// Every arm64 program running under maclator on this Mac, however it was started (this launcher,
// a terminal, brew, a shim): found by scanning the process table for maclator processes and
// grouping each one with the maclator helpers below it.

import AppKit
import Darwin
import Foundation

struct GuestProcess: Identifiable, Hashable {
    let pid: pid_t
    /// The arm64 program maclator is running (its path as given on the command line).
    let program: String
    let args: [String]
    let started: Date
    /// The .app bundle the program belongs to, if any.
    let bundle: URL?
    var processes: Int
    var residentBytes: UInt64
    /// Percent of one core, summed over the group, since the previous scan.
    var cpu: Double
    var windows: Int
    /// The group's processes: the program itself first, then its helpers.
    var members: [Member]
    var id: pid_t { pid }

    struct Member: Identifiable, Hashable {
        let pid: pid_t
        /// What the process is: Chromium/Electron's `--type=…`, else the program's name.
        let role: String
        let cpu: Double
        let residentBytes: UInt64
        var id: pid_t { pid }
    }

    var name: String {
        if let b = bundle, let info = Bundle(url: b)?.infoDictionary {
            return (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? b.deletingPathExtension().lastPathComponent
        }
        return (program as NSString).lastPathComponent
    }
    var icon: NSImage {
        if let b = bundle { return NSWorkspace.shared.icon(forFile: b.path) }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

/// Raw facts about one process.
private struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let started: Date
    let isMaclator: Bool
    let cpuTime: UInt64
    let resident: UInt64
}

private func procInfo(_ pid: pid_t) -> ProcInfo? {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    var bsd = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
    var task = proc_taskinfo()
    let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size)
    return ProcInfo(pid: pid, ppid: pid_t(bsd.pbi_ppid),
                    started: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6),
                    isMaclator: (String(cString: path) as NSString).lastPathComponent == "maclator",
                    cpuTime: hasTask ? task.pti_total_user + task.pti_total_system : 0,
                    resident: hasTask ? task.pti_resident_size : 0)
}

/// argv of a process (KERN_PROCARGS2: argc, the exec path, then argv strings).
private func arguments(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size && buf[i] != 0 { i += 1 } // exec path
    while i < size && buf[i] == 0 { i += 1 } // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

/// The guest program and its arguments, skipping maclator's own options (see main.rs).
private func guestCommand(_ argv: [String]) -> (String, [String])? {
    let withValue: Set<String> = ["--dyld", "--sysroot", "--gpu-only"]
    var i = 1
    while i < argv.count, argv[i].hasPrefix("--") {
        i += withValue.contains(argv[i]) ? 2 : 1
    }
    guard i < argv.count else { return nil }
    return (argv[i], Array(argv[(i + 1)...]))
}

/// The .app a path is inside of (…/Foo.app/Contents/MacOS/Foo → …/Foo.app).
private func enclosingBundle(_ path: String) -> URL? {
    var url = URL(fileURLWithPath: path)
    while url.path != "/" {
        if url.pathExtension == "app" { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

/// maclator processes whose guest program is `program` (finds apps that relaunched themselves).
func maclatorProcesses(running program: String) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 8192)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard n > 0 else { return [] }
    return pids.prefix(Int(n)).filter { pid in
        guard pid > 0, let info = procInfo(pid), info.isMaclator else { return false }
        return guestCommand(arguments(pid))?.0 == program
    }
}

/// Polls the process table and keeps the list of guest programs current.
/// One reading of a program's group, for the inspector's charts.
struct Sample: Identifiable, Hashable {
    let time: Date
    let cpu: Double
    let residentBytes: UInt64
    var id: Date { time }
}

@MainActor
final class GuestMonitor: ObservableObject {
    @Published private(set) var running: [GuestProcess] = []
    /// The last `historyLength` readings per program (root pid), one per scan (every 2 s).
    @Published private(set) var history: [pid_t: [Sample]] = [:]
    static let historyLength = 180
    private var lastCPU: [pid_t: (UInt64, Date)] = [:]
    private var timer: Timer?

    init() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func scan() {
        let previous = lastCPU
        Task.detached(priority: .utility) {
            let result = Self.collect(previous: previous)
            await MainActor.run {
                self.running = result.0
                self.lastCPU = result.1
                let now = Date()
                // Keep an ended program's readings for 10 minutes (its inspector may still be open).
                var h = self.history.filter { pid, s in
                    result.0.contains { $0.pid == pid } || (s.last.map { now.timeIntervalSince($0.time) < 600 } ?? false)
                }
                for g in result.0 where previous.keys.contains(g.pid) { // the first scan has no CPU figure yet
                    var s = h[g.pid] ?? []
                    s.append(Sample(time: now, cpu: g.cpu, residentBytes: g.residentBytes))
                    if s.count > Self.historyLength { s.removeFirst(s.count - Self.historyLength) }
                    h[g.pid] = s
                }
                self.history = h
            }
        }
    }

    /// SIGTERM to the program and its helpers, then SIGKILL whatever is left.
    func stop(_ g: GuestProcess) {
        let tree = descendants(of: g.pid) + [g.pid]
        for p in tree { kill(p, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for p in tree { kill(p, SIGKILL) }
            self.scan()
        }
    }

    nonisolated private static func collect(previous: [pid_t: (UInt64, Date)]) -> ([GuestProcess], [pid_t: (UInt64, Date)]) {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return ([], [:]) }
        let infos = pids.prefix(Int(n)).compactMap { $0 > 0 ? procInfo($0) : nil }
        let guests = Dictionary(uniqueKeysWithValues: infos.filter(\.isMaclator).map { ($0.pid, $0) })
        var children: [pid_t: [pid_t]] = [:]
        for p in guests.values { children[p.ppid, default: []].append(p.pid) }

        let now = Date()
        var cpuNow: [pid_t: (UInt64, Date)] = [:]
        var out: [GuestProcess] = []
        // A group's root is a maclator process whose parent isn't one.
        for root in guests.values where guests[root.ppid] == nil {
            guard let (program, args) = guestCommand(arguments(root.pid)) else { continue }
            var group: [ProcInfo] = []
            var queue = [root.pid]
            while let p = queue.popLast() {
                if let info = guests[p] { group.append(info) }
                queue += children[p] ?? []
            }
            var cpu = 0.0
            var members: [GuestProcess.Member] = []
            for p in group {
                cpuNow[p.pid] = (p.cpuTime, now)
                var c = 0.0
                if let (t0, d0) = previous[p.pid], p.cpuTime >= t0 {
                    // pti_total_* are in Mach time units: nanoseconds on Intel Macs.
                    c = Double(p.cpuTime - t0) / 1e9 / max(now.timeIntervalSince(d0), 0.1) * 100
                }
                cpu += c
                let argv = p.pid == root.pid ? args : (guestCommand(arguments(p.pid))?.1 ?? [])
                let role = argv.first { $0.hasPrefix("--type=") }.map { String($0.dropFirst(7)) }
                    ?? (p.pid == root.pid ? "main" : "helper")
                members.append(.init(pid: p.pid, role: role, cpu: c, residentBytes: p.resident))
            }
            out.append(GuestProcess(pid: root.pid, program: program, args: args, started: root.started,
                                    bundle: enclosingBundle(program), processes: group.count,
                                    residentBytes: group.reduce(0) { $0 + $1.resident }, cpu: cpu,
                                    windows: onscreenWindows(owners: Set(group.map(\.pid))), members: members))
        }
        return (out.sorted { $0.started < $1.started }, cpuNow)
    }
}
