import Foundation

/// Versão em texto do relatório (linha de comando).
enum TextReport {
    static func render(_ b: ReportBundle) -> String {
        let r = b.report
        var out: [String] = []
        out.append("== Dreno: \(r.session.displayTitle) ==")
        out.append("\(Fmt.long(r.start)) até \(Fmt.time(r.end)) · \(Fmt.duration(r.windowSec)) · \(r.tickCount) amostras · \(r.filter.label)")
        var sys: [String] = []
        if let busy = r.avgBusyPct { sys.append("CPU do Mac \(Fmt.pct(busy))") }
        if let w = r.battery.avgWatts { sys.append("consumo médio \(Fmt.watts(w))") }
        if let wh = r.battery.energyWh { sys.append("\(Fmt.num(wh, 2)) Wh") }
        if let a = r.battery.autonomyHours { sys.append("autonomia ~\(Fmt.hours(a)) (\(r.battery.autonomyBasis))") }
        let bl = ReportText.batteryLine(r)
        if !bl.isEmpty { sys.append(bl) }
        sys.append("J por s de CPU: \(Fmt.num(r.jPerCpuSec, 2))")
        out.append(sys.joined(separator: " · "))
        out.append("")
        out.append("-- O que mais pesou --")
        for (i, g) in r.offenders.enumerated() {
            out.append("\(i + 1). \(g.identity.displayName) [\(g.pattern.label)] \(ReportText.subtitle(g))")
            out.append("   " + ReportText.metrics(g, r).map { "\($0.value) \($0.label)" }.joined(separator: " | "))
            if let ex = b.explanations[g.id] {
                out.append("   > \(ex.title) (\(ex.source); \(Labels.stop(ex.stop)))")
                out.append("   > \(ex.what)")
            }
        }
        if !r.sleepers.isEmpty {
            out.append("")
            out.append("-- Impediram o Mac de dormir --")
            for g in r.sleepers {
                for h in g.holds { out.append("- \(g.identity.displayName): \(h.label) por \(Fmt.duration(h.seconds)) (\(h.names.prefix(2).joined(separator: "; ")))") }
            }
        }
        if !r.spikes.isEmpty {
            out.append("")
            out.append("-- Só picos --")
            for g in r.spikes { out.append("- \(g.identity.displayName): pico \(Fmt.pct(g.peakPct)), \(Fmt.duration(g.cpuSec)) de CPU") }
        }
        if !r.memoryHogs.isEmpty {
            out.append("")
            out.append("-- Memória --")
            for g in r.memoryHogs { out.append("- \(g.identity.displayName): \(Fmt.bytes(g.memAvg ?? 0)) em média") }
        }
        return out.joined(separator: "\n")
    }
}
