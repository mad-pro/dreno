import Foundation
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - Lista de processos (ps é setuid root: enxerga CPU de todos os processos sem senha)

struct PSRow {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let cpuTime: Double   // segundos acumulados (user + sys)
    let rss: Double       // bytes
    let command: String   // caminho completo quando disponível
}

enum ProcessLister {
    static func list() -> [PSRow] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,uid=,time=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var rows: [PSRow] = []
        rows.reserveCapacity(1024)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let uid = UInt32(parts[2]),
                  let rssKB = Double(parts[4]) else { continue }
            let cmd = parts[5].trimmingCharacters(in: .whitespaces)
            rows.append(PSRow(pid: pid, ppid: ppid, uid: uid, cpuTime: parseCPUTime(parts[3]), rss: rssKB * 1024, command: cmd))
        }
        return rows
    }

    /// Aceita "221:34.48", "1:02:03" e "2-01:02:03".
    static func parseCPUTime(_ s: Substring) -> Double {
        var days = 0.0
        var rest = s
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        var total = 0.0
        for c in rest.split(separator: ":") { total = total * 60 + (Double(c) ?? 0) }
        return days * 86400 + total
    }
}

// MARK: - Dados por processo via libproc (só processos do próprio usuário)

struct ProcUsage {
    let cpuNs: UInt64
    let energyNJ: UInt64
    let idleWakeups: UInt64
    let footprint: UInt64
}

enum ProcInfo {
    /// No Apple Silicon os tempos do rusage vêm em ticks de mach_absolute_time.
    static let timebase: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    static func usage(_ pid: Int32) -> ProcUsage? {
        var ru = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &ru) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard r == 0 else { return nil }
        let ticks = ru.ri_user_time &+ ru.ri_system_time
        return ProcUsage(cpuNs: UInt64(Double(ticks) * timebase), energyNJ: ru.ri_energy_nj,
                         idleWakeups: ru.ri_pkg_idle_wkups, footprint: ru.ri_phys_footprint)
    }

    static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private static let respFn: RespFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(s, to: RespFn.self)
    }()

    /// App "responsável" pelo processo (ex.: Safari para os WebContent). Só funciona no mesmo usuário.
    static func responsible(_ pid: Int32) -> Int32? {
        guard let f = respFn else { return nil }
        let r = f(pid)
        return (r > 0 && r != pid) ? r : nil
    }

    private static let interpreters: Set<String> = ["node", "python", "Python", "ruby", "java", "php", "bun", "deno", "perl", "dotnet", "sh", "bash", "zsh"]

    static func wantsArgs(_ name: String) -> Bool {
        interpreters.contains(name) || name.hasPrefix("python3")
    }

    /// Linha de comando (KERN_PROCARGS2). Fica só no banco local.
    static func args(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 8 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        var start = i
        while i < size && out.count < Int(argc) {
            if buf[i] == 0 {
                out.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return out
    }

    static func summarize(args: [String]) -> String {
        let home = NSHomeDirectory()
        let parts = args.prefix(6).map { a -> String in
            let s = a.replacingOccurrences(of: home, with: "~")
            return s.count > 90 ? String(s.prefix(90)) + "…" : s
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - GPU por processo (IOAccelerator user clients, tempo em ns)

enum GPUProbe {
    static func times() -> [Int32: UInt64] {
        var out: [Int32: UInt64] = [:]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        var acc = IOIteratorNext(it)
        while acc != 0 {
            var ci: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(acc, kIOServicePlane, &ci) == KERN_SUCCESS {
                var c = IOIteratorNext(ci)
                while c != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                       let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]],
                       let first = creator.split(separator: ",").first,
                       let pid = Int32(first.replacingOccurrences(of: "pid", with: "").trimmingCharacters(in: .whitespaces)) {
                        let total = usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                        out[pid, default: 0] &+= total
                    }
                    IOObjectRelease(c)
                    c = IOIteratorNext(ci)
                }
                IOObjectRelease(ci)
            }
            IOObjectRelease(acc)
            acc = IOIteratorNext(it)
        }
        return out
    }
}

// MARK: - CPU total da máquina

enum HostCPU {
    private static let host = mach_host_self()

    static func ticks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let u = UInt64(info.cpu_ticks.0), s = UInt64(info.cpu_ticks.1), i = UInt64(info.cpu_ticks.2), n = UInt64(info.cpu_ticks.3)
        return (u + s + n, u + s + i + n)
    }
}

// MARK: - Bateria e consumo em watts

struct PowerReading {
    var hasBattery = false
    var percent: Double?
    var onBattery = false
    var charging = false
    var watts: Double?          // consumo total do sistema (PowerTelemetryData.SystemLoad)
    var nominalMah: Double?
    var minutesToEmpty: Int?
}

enum PowerProbe {
    static func read() -> PowerReading {
        var r = PowerReading()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return r }
        defer { IOObjectRelease(svc) }
        func prop(_ k: String) -> Any? {
            IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        r.hasBattery = (prop("BatteryInstalled") as? Bool) ?? true
        if let cur = (prop("CurrentCapacity") as? NSNumber)?.doubleValue,
           let mx = (prop("MaxCapacity") as? NSNumber)?.doubleValue, mx > 0 {
            r.percent = mx <= 100 ? cur : cur / mx * 100
        }
        let external = (prop("ExternalConnected") as? Bool) ?? false
        r.onBattery = !external
        r.charging = (prop("IsCharging") as? Bool) ?? false
        if let tel = prop("PowerTelemetryData") as? [String: Any],
           let load = (tel["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            r.watts = load / 1000
        } else if !external,
                  let v = (prop("Voltage") as? NSNumber)?.doubleValue,
                  let a = (prop("InstantAmperage") as? NSNumber)?.int64Value, a < 0 {
            r.watts = v / 1000 * Double(-a) / 1000
        }
        r.nominalMah = (prop("NominalChargeCapacity") as? NSNumber)?.doubleValue
        if let m = (prop("AvgTimeToEmpty") as? NSNumber)?.intValue, m > 0, m < 65535 { r.minutesToEmpty = m }
        return r
    }
}

// MARK: - Quem está impedindo o Mac de dormir

struct HoldSample {
    let pid: Int32
    let type: String
    let name: String
}

enum SleepHolds {
    static let relevant: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion",
        "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion",
    ]

    static func read() -> [HoldSample] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var out: [HoldSample] = []
        for (pid, list) in d {
            for a in list {
                guard let type = a["AssertType"] as? String, relevant.contains(type) else { continue }
                // Quando o sistema segura em nome de outro app (ex.: coreaudiod pelo app que usa o microfone)
                var owner = pid.int32Value
                if let ob = (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value, ob > 0 { owner = ob }
                out.append(HoldSample(pid: owner, type: type, name: (a["AssertName"] as? String) ?? ""))
            }
        }
        return out
    }

    /// Asserções normais que não interessam no relatório.
    static func isNoise(_ name: String) -> Bool {
        name.hasPrefix("Powerd - Prevent sleep while display is on")
    }

    /// Traduz os nomes técnicos das asserções em algo legível.
    static func describe(_ rawNames: [String]) -> [String] {
        var out: [String] = []
        for raw in rawNames {
            for name in raw.split(separator: "\n").map(String.init) {
                let d: String
                if name.contains("Microphone") { d = "microfone em uso" }
                else if name.contains("Speaker") { d = "alto-falante em uso" }
                else if name.hasPrefix("com.apple.audio.") { d = "dispositivo de áudio aberto" }
                else if name.localizedCaseInsensitiveContains("video") || name.localizedCaseInsensitiveContains("playing") { d = "vídeo ou mídia tocando" }
                else if name == "Electron" || name.hasPrefix("Chrome") { d = "pedido do próprio app (\(name))" }
                else { d = name.count > 70 ? String(name.prefix(70)) + "…" : name }
                if !out.contains(d) { out.append(d) }
            }
        }
        return out
    }

    static func label(_ type: String) -> String {
        switch type {
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": return "Manteve a tela acesa"
        case "PreventSystemSleep": return "Impediu o sono do sistema"
        default: return "Impediu o Mac de dormir"
        }
    }
}

// MARK: - Diversos

enum MemoryPressure {
    static func level() -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0)
        return Int(v)
    }
}

enum MacInfo {
    static let model: String = sysctlString("hw.model") ?? "Mac"
    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()
    static let ncpu = ProcessInfo.processInfo.activeProcessorCount

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func userName(uid: Int) -> String {
        if uid == Int(getuid()) { return "você" }
        if uid == 0 { return "root (sistema)" }
        if let pw = getpwuid(uid_t(uid)) { return String(cString: pw.pointee.pw_name) + " (sistema)" }
        return "uid \(uid)"
    }

    static func tilde(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}
