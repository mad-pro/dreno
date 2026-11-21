import Foundation

enum Pattern: String {
    case continuo, frequente, picos, leve

    var label: String {
        switch self {
        case .continuo: return "Uso contínuo"
        case .frequente: return "Frequente"
        case .picos: return "Só picos"
        case .leve: return "Leve"
        }
    }

    var hint: String {
        switch self {
        case .continuo: return "Ficou processando por longos trechos seguidos."
        case .frequente: return "Acordou e trabalhou muitas vezes ao longo do período."
        case .picos: return "Subiu e desceu rápido. Normal."
        case .leve: return "Quase não consumiu."
        }
    }
}

struct AnalyzerSettings {
    var busyPct: Double = 2.0       // % de um núcleo pra contar como "ativo" numa amostra
    var minStreakSec: Double = 60   // trecho seguido mínimo pra contar como uso contínuo
}

enum TickFilter: Equatable {
    case all
    case battery
    case range(Date, Date)

    var label: String {
        switch self {
        case .all: return "Período inteiro"
        case .battery: return "Só enquanto estava na bateria"
        case .range(let a, let b): return "Trecho das \(Fmt.time(a)) às \(Fmt.time(b))"
        }
    }
}

enum Grouping: String, CaseIterable, Identifiable {
    case app = "Por app"
    case processo = "Por processo"
    var id: String { rawValue }
}

struct ProcRow {
    let id: Int64
    let pid: Int
    let ppid: Int
    let uid: Int
    let name: String
    let path: String?
    let rpath: String?
    let args: String?
    let first: Double
    let last: Double
}

/// O que se sabe sobre um grupo (app ou processo) pra poder explicar.
struct GroupIdentity {
    let key: String
    let displayName: String
    let mainName: String
    let path: String?
    let appPath: String?
    let appName: String?
    let bundleId: String?
    let isAppGroup: Bool
    let names: [String]
    let uids: Set<Int>
    let responsibleApps: [String]
    let commands: [String]
    let isResidual: Bool
}

struct HoldStat: Identifiable {
    var id: String { type }
    let type: String
    let seconds: Double
    let names: [String]
    var label: String { SleepHolds.label(type) }
}

struct MemberStat: Identifiable {
    let id: String
    let name: String
    let pidCount: Int
    let cpuSec: Double
    let memAvg: Double?
}

struct GroupStat: Identifiable {
    let id: String
    var identity: GroupIdentity
    var pidCount = 0
    var cpuSec = 0.0
    var aliveSec = 0.0
    var avgPctWindow = 0.0
    var avgPctAlive = 0.0
    var activeRatio = 0.0
    var longestStreakSec = 0.0
    var sustainedCpuSec = 0.0
    var peakPct = 0.0
    var energyJ = 0.0
    var energyEstimated = false
    var energyShareOfMac: Double?
    var batteryGainPct: Double?
    var wakeupsPerSec: Double?
    var gpuSec = 0.0
    var memAvg: Double?
    var memPeak: Double?
    var memGrowth: Double?
    var series: [Double] = []
    var pattern: Pattern = .leve
    var score = 0.0
    var share = 0.0
    var holds: [HoldStat] = []
    var members: [MemberStat] = []

    var sustainedShare: Double { cpuSec > 0 ? sustainedCpuSec / cpuSec : 0 }
    var holdSeconds: Double { holds.map(\.seconds).max() ?? 0 }
}

struct TickPoint: Identifiable {
    let id: Int
    let date: Date
    let busyPct: Double?
    let watts: Double?
    let battery: Double?
    let onBattery: Bool
}

struct BatterySummary {
    var hasBattery = false
    var onBatterySec = 0.0
    var startPct: Double?
    var endPct: Double?
    var drop = 0.0
    var dropPerHour: Double?
    var avgWatts: Double?
    var avgWattsOnBattery: Double?
    var peakWatts: Double?
    var energyWh: Double?
    var autonomyHours: Double?
    var autonomyBasis = ""
}

struct Report {
    let session: SessionSummary
    let filter: TickFilter
    let start: Date
    let end: Date
    let windowSec: Double
    let tickCount: Int
    let ncpu: Int
    let avgBusyPct: Double?
    let maxThermal: Int
    let maxPressure: Int
    let battery: BatterySummary
    let timeline: [TickPoint]
    let groups: [GroupStat]
    let jPerCpuSec: Double
    let settings: AnalyzerSettings

    var offenders: [GroupStat] {
        let main = groups.filter { $0.pattern == .continuo || $0.pattern == .frequente }
        if !main.isEmpty { return Array(main.prefix(20)) }
        return Array(groups.filter { $0.cpuSec > 0 }.prefix(8))
    }

    var spikes: [GroupStat] {
        let off = Set(offenders.map(\.id))
        return Array(groups.filter { $0.pattern == .picos && $0.peakPct >= 20 && !off.contains($0.id) }
            .sorted { $0.peakPct > $1.peakPct }.prefix(10))
    }

    var memoryHogs: [GroupStat] {
        Array(groups.filter { ($0.memAvg ?? 0) > 0 && !$0.identity.isResidual }
            .sorted { ($0.memAvg ?? 0) > ($1.memAvg ?? 0) }.prefix(10))
    }

    var sleepers: [GroupStat] {
        Array(groups.filter { !$0.holds.isEmpty }.sorted { $0.holdSeconds > $1.holdSeconds }.prefix(10))
    }

    /// Grupos que aparecem em alguma seção (pra explicar).
    var displayedGroups: [GroupStat] {
        var seen = Set<String>()
        var out: [GroupStat] = []
        for g in offenders + sleepers + spikes + memoryHogs where !seen.contains(g.id) {
            seen.insert(g.id)
            out.append(g)
        }
        return out
    }

    var macEnergyJ: Double? { battery.energyWh.map { $0 * 3600 } }
}

struct ReportBundle {
    var report: Report
    var explanations: [String: Explanation]
}
