// The launcher's screens, in the Paper tool grammar: a sidebar shell, panes, mono labels,
// one serif title per screen with a single vermilion phrase.

import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

enum Screen: String, CaseIterable, Identifiable {
    case library, running, setup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: "Library"
        case .running: "Running"
        case .setup: "Setup"
        }
    }
    var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .running: "play.circle"
        case .setup: "wrench.and.screwdriver"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var launcher: Launcher
    @State private var screen: Screen = .library
    @State private var selection: GuestApp.ID?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(screen: $screen)
            Rectangle().fill(Paper.line).frame(width: 1)
            Group {
                switch screen {
                case .library: LibraryView(selection: $selection)
                case .running: RunningView(screen: $screen, selection: $selection)
                case .setup: SetupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Paper.paper)
        .ignoresSafeArea()
        .foregroundStyle(Paper.ink)
        .tint(Paper.accent)
        .onAppear {
            launcher.refresh()
            Snapshot.scheduleIfRequested(screen: $screen, selection: $selection, launcher: launcher)
        }
    }
}

/// Debug aid for screenshots without the Screen Recording permission: with
/// MACLATOR_SNAPSHOT=/path.png the app shows MACLATOR_SNAPSHOT_SCREEN (library/running/setup),
/// selects the app whose bundle ID is MACLATOR_SNAPSHOT_SELECT, draws its own window into the PNG and quits.
@MainActor
enum Snapshot {
    static func scheduleIfRequested(screen: Binding<Screen>, selection: Binding<GuestApp.ID?>, launcher: Launcher) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MACLATOR_SNAPSHOT"] else { return }
        if let s = env["MACLATOR_SNAPSHOT_SCREEN"].flatMap(Screen.init(rawValue:)) { screen.wrappedValue = s }
        // MACLATOR_SNAPSHOT_ADD=/path: what Add apps… does with a picked folder or app.
        if let p = env["MACLATOR_SNAPSHOT_ADD"] { launcher.add([URL(fileURLWithPath: p)]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if let id = env["MACLATOR_SNAPSHOT_SELECT"], let app = launcher.apps.first(where: { $0.bundleID == id }) {
                selection.wrappedValue = app.id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // A process may capture its own windows without the Screen Recording permission.
                if let h = env["MACLATOR_SNAPSHOT_HEIGHT"].flatMap(Double.init), let w = NSApp.windows.first(where: \.isVisible) {
                    w.setContentSize(NSSize(width: w.frame.width, height: h))
                }
                guard let w = NSApp.windows.first(where: \.isVisible),
                      let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution])
                else { exit(1) }
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }
}

// MARK: - Sidebar (`.app__side`)

struct Sidebar: View {
    @EnvironmentObject var launcher: Launcher
    @EnvironmentObject var monitor: GuestMonitor
    @Binding var screen: Screen

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Maclator").font(Paper.serif(26)).padding(.horizontal, 8).padding(.bottom, 4)
            Text("arm64 apps on Intel").font(Paper.sans(12.5)).foregroundStyle(Paper.ink3).padding(.horizontal, 8).padding(.bottom, 24)
            ForEach(Screen.allCases) { s in
                Button { screen = s } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.symbol).font(.system(size: 13)).frame(width: 16)
                        Text(s.title).font(Paper.sans(14))
                        Spacer()
                        if s == .running, !monitor.running.isEmpty {
                            Text("\(monitor.running.count)").font(Paper.mono(11))
                        }
                    }
                    .foregroundStyle(screen == s ? Paper.paper : Paper.ink2)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(screen == s ? Paper.ink : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(screen == s ? .isSelected : [])
            }
            Spacer()
            MonoLabel("Translator").padding(.horizontal, 12).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 6) {
                StatusLine(health: launcher.install.maclator != nil ? .ok : .err, text: launcher.install.maclator != nil ? "Installed" : "Not found")
                StatusLine(health: launcher.install.sysroot != nil ? .ok : .err, text: launcher.install.sysroot != nil ? "arm64 system ready" : "No arm64 system")
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 46) // clear of the window buttons
        .padding(.bottom, 22)
        .padding(.horizontal, 16)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Paper.paperHi.opacity(0.7))
    }
}

// MARK: - Library

enum LibraryFilter: Hashable { case all, works, untested, trouble }

struct LibraryView: View {
    @EnvironmentObject var launcher: Launcher
    @Binding var selection: GuestApp.ID?
    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    /// What the last Add apps… or drop did, shown under the toolbar.
    @State private var notice: String?
    @State private var dropTargeted = false

    private var runnable: [GuestApp] { launcher.apps.filter(\.runnable) }

    private var shown: [GuestApp] {
        _ = launcher.compatVersion
        return launcher.apps.filter { app in
            (query.isEmpty || app.name.localizedCaseInsensitiveContains(query)) && {
                let v = launcher.entry(app).verdict
                switch filter {
                case .all: return true
                case .works: return v == .works
                case .untested: return v == .untested
                case .trouble: return app.runnable && (v == .fails || v == .partial)
                }
            }()
        }
        .sorted { ($0.runnable ? 0 : 1, $0.name) < ($1.runnable ? 0 : 1, $1.name) }
    }

    private func count(_ v: Verdict) -> Int {
        _ = launcher.compatVersion
        return runnable.filter { launcher.entry($0).verdict == v }.count
    }

    private func pickApps() {
        let panel = NSOpenPanel()
        panel.title = "Add arm64 apps"
        panel.message = "Choose apps, or a folder of apps, to run through Maclator."
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application, .folder]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        guard panel.runModal() == .OK else { return }
        report(launcher.add(panel.urls))
    }

    private func addDropped(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for p in providers {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let u = URL(dataRepresentation: url, relativeTo: nil) {
                urls.append(u)
            }
        }
        report(launcher.add(urls))
    }

    private func report(_ r: (added: Int, skipped: [String])) {
        var parts: [String] = []
        if r.added > 0 { parts.append("Added \(r.added) app\(r.added == 1 ? "" : "s").") }
        if r.added == 0 && r.skipped.isEmpty { parts.append("Those apps are already in the list.") }
        if !r.skipped.isEmpty {
            parts.append("Not added (no arm64 code, or not an app): \(r.skipped.prefix(3).joined(separator: ", "))\(r.skipped.count > 3 ? "…" : "").")
        }
        withAnimation(Paper.ease) { notice = parts.joined(separator: " ") }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Library")
                    Title(before: "Your ", em: "apps", size: 44)
                    Text("Apps with arm64 code on this Mac's volumes, plus any you add. Launch one and Maclator translates it to run here; each run is noted below.")
                        .font(Paper.sans(14.5)).foregroundStyle(Paper.ink2).frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 14) {
                    Pane { KPI(label: "Can run", value: "\(runnable.count)", note: "of \(launcher.apps.count) apps") }
                    Pane { KPI(label: "Works", value: "\(count(.works))", note: "opened a window") }
                    Pane { KPI(label: "Not tried", value: "\(count(.untested))", note: "no run yet") }
                    Pane { KPI(label: "Trouble", value: "\(count(.fails) + count(.partial))", note: "failed or partial") }
                }
                HStack(spacing: 10) {
                    PaperField(placeholder: "Search apps", text: $query).frame(minWidth: 120, maxWidth: 260)
                    Segmented(options: [(.all, "All"), (.works, "Works"), (.untested, "Not tried"), (.trouble, "Trouble")], selection: $filter)
                    Spacer()
                    if launcher.scanning { ProgressView().controlSize(.small) }
                    Button { pickApps() } label: { Text("Add apps…") }
                        .buttonStyle(PaperButtonStyle(small: true))
                        .help("Add arm64 apps from anywhere: pick .app bundles or a folder of them, or drop them on the list")
                    Button { launcher.refresh() } label: { Text("Rescan") }
                        .buttonStyle(PaperButtonStyle(small: true))
                }
                if let notice {
                    HStack(spacing: 10) {
                        Text(notice).font(Paper.sans(13)).foregroundStyle(Paper.ink2)
                        Button { withAnimation(Paper.ease) { self.notice = nil } } label: { Text("OK") }
                            .buttonStyle(PaperButtonStyle(small: true))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { app in
                            AppRow(app: app, entry: launcher.entry(app), selected: selection == app.id)
                                .onTapGesture { selection = app.id }
                            Hairline()
                        }
                        if shown.isEmpty && !launcher.scanning {
                            Text(launcher.apps.isEmpty ? "No apps found in /Applications or on other volumes." : "Nothing matches.")
                                .font(Paper.sans(14)).foregroundStyle(Paper.ink3).padding(.vertical, 40)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Paper.radius).fill(Paper.paperHi.opacity(0.82)))
                .overlay(RoundedRectangle(cornerRadius: Paper.radius).stroke(dropTargeted ? Paper.ink : Paper.line, lineWidth: dropTargeted ? 2 : 1))
                .overlay {
                    if dropTargeted {
                        Text("Drop arm64 apps to add them").font(Paper.sans(15, .medium)).foregroundStyle(Paper.ink)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(Paper.paperHi))
                            .overlay(Capsule().stroke(Paper.line2, lineWidth: 1))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Paper.radius))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    Task { await addDropped(providers) }
                    return true
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 38)
            .padding(.bottom, 24)

            if let id = selection, let app = launcher.apps.first(where: { $0.id == id }) {
                Rectangle().fill(Paper.line).frame(width: 1)
                AppDetail(app: app)
                    .frame(width: 400)
                    .id(app.id)
            }
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var launcher: Launcher
    let app: GuestApp
    let entry: CompatEntry
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: app.icon).resizable().frame(width: 34, height: 34)
                .saturation(app.runnable ? 1 : 0).opacity(app.runnable ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(Paper.sans(14.5, .medium)).foregroundStyle(app.runnable ? Paper.ink : Paper.ink3)
                Text(app.url.deletingLastPathComponent().path).font(Paper.mono(10.5)).foregroundStyle(Paper.ink3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Chip(app.arches.label)
                if app.sandboxed { Chip("sandboxed") }
                if app.electron { Chip("electron") } else if app.chromium { Chip("chromium") }
                if app.added { Chip("added") }
                if app.builtIn { Chip("built-in test") }
            }
            StatusLine(health: launcher.session(for: app)?.isLive == true ? .live : entry.verdict.health,
                       text: launcher.session(for: app)?.isLive == true ? "Running" : (app.runnable ? entry.verdict.label : "Intel only"))
                .frame(width: 118, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(selected ? Paper.paperLo : (hover ? Paper.ink.opacity(0.03) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Detail

struct AppDetail: View {
    @EnvironmentObject var launcher: Launcher
    let app: GuestApp

    var body: some View {
        let entry = launcher.entry(app)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: app.icon).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(Paper.serif(30)).lineLimit(2)
                        Text([app.version, app.bundleID].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(Paper.mono(10.5)).foregroundStyle(Paper.ink3).lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Chip(app.arches.label)
                    if app.sandboxed { Chip("sandboxed") }
                    if app.electron { Chip("electron") } else if app.chromium { Chip("chromium") }
                    if app.added { Chip("added") }
                if app.builtIn { Chip("built-in test") }
                    Spacer(minLength: 0)
                    if app.added {
                        Button { launcher.remove(app) } label: { Text("Remove") }
                            .buttonStyle(PaperButtonStyle(small: true))
                            .help("Take this app off the list (the app itself is not touched)")
                    }
                }
                Pane(title: "Last result") {
                    VStack(alignment: .leading, spacing: 12) {
                        StatusLine(health: entry.verdict.health, text: app.runnable ? entry.verdict.label : "Intel only")
                        if !entry.note.isEmpty {
                            Text(entry.note).font(Paper.sans(13)).foregroundStyle(Paper.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            KPI(label: "First window", value: entry.firstWindow.map { "\(Int($0.rounded()))s" } ?? "—")
                            KPI(label: "Tested", value: entry.tested ?? "—")
                        }
                    }
                }
                if app.runnable {
                    LaunchPane(app: app)
                    if app.sandboxed {
                        Note(text: "Sandboxed apps start without their sandbox under Maclator, and some refuse to run that way.")
                    }
                } else {
                    Note(text: "This app has no arm64 code, so there is nothing to translate: open it normally.")
                }
                if let s = launcher.session(for: app) { SessionLog(session: s) }
            }
            .padding(24)
        }
        .background(Paper.paper)
    }
}

struct Note: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Paper.line2).frame(width: 2)
            Text(text).font(Paper.sans(13)).foregroundStyle(Paper.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LaunchPane: View {
    @EnvironmentObject var launcher: Launcher
    let app: GuestApp

    var body: some View {
        Pane(title: "Launch") {
            VStack(alignment: .leading, spacing: 14) {
                PaperToggle(title: "Helpers run as arm64", hint: "Tools and helper processes the app starts get the same treatment.", isOn: $launcher.options.arm64Children)
                PaperToggle(title: "Use this Mac's GPU", hint: "Bridges Metal to the real graphics card. Needed for GPU-drawn apps; windows drawn with CAMetalLayer don't show yet.", isOn: $launcher.options.gpu)
                PaperToggle(title: "Skip the translation cache", hint: "Slower; for ruling out cache problems.", isOn: $launcher.options.noCache)
                HStack(spacing: 10) {
                    if let s = launcher.session(for: app), s.isLive {
                        Button { s.stop() } label: { Text("Stop") }.buttonStyle(PaperButtonStyle(kind: .danger))
                    } else {
                        Button { launcher.launch(app) } label: { ArrowLabel("Launch") }
                            .buttonStyle(PaperButtonStyle(kind: .ink))
                            .disabled(!launcher.install.ready)
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: { Text("Show in Finder") }
                        .buttonStyle(PaperButtonStyle(small: true))
                }
                if !launcher.install.ready {
                    Text("Maclator isn't set up yet: see Setup.").font(Paper.sans(12.5)).foregroundStyle(Paper.err)
                }
            }
        }
    }
}

struct SessionLog: View {
    @ObservedObject var session: Session

    private var stateText: (Health, String) {
        switch session.state {
        case .starting: (.warn, "Starting… translating as it goes")
        case .running: (.live, "Running · \(session.windows) window\(session.windows == 1 ? "" : "s")")
        case .exited(let s): (s == 0 ? .down : .err, s == 0 ? "Quit" : "Exited with status \(s)")
        case .signaled(let s): (.down, s == SIGTERM || s == SIGKILL ? "Stopped" : "Ended by signal \(s)")
        case .failed(let e): (.err, e)
        }
    }

    var body: some View {
        Pane(title: "This run", accessory: {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(elapsed).font(Paper.mono(11)).foregroundStyle(Paper.ink3)
            }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                StatusLine(health: stateText.0, text: stateText.1)
                HStack {
                    KPI(label: "First window", value: session.firstWindow.map { "\(Int($0.rounded()))s" } ?? "—")
                    KPI(label: "Processes", value: "\(session.processes)")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(session.log.suffix(400).enumerated()), id: \.offset) { i, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(Paper.mono(10.5))
                                    .foregroundStyle(line.hasPrefix("maclator:") ? Paper.err : Paper.ink2)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                        .padding(10)
                    }
                    .frame(height: 220)
                    .background(RoundedRectangle(cornerRadius: Paper.radiusSmall).fill(Paper.paperLo.opacity(0.7)))
                    .onChange(of: session.log.count) { _, _ in
                        proxy.scrollTo(min(session.log.count, 400) - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var elapsed: String {
        let t = Int(Date().timeIntervalSince(session.started))
        return session.isLive ? String(format: "%d:%02d", t / 60, t % 60) : "done"
    }
}

// MARK: - Running

struct RunningView: View {
    @EnvironmentObject var launcher: Launcher
    @EnvironmentObject var monitor: GuestMonitor
    @Binding var screen: Screen
    @Binding var selection: GuestApp.ID?
    /// The program shown in the inspector, as it was when opened.
    @State private var inspected: GuestProcess?

    private var history: [Session] { launcher.sessions.filter { !$0.isLive }.reversed() }

    var body: some View {
        HStack(spacing: 0) {
            list
                .onAppear {
                    // Snapshot debug aid (see Snapshot): open the first running program's inspector.
                    guard ProcessInfo.processInfo.environment["MACLATOR_SNAPSHOT_INSPECT"] != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { inspected = monitor.running.first }
                }
            if let snap = inspected {
                Rectangle().fill(Paper.line).frame(width: 1)
                GuestInspector(snapshot: snap, live: monitor.running.first { $0.pid == snap.pid },
                               close: { withAnimation(Paper.ease) { inspected = nil } },
                               openInLibrary: libraryLink(snap))
                    .frame(width: 460)
                    .id(snap.pid)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Running")
                    Title(before: "Under ", em: "translation", size: 44)
                    Text("Every arm64 program running through Maclator on this Mac, whether it was started here, from a terminal or by brew.")
                        .font(Paper.sans(14.5)).foregroundStyle(Paper.ink2).frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 14) {
                    Pane { KPI(label: "Programs", value: "\(monitor.running.count)", note: "arm64, translated") }
                    Pane { KPI(label: "Processes", value: "\(monitor.running.reduce(0) { $0 + $1.processes })", note: "including helpers") }
                    Pane { KPI(label: "Memory", value: ByteCountFormatter.string(fromByteCount: Int64(monitor.running.reduce(0) { $0 + $1.residentBytes }), countStyle: .memory), note: "resident") }
                    Pane { KPI(label: "CPU", value: "\(Int(monitor.running.reduce(0) { $0 + $1.cpu }.rounded()))%", note: "of one core") }
                }
                Pane(title: "Now") {
                    if monitor.running.isEmpty {
                        Text("Nothing is running under Maclator. Launch an app from the Library, or run `maclator <program>` in a terminal.")
                            .font(Paper.sans(14)).foregroundStyle(Paper.ink3)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(monitor.running) { g in
                                GuestRow(guest: g, selected: inspected?.pid == g.pid, compact: inspected != nil) {
                                    withAnimation(Paper.ease) { inspected = inspected?.pid == g.pid ? nil : g }
                                }
                                if g.id != monitor.running.last?.id { Hairline() }
                            }
                        }
                    }
                }
                if !history.isEmpty {
                    Pane(title: "Launched from here, ended") {
                        VStack(spacing: 0) {
                            ForEach(history) { s in
                                SessionRow(session: s) {
                                    selection = s.app.id
                                    screen = .library
                                }
                                if s.id != history.last?.id { Hairline() }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 38)
            .padding(.bottom, 24)
        }
    }

    /// Jump to the Library entry for a running bundle, if it is one the Library knows.
    private func libraryLink(_ g: GuestProcess) -> (() -> Void)? {
        guard let b = g.bundle, let app = launcher.apps.first(where: { $0.url.standardizedFileURL == b.standardizedFileURL }) else { return nil }
        return {
            selection = app.id
            screen = .library
        }
    }
}

struct GuestRow: View {
    @EnvironmentObject var monitor: GuestMonitor
    let guest: GuestProcess
    let selected: Bool
    /// The inspector is open: show fewer columns.
    let compact: Bool
    let details: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: guest.icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(guest.name).font(Paper.sans(14.5, .medium))
                Text(([guest.program] + guest.args).joined(separator: " "))
                    .font(Paper.mono(10.5)).foregroundStyle(Paper.ink3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            HStack(spacing: 18) {
                Metric(label: "Up", value: uptime)
                if !compact { Metric(label: "Procs", value: "\(guest.processes)") }
                Metric(label: "CPU", value: "\(Int(guest.cpu.rounded()))%")
                if !compact { Metric(label: "Mem", value: ByteCountFormatter.string(fromByteCount: Int64(guest.residentBytes), countStyle: .memory), width: 70) }
            }
            if !compact {
                StatusLine(health: .live, text: guest.windows > 0 ? "\(guest.windows) window\(guest.windows == 1 ? "" : "s")" : "No window")
                    .frame(width: 104, alignment: .leading)
            }
            Button(action: details) { Text(selected ? "Hide" : "Details") }
                .buttonStyle(PaperButtonStyle(small: true))
                .accessibilityAddTraits(selected ? .isSelected : [])
            if !compact {
                Button { monitor.stop(guest) } label: { Text("Stop") }.buttonStyle(PaperButtonStyle(kind: .danger, small: true))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Paper.paperLo : .clear))
    }

    private var uptime: String {
        let t = Int(Date().timeIntervalSince(guest.started))
        return t >= 3600 ? "\(t / 3600)h \(t % 3600 / 60)m" : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// A small mono label over a value, for dense rows.
struct Metric: View {
    let label: String
    let value: String
    var width: CGFloat = 44
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MonoLabel(label, size: 9.5)
            Text(value).font(Paper.mono(12)).foregroundStyle(Paper.ink).lineLimit(1)
        }
        .frame(minWidth: width, alignment: .leading)
        .fixedSize()
    }
}

struct SessionRow: View {
    @ObservedObject var session: Session
    let open: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: session.app.icon).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.app.name).font(Paper.sans(14, .medium))
                Text(session.started.formatted(date: .omitted, time: .shortened)).font(Paper.mono(10.5)).foregroundStyle(Paper.ink3)
            }
            Spacer()
            StatusLine(health: session.firstWindow != nil ? .ok : .down, text: session.firstWindow.map { "Window after \(Int($0.rounded()))s" } ?? "No window")
            Button(action: open) { Text("Details") }.buttonStyle(PaperButtonStyle(small: true))
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        let i = launcher.install
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Setup")
                    Title(before: "The ", em: "translator", size: 44)
                    Text("Maclator runs arm64 code on this Intel Mac using Apple's own arm64 system libraries, which you download once.")
                        .font(Paper.sans(14.5)).foregroundStyle(Paper.ink2).frame(maxWidth: 560, alignment: .leading)
                }
                Pane(title: "Checklist", accessory: {
                    Button { launcher.refresh() } label: { Text("Check again") }.buttonStyle(PaperButtonStyle(small: true))
                }) {
                    VStack(alignment: .leading, spacing: 0) {
                        CheckRow(ok: i.maclator != nil, title: "Maclator", detail: i.maclator?.path ?? "Run scripts/install.sh in the repository.")
                        Hairline()
                        CheckRow(ok: i.sysroot != nil, title: "arm64 system libraries", detail: i.sysroot?.path ?? "Run scripts/fetch-sysroot.sh (about 5.5 GB).")
                        Hairline()
                        CheckRow(ok: i.gpuBridge != nil, optional: true, title: "GPU bridge", detail: i.gpuBridge?.path ?? "Optional. Built by scripts/install.sh.")
                        Hairline()
                        CheckRow(ok: i.homebrew != nil, optional: true, title: "Homebrew (arm64)", detail: i.homebrew != nil ? "/opt/homebrew · use the brew in ~/bin" : "Optional. See docs/USAGE.md, Homebrew.")
                    }
                }
                ArmTestPane()
                HStack(spacing: 14) {
                    Pane { KPI(label: "Translation cache", value: ByteCountFormatter.string(fromByteCount: i.aotBytes, countStyle: .file), note: "speeds up later launches") }
                    Pane { KPI(label: "This Mac", value: "\(ProcessInfo.processInfo.processorCount) threads", note: cpuModel()) }
                }
                Note(text: "Apps save their translations when they quit normally. An app that is force-stopped saves nothing, and its next launch is slow again.")
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Intel(R) Core(TM) i5-10310U CPU @ 1.70GHz" → "Intel Core i5-10310U"
func cpuModel() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    return String(cString: buf).replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
        .components(separatedBy: " CPU").first ?? ""
}

/// Setup's one-click proof that translation works: run the built-in arm64 Hello.app.
struct ArmTestPane: View {
    @EnvironmentObject var launcher: Launcher

    private var hello: GuestApp? { launcher.apps.first(where: \.builtIn) }

    var body: some View {
        Pane(title: "Test it") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hello.app is a small app built for Apple silicon only, carried inside Maclator. If it opens and greets you with “Hello, I am ARM.”, arm64 apps run on this Mac. It also lists what it sees: architecture, CPU, OS and memory.")
                    .font(Paper.sans(13.5)).foregroundStyle(Paper.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if let app = hello {
                        if let s = launcher.session(for: app), s.isLive {
                            Button { s.stop() } label: { Text("Stop") }.buttonStyle(PaperButtonStyle(kind: .danger))
                        } else {
                            Button { launcher.launch(app) } label: { ArrowLabel("Run the arm64 test") }
                                .buttonStyle(PaperButtonStyle(kind: .ink))
                                .disabled(!launcher.install.ready)
                        }
                        if let s = launcher.session(for: app) { ArmTestStatus(session: s) }
                    } else {
                        StatusLine(health: .down, text: "Not in this build (app/build.sh --bundle adds it)")
                    }
                }
            }
        }
    }
}

struct ArmTestStatus: View {
    @ObservedObject var session: Session
    var body: some View {
        switch session.state {
        case .starting:
            StatusLine(health: .warn, text: "Starting… the first launch translates as it goes")
        case .running:
            StatusLine(health: .live, text: "Running: window after \(Int((session.firstWindow ?? 0).rounded())) s")
        case .exited(let s):
            StatusLine(health: session.firstWindow != nil ? .ok : .err, text: session.firstWindow != nil ? "Worked: it opened a window" : "Quit before a window (status \(s)); see Running")
        case .signaled:
            StatusLine(health: session.firstWindow != nil ? .ok : .down, text: session.firstWindow != nil ? "Worked: it opened a window" : "Stopped")
        case .failed(let e):
            StatusLine(health: .err, text: e)
        }
    }
}

struct CheckRow: View {
    let ok: Bool
    var optional = false
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StatusDot(health: ok ? .ok : (optional ? .down : .err))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Paper.sans(14, .medium))
                Text(detail).font(Paper.mono(11)).foregroundStyle(Paper.ink3).textSelection(.enabled)
            }
            Spacer()
            Text(ok ? "Ready" : (optional ? "Not installed" : "Missing")).font(Paper.sans(13)).foregroundStyle(Paper.ink2)
        }
        .padding(.vertical, 12)
    }
}
