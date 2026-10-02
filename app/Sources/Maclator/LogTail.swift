// Following the logs maclator keeps for each process (~/Library/Logs/Maclator/<pid>.log, see
// crates/maclator/src/logtee.rs): the inspector's live output view.

import Foundation

struct LogLine: Identifiable, Hashable {
    let id: Int
    let pid: pid_t
    let text: String
}

@MainActor
final class LogTail: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    /// pids that have no log file (started before logging existed, or MACLATOR_NO_LOG).
    @Published private(set) var missing: Set<pid_t> = []
    private var offsets: [pid_t: UInt64] = [:]
    private var partial: [pid_t: String] = [:]
    private var nextID = 0
    private var timer: Timer?
    private var pids: [pid_t] = []
    static let maxLines = 3000
    /// How far back to start in an existing log.
    static let backlog: UInt64 = 256 << 10

    static func url(_ pid: pid_t) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Maclator/\(pid).log")
    }

    func follow(_ pids: [pid_t]) {
        guard pids != self.pids else { return }
        let added = pids.filter { !self.pids.contains($0) }
        self.pids = pids
        for p in added { read(p, first: true) }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        for p in pids { read(p, first: false) }
    }

    private func read(_ pid: pid_t, first: Bool) {
        guard let h = try? FileHandle(forReadingFrom: Self.url(pid)) else {
            missing.insert(pid)
            return
        }
        missing.remove(pid)
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var from = offsets[pid] ?? (size > Self.backlog ? size - Self.backlog : 0)
        if size < from { from = 0 } // cut back to empty by maclator
        guard size > from else { return }
        try? h.seek(toOffset: from)
        guard let data = try? h.read(upToCount: Int(size - from)) else { return }
        offsets[pid] = size
        var text = (partial[pid] ?? "") + String(decoding: data, as: UTF8.self)
        var parts = text.components(separatedBy: "\n")
        text = parts.removeLast()
        partial[pid] = text
        if first && from > 0 && !parts.isEmpty { parts.removeFirst() } // started mid-line
        for line in parts {
            lines.append(LogLine(id: nextID, pid: pid, text: line))
            nextID += 1
        }
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }
}
