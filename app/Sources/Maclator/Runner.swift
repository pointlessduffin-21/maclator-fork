// Launching apps through maclator and watching them: output, first window, exit.

import AppKit
import CoreGraphics
import Darwin
import Foundation

struct LaunchOptions: Hashable {
    /// `--arm64-children`: helpers and tools the app starts run as arm64 too.
    var arm64Children = true
    /// `--gpu`: route the app's Metal calls to this Mac's GPU.
    var gpu = false
    /// `--no-aot`: don't use or build the translation cache.
    var noCache = false
}

@MainActor
final class Session: ObservableObject, Identifiable {
    enum State: Equatable {
        /// `exited`: the app quit with this status; `signaled`: it was stopped or crashed on a signal.
        case starting, running, exited(Int32), signaled(Int32), failed(String)
    }

    let id = UUID()
    let app: GuestApp
    let options: LaunchOptions
    let started = Date()
    @Published private(set) var state: State = .starting
    @Published private(set) var log: [String] = []
    @Published private(set) var firstWindow: TimeInterval?
    @Published private(set) var windows = 0
    @Published private(set) var processes = 1

    private let process = Process()
    private var timer: Timer?
    private var partial = ""
    var onFinish: ((Session) -> Void)?

    init(app: GuestApp, options: LaunchOptions) {
        self.app = app
        self.options = options
    }

    var pid: pid_t { process.processIdentifier }
    var isLive: Bool { state == .starting || state == .running }

    func start(maclator: URL) {
        var args: [String] = []
        if options.arm64Children { args.append("--arm64-children") }
        if options.gpu { args.append("--gpu") }
        if options.noCache { args.append("--no-aot") }
        if app.chromium { args += ["--dump-on-fault"] }
        args.append(app.executable.path)
        if app.chromium { args += ["--no-sandbox", "--disable-gpu-sandbox"] }
        process.executableURL = maclator
        process.arguments = args
        process.currentDirectoryURL = app.url.deletingLastPathComponent()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(s) }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            let signaled = p.terminationReason == .uncaughtSignal
            Task { @MainActor in self?.finished(signaled ? .signaled(status) : .exited(status)) }
        }
        do {
            try process.run()
            append("$ maclator \(args.map(shellQuote).joined(separator: " "))\n")
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// Ask the app and every helper it started to quit (SIGTERM), then make sure (SIGKILL).
    func stop() {
        stopRequested = true
        let tree = ([pid] + relaunched).flatMap { descendants(of: $0) + [$0] }
        for p in tree { kill(p, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for p in tree { kill(p, SIGKILL) }
        }
    }

    private func append(_ s: String) {
        let text = partial + s
        var lines = text.components(separatedBy: "\n")
        partial = lines.removeLast()
        log.append(contentsOf: lines)
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }

    /// Processes of a copy the app relaunched (the original exits, the copy is reparented to launchd).
    private var relaunched: [pid_t] = []

    private func poll() {
        guard isLive else { return }
        let tree = Set(descendants(of: pid) + [pid] + relaunched.flatMap { descendants(of: $0) + [$0] })
        processes = tree.count
        let n = onscreenWindows(owners: tree)
        windows = n
        if n > 0 && firstWindow == nil {
            firstWindow = Date().timeIntervalSince(started)
            state = .running
        }
    }

    private var stopRequested = false

    private func finished(_ end: State) {
        // Quit cleanly before any window, but another maclator is running the same program: the app
        // relaunched itself (Pixelmator Pro does). Follow the copy instead of ending the run.
        if case .exited(0) = end, firstWindow == nil, !stopRequested {
            let copies = maclatorProcesses(running: app.executable.path).filter { $0 != pid }
            if !copies.isEmpty {
                relaunched = copies
                append("[launcher] the app relaunched itself (pid \(copies.map(String.init).joined(separator: ", "))); following it\n")
                followRelaunch()
                return
            }
        }
        timer?.invalidate()
        if !partial.isEmpty { log.append(partial); partial = "" }
        state = end
        windows = 0
        onFinish?(self)
    }

    /// Poll until every relaunched copy is gone, then finish the run.
    private func followRelaunch() {
        if relaunched.contains(where: { kill($0, 0) == 0 }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.followRelaunch() }
            return
        }
        relaunched = []
        finished(.exited(0))
    }

    /// What this run says about the app.
    var verdict: CompatEntry {
        let date = ISO8601DateFormatter.string(from: started, timeZone: .current, formatOptions: [.withFullDate])
        if let w = firstWindow {
            // maclator exits 128+signal for a guest crash; a stop the user asked for is not one.
            let crashed: Bool = {
                switch state {
                case .exited(let s): return s != 0
                case .signaled: return !stopRequested
                default: return false
                }
            }()
            return CompatEntry(verdict: crashed ? .partial : .works,
                               note: crashed ? "Opened a window, then quit with an error." : "Opened a window.",
                               firstWindow: w, tested: date)
        }
        let last = log.last { line in
            line.hasPrefix("maclator:") || line.contains("unimplemented") || line.contains("BRK") || line.localizedCaseInsensitiveContains("error")
        }
        return CompatEntry(verdict: .fails, note: last.map { String($0.prefix(160)) } ?? "Quit before showing a window.", tested: date)
    }
}

private func shellQuote(_ s: String) -> String {
    s.contains(" ") ? "\"\(s)\"" : s
}

/// Every process below `pid` (Electron and Chromium apps run a tree of helpers).
func descendants(of pid: pid_t) -> [pid_t] {
    var out: [pid_t] = []
    var queue = [pid]
    while let p = queue.popLast() {
        var buf = [pid_t](repeating: 0, count: 512)
        let n = proc_listchildpids(p, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { continue }
        let kids = Array(buf.prefix(Int(n))).filter { $0 > 0 }
        out += kids
        queue += kids
    }
    return out
}

/// On-screen, normal-layer windows owned by any of `owners`.
func onscreenWindows(owners: Set<pid_t>) -> Int {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return 0 }
    return list.filter { w in
        guard let pid = w[kCGWindowOwnerPID as String] as? Int32, owners.contains(pid) else { return false }
        return (w[kCGWindowLayer as String] as? Int) == 0
    }.count
}

// MARK: - The launcher's state

@MainActor
final class Launcher: ObservableObject {
    @Published var install = Install.discover()
    @Published var apps: [GuestApp] = []
    @Published var scanning = false
    @Published var sessions: [Session] = []
    @Published var options = LaunchOptions()
    @Published private(set) var compatVersion = 0
    let compat = CompatStore()

    func refresh() {
        install = Install.discover()
        scanning = true
        let added = AddedApps.load()
        Task.detached(priority: .userInitiated) {
            let found = GuestApp.scan(added: added)
            await MainActor.run {
                self.apps = found
                self.scanning = false
            }
        }
    }

    /// Add apps by hand (picked in a panel or dropped): .app bundles, or folders of them.
    /// Returns how many new apps there were and which picks weren't apps with arm64 code.
    @discardableResult
    func add(_ urls: [URL]) -> (added: Int, skipped: [String]) {
        var list = AddedApps.load()
        var added = 0
        var skipped: [String] = []
        for b in AddedApps.bundles(in: urls) {
            guard let app = GuestApp.load(b), app.runnable else {
                skipped.append(b.deletingPathExtension().lastPathComponent)
                continue
            }
            let known = apps.contains { $0.url.resolvingSymlinksInPath() == b.resolvingSymlinksInPath() }
            if !known && !list.contains(b) {
                list.append(b)
                added += 1
            }
        }
        AddedApps.save(list)
        refresh()
        return (added, skipped)
    }

    func remove(_ app: GuestApp) {
        AddedApps.save(AddedApps.load().filter { $0.resolvingSymlinksInPath() != app.url.resolvingSymlinksInPath() })
        refresh()
    }

    func entry(_ app: GuestApp) -> CompatEntry { compat.entry(for: app) }

    func session(for app: GuestApp) -> Session? {
        sessions.last { $0.app.id == app.id }
    }

    func launch(_ app: GuestApp) {
        guard let m = install.maclator, app.runnable else { return }
        let s = Session(app: app, options: options)
        s.onFinish = { [weak self] s in self?.record(s) }
        sessions.append(s)
        s.start(maclator: m)
    }

    /// Record the outcome once a run ends (or when the user stops a run that showed a window).
    func record(_ s: Session) {
        compat.record(s.verdict, for: s.app)
        compatVersion += 1
    }

    var live: [Session] { sessions.filter(\.isLive) }
}
