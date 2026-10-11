import Foundation
import Darwin

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

func sysctlInt(_ name: String) -> Int64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
    if size == 4 { var v: Int32 = 0; guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }; return Int64(v) }
    if size == 8 { var v: Int64 = 0; guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }; return v }
    return nil
}

func cpuTypeName(_ t: Int32, _ sub: Int32) -> String {
    let s = sub & 0x00FF_FFFF
    switch t {
    case 0x0100000C: return s == 2 ? "arm64e" : "arm64"
    case 0x01000007: return "x86_64"
    case 7: return "x86"
    default: return String(format: "0x%08x", t)
    }
}

/// CPU type of the main executable, read from its Mach-O header (thin or fat).
func machOArchitecture() -> String {
    guard let url = Bundle.main.executableURL, let h = try? FileHandle(forReadingFrom: url),
          let d = try? h.read(upToCount: 4096), d.count >= 16 else { return "unknown" }
    func u32(_ o: Int, big: Bool = false) -> UInt32 {
        let v = d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return big ? v.byteSwapped : v
    }
    let magic = u32(0)
    if magic == 0xFEEDFACF { return cpuTypeName(Int32(bitPattern: u32(4)), Int32(bitPattern: u32(8))) + " (thin Mach-O)" }
    if magic == 0xBEBAFECA { // fat, big-endian fields
        let n = Int(u32(4, big: true))
        let archs = (0..<min(n, 8)).map { cpuTypeName(Int32(bitPattern: u32(8 + $0 * 20, big: true)), Int32(bitPattern: u32(12 + $0 * 20, big: true))) }
        return archs.joined(separator: ", ") + " (fat)"
    }
    return "unrecognised header"
}

struct Reading: Identifiable { let id = UUID(); let key: String; let value: String; let sysctl: String? }
struct Feature: Identifiable { let id: String; let on: Bool }

let isARMCode: Bool = {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
}()
let greetingName = isARMCode ? "ARM" : "Intel"
let historyLine = isARMCode
    ? "Acorn\u{2019}s ARM1, the first ARM processor, is said to have printed these words when it first ran on 26 April 1985."
    : "The Intel 8086, introduced in 1978, was the first processor to use the x86 instruction set that this code is written in."

struct Snapshot {
    var arch = ""
    var cputype = ""
    var verdict = ""
    var health: Health = .live
    var pageSize = ""
    var cpus = ""
    var memory = ""
    var system: [Reading] = []
    var features: [Feature] = []
    var featureTitle = ""
    var report: String = ""
}

func gather() -> Snapshot {
    var u = utsname(); uname(&u)
    let machine = withUnsafePointer(to: &u.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    #if arch(arm64)
    let compiled = "arm64"
    #else
    let compiled = "x86_64"
    #endif
    let ct = Int32(sysctlInt("hw.cputype") ?? 0), cs = Int32(sysctlInt("hw.cpusubtype") ?? 0)
    let translated = sysctlInt("sysctl.proc_translated")
    let hwArm64 = sysctlInt("hw.optional.arm64")
    let brand = sysctlString("machdep.cpu.brand_string") ?? "unknown"
    let page = Int(getpagesize())
    let mem = sysctlInt("hw.memsize") ?? 0
    let memStr = ByteCountFormatter.string(fromByteCount: mem, countStyle: .memory)
    let ncpu = sysctlInt("hw.ncpu"), phys = sysctlInt("hw.physicalcpu"), logi = sysctlInt("hw.logicalcpu")
    let fam = sysctlInt("hw.cpufamily").map { String(format: "0x%08x", UInt32(truncatingIfNeeded: $0)) } ?? "n/a"
    func n(_ v: Int64?) -> String { v.map(String.init) ?? "n/a" }

    var s = Snapshot()
    s.arch = compiled
    s.cputype = cpuTypeName(ct, cs)
    s.pageSize = "\(page / 1024) KB"
    s.cpus = n(logi ?? ncpu)
    s.memory = memStr

    let kernel = (sysctlString("kern.version") ?? "n/a").split(separator: "\n").first.map(String.init) ?? "n/a"
    s.system = [
        Reading(key: "uname machine", value: machine, sysctl: "hw.machine"),
        Reading(key: "Compiled for", value: compiled, sysctl: nil),
        Reading(key: "Image (Mach-O)", value: machOArchitecture(), sysctl: nil),
        Reading(key: "CPU type", value: "\(s.cputype)  (\(ct), subtype \(cs))", sysctl: "hw.cputype"),
        Reading(key: "Translated", value: translated.map { $0 == 1 ? "yes (Rosetta)" : "no" } ?? "n/a", sysctl: "sysctl.proc_translated"),
        Reading(key: "hw.optional.arm64", value: hwArm64.map { $0 == 1 ? "1" : "0" } ?? "absent", sysctl: "hw.optional.arm64"),
        Reading(key: "OS", value: ProcessInfo.processInfo.operatingSystemVersionString, sysctl: nil),
        Reading(key: "Product version", value: sysctlString("kern.osproductversion") ?? "n/a", sysctl: "kern.osproductversion"),
        Reading(key: "Build", value: sysctlString("kern.osversion") ?? "n/a", sysctl: "kern.osversion"),
        Reading(key: "Kernel", value: kernel, sysctl: "kern.version"),
        Reading(key: "CPU brand", value: brand, sysctl: "machdep.cpu.brand_string"),
        Reading(key: "CPUs (n / phys / log)", value: "\(n(ncpu)) / \(n(phys)) / \(n(logi))", sysctl: "hw.ncpu"),
        Reading(key: "CPU family", value: fam, sysctl: "hw.cpufamily"),
        Reading(key: "Memory", value: "\(memStr)  (\(mem) bytes)", sysctl: "hw.memsize"),
        Reading(key: "Page size", value: "\(page) bytes", sysctl: "hw.pagesize"),
    ]
    if isARMCode {
        s.featureTitle = "ARM features"
        let names = ["LSE", "CRC32", "AES", "SHA256", "FP16", "DotProd", "PAuth", "BF16", "SME"]
        s.features = names.map { Feature(id: "FEAT_\($0)", on: (sysctlInt("hw.optional.arm.FEAT_\($0)") ?? 0) == 1) }
    } else {
        s.featureTitle = "x86 features"
        let flags = Set(((sysctlString("machdep.cpu.features") ?? "") + " " + (sysctlString("machdep.cpu.leaf7_features") ?? ""))
            .split(separator: " ").map(String.init))
        let want = [("SSE4.2", "SSE4.2"), ("AVX", "AVX1.0"), ("AVX2", "AVX2"), ("AES-NI", "AES"), ("SHA", "SHA"),
                    ("FMA", "FMA"), ("BMI2", "BMI2"), ("AVX-512", "AVX512F"), ("RDRAND", "RDRAND")]
        s.features = want.map { Feature(id: $0.0, on: flags.contains($0.1)) }
    }

    if compiled != machine {
        s.verdict = "\(compiled) code; uname reports \(machine)"; s.health = .warn
    } else if compiled == "arm64" {
        if brand.localizedCaseInsensitiveContains("Intel") { s.verdict = "arm64 code on an Intel CPU, translated by Maclator" }
        else if brand.localizedCaseInsensitiveContains("Apple") { s.verdict = "arm64 code running natively on Apple silicon" }
        else { s.verdict = "arm64 code; host CPU is \(brand)" }
        s.health = .live
    } else {
        if translated == 1 { s.verdict = "x86-64 code on Apple silicon, translated by Rosetta 2" }
        else if brand.localizedCaseInsensitiveContains("Intel") { s.verdict = "x86-64 code running natively on an Intel CPU" }
        else { s.verdict = "x86-64 code; host CPU is \(brand)" }
        s.health = .live
    }

    var r = "Hello.app report\n"
    r += "Verdict: \(s.verdict)\n\n"
    for x in s.system { r += "\(x.key): \(x.value)" + (x.sysctl.map { "   [\($0)]" } ?? "") + "\n" }
    r += "\n\(s.featureTitle):\n" + s.features.map { "  \($0.id): \($0.on ? "yes" : "no")" }.joined(separator: "\n") + "\n"
    s.report = r
    return s
}

struct Usage { var uptime: TimeInterval; var rss: UInt64; var cpuTime: TimeInterval; var threads: Int }

let launchDate = Date()

func usage() -> Usage {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
    var list: thread_act_array_t?
    var tc: mach_msg_type_number_t = 0
    var threads = 0
    if task_threads(mach_task_self_, &list, &tc) == KERN_SUCCESS, let list {
        threads = Int(tc)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(tc) * MemoryLayout<thread_act_t>.size))
    }
    return Usage(uptime: Date().timeIntervalSince(launchDate), rss: kr == KERN_SUCCESS ? info.resident_size : 0, cpuTime: cpu, threads: threads)
}
