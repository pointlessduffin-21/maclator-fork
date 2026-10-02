// What the launcher knows: the Maclator install, the arm64 apps on this Mac, and how each one fared.

import AppKit
import Foundation
import Security

// MARK: - Install

/// Where the pieces of a Maclator install are, and whether they are there.
struct Install {
    var maclator: URL?
    var sysroot: URL?
    var gpuBridge: URL?
    var homebrew: URL?
    var aotCache: URL
    var aotBytes: Int64

    static func discover() -> Install {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        let maclatorCandidates = [
            ProcessInfo.processInfo.environment["MACLATOR"].map { URL(fileURLWithPath: $0) },
            home.appending(path: "bin/maclator"),
            exe?.appending(path: "maclator"),
            URL(fileURLWithPath: "/usr/local/bin/maclator"),
        ].compactMap { $0 }
        let maclator = maclatorCandidates.first { fm.isExecutableFile(atPath: $0.path) }

        // Same rule as paths::discover_sysroot(): a directory holding dyld_shared_cache_arm64e.
        let sysrootBase = home.appending(path: "maclator-sysroot")
        let sysroot = ((try? fm.contentsOfDirectory(at: sysrootBase, includingPropertiesForKeys: nil)) ?? [])
            .first { fm.fileExists(atPath: $0.appending(path: "dyld_shared_cache_arm64e").path) }

        let gpuDirs = [maclator?.deletingLastPathComponent().appending(path: "gpu"), home.appending(path: ".maclator/gpu")].compactMap { $0 }
        let gpu = gpuDirs.first { fm.fileExists(atPath: $0.appending(path: "libmclbridge.dylib").path) }

        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let aot = home.appending(path: "Library/Caches/Maclator/aot")
        return Install(maclator: maclator, sysroot: sysroot, gpuBridge: gpu,
                       homebrew: fm.fileExists(atPath: brew.path) ? brew : nil,
                       aotCache: aot, aotBytes: directorySize(aot))
    }

    var ready: Bool { maclator != nil && sysroot != nil }
}

func directorySize(_ url: URL) -> Int64 {
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let f as URL in e {
        total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}

// MARK: - Apps

struct Arches: OptionSet, Hashable {
    let rawValue: Int
    static let arm64 = Arches(rawValue: 1)
    static let x86_64 = Arches(rawValue: 2)

    var label: String {
        switch self {
        case [.arm64, .x86_64]: "universal"
        case .arm64: "arm64"
        case .x86_64: "x86_64"
        default: "unknown"
        }
    }

    /// The architectures of a Mach-O (thin or fat), as spawn.rs reads them.
    static func of(_ url: URL) -> Arches {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 4096), d.count >= 8 else { return [] }
        defer { try? h.close() }
        let be = { (o: Int) -> UInt32 in d[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        let le = { (o: Int) -> UInt32 in d[o..<o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        let arm: UInt32 = 0x0100_000C, x86: UInt32 = 0x0100_0007
        var a: Arches = []
        if be(0) == 0xCAFE_BABE || be(0) == 0xCAFE_BABF {
            let stride = be(0) == 0xCAFE_BABE ? 20 : 32
            for i in 0..<min(Int(be(4)), 8) where 8 + i * stride + 4 <= d.count {
                switch be(8 + i * stride) {
                case arm: a.insert(.arm64)
                case x86: a.insert(.x86_64)
                default: break
                }
            }
        } else if le(0) == 0xFEED_FACF {
            if le(4) == arm { a.insert(.arm64) }
            if le(4) == x86 { a.insert(.x86_64) }
        }
        return a
    }
}

struct GuestApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let executable: URL
    let arches: Arches
    let sandboxed: Bool
    let electron: Bool
    /// Chromium-based (Electron, Chrome, ChatGPT, …): needs `--no-sandbox` under maclator.
    let chromium: Bool
    /// Added by hand (Add apps… or a drop) rather than found in an Applications folder.
    var added = false
    var id: String { url.path }
    var runnable: Bool { arches.contains(.arm64) }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    static func load(_ url: URL) -> GuestApp? {
        guard let b = Bundle(url: url), let info = b.infoDictionary,
              let exeName = info["CFBundleExecutable"] as? String else { return nil }
        let exe = url.appending(path: "Contents/MacOS/\(exeName)")
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let electron = FileManager.default.fileExists(atPath: url.appending(path: "Contents/Frameworks/Electron Framework.framework").path)
        return GuestApp(url: url, name: name, bundleID: b.bundleIdentifier ?? "", version: (info["CFBundleShortVersionString"] as? String) ?? "",
                        executable: exe, arches: .of(exe), sandboxed: isSandboxed(url), electron: electron,
                        chromium: electron || isChromium(url))
    }

    /// Chromium's helper apps, "… (Renderer).app" / "… (GPU).app": in Contents/Frameworks (Electron)
    /// or in the framework's Helpers directory (Chrome, ChatGPT and other Chromium builds).
    private static func isChromium(_ url: URL) -> Bool {
        let fm = FileManager.default
        let frameworks = url.appending(path: "Contents/Frameworks")
        let isHelper = { (n: String) in n.hasSuffix("(Renderer).app") || n.hasSuffix("(GPU).app") }
        let top = (try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? []
        if top.contains(where: isHelper) { return true }
        for f in top where f.hasSuffix(".framework") {
            if ((try? fm.contentsOfDirectory(atPath: frameworks.appending(path: "\(f)/Helpers").path)) ?? []).contains(where: isHelper) {
                return true
            }
        }
        return false
    }

    private static func isSandboxed(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return (ents["com.apple.security.app-sandbox"] as? Bool) == true
    }

    /// Application folders: /Applications, ~/Applications, and every mounted volume's Applications.
    static func folders() -> [URL] {
        let fm = FileManager.default
        var dirs = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appending(path: "Applications")]
        for v in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? [] {
            dirs.append(v.appending(path: "Applications"))
        }
        return dirs.filter { fm.fileExists(atPath: $0.path) }
    }

    static func scan(added: [URL] = []) -> [GuestApp] {
        var seen = Set<String>()
        var apps: [GuestApp] = []
        func consider(_ url: URL, added: Bool) {
            let real = url.resolvingSymlinksInPath().path
            guard seen.insert(real).inserted, var app = load(url), app.bundleID != Bundle.main.bundleIdentifier else { return }
            app.added = added
            apps.append(app)
        }
        for dir in folders() {
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "app" {
                consider(url, added: false)
            }
        }
        for url in added where FileManager.default.fileExists(atPath: url.path) {
            consider(url, added: true)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Apps added by hand, kept in ~/Library/Application Support/Maclator/added.json (paths).
enum AddedApps {
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Maclator/added.json")
    }

    static func load() -> [URL] {
        guard let d = try? Data(contentsOf: file), let paths = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func save(_ urls: [URL]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(urls.map(\.path)) { try? d.write(to: file, options: .atomic) }
    }

    /// The .app bundles in what was picked or dropped: apps themselves, or the apps one level
    /// inside a folder.
    static func bundles(in urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            if url.pathExtension == "app" { return [url] }
            let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return inside.filter { $0.pathExtension == "app" }
        }
    }
}

// MARK: - Compatibility

enum Verdict: String, Codable, CaseIterable {
    case works, partial, fails, untested

    var health: Health {
        switch self {
        case .works: .ok
        case .partial: .warn
        case .fails: .err
        case .untested: .down
        }
    }
    var label: String {
        switch self {
        case .works: "Works"
        case .partial: "Partly works"
        case .fails: "Doesn't run"
        case .untested: "Not tried yet"
        }
    }
}

/// One entry of the compatibility list: a verdict and a short note.
struct CompatEntry: Codable, Hashable {
    var verdict: Verdict
    var note: String
    /// Seconds to the first window, if one appeared.
    var firstWindow: Double?
    var tested: String?
}

/// The compatibility list: the bundled one (docs/compatibility.json, keyed by bundle ID), overridden
/// by what this launcher observed on this Mac (~/Library/Application Support/Maclator/compat.json).
final class CompatStore {
    private(set) var bundled: [String: CompatEntry] = [:]
    private(set) var local: [String: CompatEntry] = [:]
    private let localURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Maclator")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        localURL = support.appending(path: "compat.json")
        if let u = Bundle.main.url(forResource: "compatibility", withExtension: "json"),
           let d = try? Data(contentsOf: u), let list = try? JSONDecoder().decode(CompatFile.self, from: d) {
            bundled = Dictionary(list.apps.map { ($0.bundleID, $0.entry) }, uniquingKeysWith: { a, _ in a })
        }
        if let d = try? Data(contentsOf: localURL), let m = try? JSONDecoder().decode([String: CompatEntry].self, from: d) {
            local = m
        }
    }

    func entry(for app: GuestApp) -> CompatEntry {
        if !app.runnable { return CompatEntry(verdict: .fails, note: "No arm64 code: runs natively on this Mac instead.") }
        return local[app.bundleID] ?? bundled[app.bundleID] ?? CompatEntry(verdict: .untested, note: "")
    }

    func record(_ e: CompatEntry, for app: GuestApp) {
        local[app.bundleID] = e
        if let d = try? JSONEncoder().encode(local) { try? d.write(to: localURL, options: .atomic) }
    }
}

/// docs/compatibility.json
struct CompatFile: Codable {
    struct App: Codable {
        var name: String
        var bundleID: String
        var verdict: Verdict
        var note: String
        var firstWindow: Double?
        var tested: String?
        var entry: CompatEntry { CompatEntry(verdict: verdict, note: note, firstWindow: firstWindow, tested: tested) }
    }
    var host: String
    var apps: [App]
}
