import Foundation

/// Textos comuns entre a tela, o HTML e a linha de comando.
enum ReportText {
    static func subtitle(_ g: GroupStat) -> String {
        let id = g.identity
        if id.isResidual { return "estimado pela diferença entre a CPU total e a soma dos processos" }
        var parts: [String] = []
        if id.isAppGroup {
            parts.append(g.pidCount == 1 ? "1 processo" : "\(g.pidCount) processos")
            if let first = id.names.first, first != id.displayName { parts.append("principal: \(first)") }
        } else {
            if let app = id.appName, app != id.displayName { parts.append("do app \(app)") }
            if g.pidCount > 1 { parts.append("\(g.pidCount) instâncias") }
        }
        if !id.responsibleApps.isEmpty { parts.append("aberto por \(id.responsibleApps.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    struct Metric { let value: String; let label: String }

    static func metrics(_ g: GroupStat, _ r: Report) -> [Metric] {
        var m: [Metric] = []
        m.append(Metric(value: Fmt.duration(g.cpuSec), label: "de CPU no período"))
        m.append(Metric(value: Fmt.pct(g.avgPctAlive), label: "de um núcleo, em média, enquanto rodava"))
        m.append(Metric(value: Fmt.pct(g.activeRatio * 100), label: "do tempo trabalhando"))
        m.append(Metric(value: Fmt.duration(g.longestStreakSec), label: "maior trecho seguido"))
        if let sh = g.energyShareOfMac {
            m.append(Metric(value: (g.energyEstimated ? "≈" : "") + Fmt.pct(sh * 100), label: "da energia do Mac (\(Fmt.wh(joules: g.energyJ)))"))
        } else if g.energyJ > 0 {
            m.append(Metric(value: (g.energyEstimated ? "≈" : "") + Fmt.wh(joules: g.energyJ), label: "de energia de CPU"))
        }
        if g.gpuSec >= 1 { m.append(Metric(value: Fmt.pct(g.gpuSec / max(r.windowSec, 1) * 100), label: "de GPU em média")) }
        if let w = g.wakeupsPerSec, w >= 20 { m.append(Metric(value: Fmt.num(w, 0) + "/s", label: "despertares da CPU")) }
        if let mem = g.memAvg { m.append(Metric(value: Fmt.bytes(mem), label: "de memória em média")) }
        return m
    }

    static func verdict(_ g: GroupStat, _ ex: Explanation?) -> String {
        if g.identity.isResidual { return "" }
        var s = "\(g.pattern.label): \(g.pattern.hint)"
        let stop = ex?.stop ?? "cuidado"
        if let gain = g.batteryGainPct, gain >= 1, stop == "sim" || stop == "cuidado" {
            s += " Sem ele, a bateria duraria uns \(Fmt.pct(gain)) a mais nesse ritmo."
        } else if let sh = g.energyShareOfMac, sh >= 0.02, stop == "reduzir" {
            s += " Responde por \(g.energyEstimated ? "uns " : "")\(Fmt.pct(sh * 100)) da energia do Mac nesse período."
        }
        if let growth = g.memGrowth, growth >= 300_000_000 {
            s += " A memória cresceu \(Fmt.bytes(growth)) durante a gravação."
        }
        return s
    }

    static func batteryLine(_ r: Report) -> String {
        let b = r.battery
        var parts: [String] = []
        if let a = b.startPct, let z = b.endPct { parts.append("Bateria \(Int(a.rounded()))% → \(Int(z.rounded()))%") }
        if b.onBatterySec > 0 { parts.append("\(Fmt.duration(b.onBatterySec)) na bateria") } else if b.hasBattery { parts.append("na tomada o tempo todo") }
        if let d = b.dropPerHour { parts.append("caiu \(Fmt.num(d, 1))% por hora") }
        return parts.joined(separator: " · ")
    }

    static func thermal(_ v: Int) -> String {
        switch v {
        case 0: return "Normal"
        case 1: return "Morno"
        case 2: return "Quente"
        default: return "Muito quente"
        }
    }

    static let methodNotes: [String] = [
        "CPU: tempo de processador de cada processo, medido a cada amostra para todos os processos do Mac. 100% é um núcleo inteiro ocupado.",
        "Uso contínuo: o processo passou de 2% de um núcleo em amostras seguidas por pelo menos 1 minuto. Picos curtos não entram nessa conta.",
        "Energia: medida pelo próprio macOS para os processos do seu usuário. Para processos do sistema é estimada pelo tempo de CPU (marcada com ≈). Não inclui a tela.",
        "Energia do Mac: consumo total em watts lido da telemetria da bateria, inclusive tela, SSD e rede.",
        "GPU: tempo de uso da placa de vídeo por processo.",
        "Kernel e processos de vida curta: diferença entre a CPU total do Mac e a soma dos processos acompanhados. Inclui o kernel_task e programas que abriram e fecharam entre duas amostras.",
    ]
}
