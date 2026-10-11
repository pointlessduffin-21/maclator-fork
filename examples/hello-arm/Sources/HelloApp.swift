import SwiftUI
import AppKit

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
}
func fmtDuration(_ t: TimeInterval) -> String {
    let s = Int(t); return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
func fmtBytes(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }

@MainActor
final class Model: ObservableObject {
    @Published var snap = Snapshot()
    @Published var use = usage()
    @Published var log: [String] = []
    private var ticks = 0
    private var timer: Timer?

    init() {
        snap = gather()
        append("Hello World, I am \(greetingName).")
        for r in snap.system {
            append((r.sysctl.map { "sysctl \($0) = " } ?? "\(r.key) = ") + r.value)
        }
        append(snap.featureTitle + ": " + snap.features.map { "\($0.id)=\($0.on ? "yes" : "no")" }.joined(separator: " "))
        append("Verdict: \(snap.verdict)")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func append(_ s: String) {
        log.append("[\(stamp())] \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
    func tick() {
        ticks += 1
        use = usage()
        if ticks % 5 == 0 {
            append("heartbeat  up \(fmtDuration(use.uptime))  rss \(fmtBytes(use.rss))  cpu \(String(format: "%.2f", use.cpuTime))s  threads \(use.threads)")
        }
    }
    var fullReport: String {
        snap.report + "\nLive: up \(fmtDuration(use.uptime)), rss \(fmtBytes(use.rss)), cpu time \(String(format: "%.2f", use.cpuTime))s, threads \(use.threads)\n\nLog:\n" + log.joined(separator: "\n") + "\n"
    }
}

struct ContentView: View {
    @StateObject private var m = Model()
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Hello.app")
                    Title(before: "Hello World, I am ", em: greetingName, after: ".", size: 56)
                    Text(historyLine)
                        .font(Paper.sans(14.5)).foregroundStyle(Paper.ink2)
                        .frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    StatusLine(health: m.snap.health, text: m.snap.verdict).padding(.top, 2)
                }
                HStack(spacing: 14) {
                    Pane { KPI(label: "Architecture", value: m.snap.arch, note: "cputype " + m.snap.cputype) }
                    Pane { KPI(label: "Page size", value: m.snap.pageSize, note: "hw.pagesize") }
                    Pane { KPI(label: "CPUs", value: m.snap.cpus, note: "logical") }
                    Pane { KPI(label: "Memory", value: m.snap.memory, note: "hw.memsize") }
                }
                Pane(title: "This process") {
                    HStack(spacing: 14) {
                        KPI(label: "Uptime", value: fmtDuration(m.use.uptime))
                        KPI(label: "Resident", value: fmtBytes(m.use.rss))
                        KPI(label: "CPU time", value: String(format: "%.2fs", m.use.cpuTime))
                        KPI(label: "Threads", value: "\(m.use.threads)")
                    }
                }
                Pane(title: "System readings") {
                    VStack(spacing: 0) {
                        ForEach(Array(m.snap.system.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Hairline() }
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                MonoLabel(r.key, size: 10.5).frame(width: 230, alignment: .leading)
                                Text(r.value).font(Paper.sans(13)).foregroundStyle(Paper.ink)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, 7)
                        }
                    }
                }
                Pane(title: m.snap.featureTitle) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(m.snap.features) { f in
                            HStack(spacing: 8) {
                                StatusDot(health: f.on ? .ok : .down)
                                Text(f.id).font(Paper.mono(11)).foregroundStyle(Paper.ink2)
                                Text(f.on ? "yes" : "no").font(Paper.sans(12.5)).foregroundStyle(Paper.ink3)
                            }
                        }
                    }
                }
                Pane(title: "Log", accessory: {
                    Button { copy() } label: { Text(copied ? "Copied" : "Copy report") }
                        .buttonStyle(PaperButtonStyle(kind: .outline, small: true))
                }, content: {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(m.log.joined(separator: "\n"))
                                    .font(Paper.mono(11)).foregroundStyle(Paper.ink2)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("end")
                            }
                        }
                        .frame(height: 190)
                        .onChange(of: m.log.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                        .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    }
                })
            }
            .padding(32)
        }
        .background(Paper.paper)
        .preferredColorScheme(.light)
        .onAppear { snapshotIfRequested() }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(m.fullReport, forType: .string)
        m.append("Report copied to clipboard")
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    func snapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["HELLO_SNAPSHOT"] else { return }
        let report = ProcessInfo.processInfo.environment["HELLO_REPORT"]
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if let report { try? m.fullReport.write(toFile: report, atomically: true, encoding: .utf8) }
            if let h = ProcessInfo.processInfo.environment["HELLO_HEIGHT"].flatMap(Double.init), let w = NSApp.windows.first(where: \.isVisible) {
                w.setContentSize(NSSize(width: w.frame.width, height: h))
            }
            if ProcessInfo.processInfo.environment["HELLO_SCROLL"] != nil, let w = NSApp.windows.first(where: \.isVisible) {
                func find(_ v: NSView) -> NSScrollView? { if let s = v as? NSScrollView, s.documentView.map({ $0.frame.height > s.frame.height }) ?? false { return s }; for c in v.subviews { if let r = find(c) { return r } }; return nil }
                if let sv = w.contentView.flatMap(find), let d = sv.documentView {
                    d.scroll(NSPoint(x: 0, y: d.isFlipped ? d.frame.height : 0)); sv.reflectScrolledClipView(sv.contentView)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let w = NSApp.windows.first(where: \.isVisible),
                  let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution])
            else { exit(1) }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
            }
        }
    }
}

@main
struct HelloApp: App {
    var body: some Scene {
        WindowGroup("Hello") {
            ContentView().frame(minWidth: 760, idealWidth: 760, minHeight: 640, idealHeight: 880)
        }
        .windowResizability(.contentMinSize)
    }
}
