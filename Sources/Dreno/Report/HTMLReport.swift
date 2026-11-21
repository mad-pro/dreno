import Foundation

/// Relatório HTML autocontido (abre no navegador, dá pra imprimir em PDF).
enum HTMLReport {
    static func render(_ b: ReportBundle) -> String {
        let r = b.report
        var h = """
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Relatório Dreno</title><style>\(css)</style></head><body><main>
        """
        h += "<header><p class=\"eyebrow\">Relatório do Dreno</p><h1>\(esc(r.session.displayTitle))</h1>"
        h += "<p class=\"muted\">\(esc(Fmt.long(r.start))) até \(esc(Fmt.time(r.end))) · \(esc(Fmt.duration(r.windowSec))) · \(esc(r.filter.label)) · \(esc(r.session.host ?? MacInfo.model)) · amostra a cada \(Int(r.session.interval)) s</p></header>"

        h += "<section class=\"stats\">"
        h += stat(Fmt.duration(r.windowSec), "gravados", "\(r.tickCount) amostras")
        if let wh = r.battery.energyWh { h += stat(Fmt.num(wh, 1) + " Wh", "de energia do Mac", r.battery.avgWatts.map { "média de \(Fmt.watts($0))" } ?? "") }
        if r.battery.hasBattery { h += stat(r.battery.endPct.map { "\(Int($0.rounded()))%" } ?? "-", "bateria no fim", ReportText.batteryLine(r)) }
        if let a = r.battery.autonomyHours { h += stat(Fmt.hours(a), "de autonomia nesse ritmo", r.battery.autonomyBasis) }
        if let busy = r.avgBusyPct { h += stat(Fmt.pct(busy), "de CPU do Mac em média", "\(r.ncpu) núcleos") }
        h += stat(ReportText.thermal(r.maxThermal), "temperatura máxima", r.session.overhead.map { "Dreno usou \(Fmt.num($0, 2))% de CPU" } ?? "")
        h += "</section>"

        h += timeline(r)

        h += "<h2>O que mais pesou</h2><p class=\"sub\">Uso contínuo ou frequente. É aqui que a bateria vai embora.</p>"
        if r.offenders.isEmpty { h += "<p class=\"muted\">Nada ficou em uso contínuo nesse período.</p>" }
        for (i, g) in r.offenders.enumerated() { h += card(i + 1, g, b.explanations[g.id], r) }

        if !r.sleepers.isEmpty {
            h += "<h2>Impediram o Mac de dormir</h2><p class=\"sub\">Seguraram o sono do Mac ou a tela acesa. Gasta bateria mesmo parado.</p><table><tr><th>Quem</th><th>O quê</th><th>Por quanto tempo</th><th>Motivo informado</th></tr>"
            for g in r.sleepers {
                for hs in g.holds.prefix(2) {
                    h += "<tr><td>\(esc(g.identity.displayName))</td><td>\(esc(hs.label))</td><td>\(esc(Fmt.duration(hs.seconds)))</td><td class=\"muted small\">\(esc(hs.names.prefix(2).joined(separator: "; ")))</td></tr>"
                }
            }
            h += "</table>"
        }
        if !r.spikes.isEmpty {
            h += "<h2>Só picos</h2><p class=\"sub\">Subiram e desceram rápido. Isso é normal.</p>" + table(r.spikes, b, valueTitle: "Pico") { Fmt.pct($0.peakPct) }
        }
        if !r.memoryHogs.isEmpty {
            h += "<h2>Memória</h2><p class=\"sub\">Quem mais ocupou memória em média.</p>" + table(r.memoryHogs, b, valueTitle: "Média") { g in
                Fmt.bytes(g.memAvg ?? 0) + (g.memPeak.map { " (pico \(Fmt.bytes($0)))" } ?? "")
            }
        }
        h += "<h2>Como ler</h2><ul class=\"notes\">" + ReportText.methodNotes.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
        h += "<footer>Gerado pelo Dreno em \(esc(Fmt.long(Date())))</footer></main></body></html>"
        return h
    }

    private static func stat(_ value: String, _ label: String, _ detail: String) -> String {
        "<div class=\"stat\"><div class=\"v\">\(esc(value))</div><div class=\"l\">\(esc(label))</div><div class=\"d\">\(esc(detail))</div></div>"
    }

    private static func card(_ rank: Int, _ g: GroupStat, _ ex: Explanation?, _ r: Report) -> String {
        var h = "<section class=\"card\"><div class=\"head\"><div class=\"rank\">\(rank)</div><div class=\"name\"><h3>\(esc(g.identity.displayName))</h3>"
        h += "<div class=\"muted small\">\(esc(ReportText.subtitle(g)))</div></div>"
        h += "<span class=\"badge \(g.pattern.rawValue)\">\(esc(g.pattern.label))</span>\(sparkline(g.series))</div>"
        h += "<div class=\"metrics\">" + ReportText.metrics(g, r).map { "<div><b>\(esc($0.value))</b><span>\(esc($0.label))</span></div>" }.joined() + "</div>"
        let verdict = ReportText.verdict(g, ex)
        if !verdict.isEmpty { h += "<p class=\"verdict\">\(esc(verdict))</p>" }
        if let ex {
            h += "<div class=\"ex\"><p class=\"ex-title\">\(esc(ex.title))</p>"
            if !ex.what.isEmpty { h += "<p><b>O que é.</b> \(esc(ex.what))</p>" }
            if !ex.why.isEmpty { h += "<p><b>Por que consome.</b> \(esc(ex.why))</p>" }
            if !ex.fix.isEmpty { h += "<p><b>O que fazer.</b> \(esc(ex.fix))</p>" }
            if let cmd = ex.stopCommand { h += "<p class=\"small\"><b>Pra parar agora no Terminal:</b> <code>\(esc(cmd))</code></p>" }
            var pills = [Labels.kind(ex.kind), Labels.stop(ex.stop), "Fonte: " + ex.source]
            if let c = ex.confidence { pills.append("confiança \(c)") }
            h += "<div class=\"pills\">" + pills.map { "<span>\(esc($0))</span>" }.joined() + "</div></div>"
            var details = ""
            if !ex.facts.isEmpty {
                details += "<table class=\"facts\">" + ex.facts.map { "<tr><th>\(esc($0.label))</th><td>\(esc($0.value).replacingOccurrences(of: "\n", with: "<br>"))</td></tr>" }.joined() + "</table>"
            }
            if g.members.count > 1 {
                details += "<p class=\"small\"><b>Processos do grupo</b></p><table class=\"facts\">"
                for m in g.members.prefix(8) {
                    details += "<tr><th>\(esc(m.name))\(m.pidCount > 1 ? " ×\(m.pidCount)" : "")</th><td>\(esc(Fmt.duration(m.cpuSec))) de CPU\(m.memAvg.map { " · " + Fmt.bytes($0) } ?? "")</td></tr>"
                }
                details += "</table>"
            }
            if !g.holds.isEmpty {
                details += "<p class=\"small\">" + g.holds.map { esc("\($0.label) por \(Fmt.duration($0.seconds))") }.joined(separator: " · ") + "</p>"
            }
            if !details.isEmpty { h += "<details><summary>Detalhes técnicos</summary>\(details)</details>" }
        }
        return h + "</section>"
    }

    private static func table(_ groups: [GroupStat], _ b: ReportBundle, valueTitle: String, value: (GroupStat) -> String) -> String {
        var h = "<table><tr><th>Quem</th><th>\(esc(valueTitle))</th><th>CPU no período</th><th>O que é</th></tr>"
        for g in groups {
            let ex = b.explanations[g.id]
            let what = ex.map { $0.title + ". " + firstSentence($0.what) } ?? ""
            h += "<tr><td><b>\(esc(g.identity.displayName))</b></td><td>\(esc(value(g)))</td><td>\(esc(Fmt.duration(g.cpuSec)))</td><td class=\"muted small\">\(esc(what))</td></tr>"
        }
        return h + "</table>"
    }

    static func firstSentence(_ s: String) -> String {
        if let r = s.range(of: ". ") { return String(s[..<r.lowerBound]) + "." }
        return s
    }

    private static func sparkline(_ v: [Double]) -> String {
        guard v.count > 1 else { return "" }
        let w = 150.0, hgt = 34.0
        let mx = max(v.max() ?? 1, 5)
        let pts = v.enumerated().map { i, y in
            String(format: "%.1f,%.1f", w * Double(i) / Double(v.count - 1), hgt - (y / mx) * (hgt - 2) - 1)
        }.joined(separator: " ")
        return "<svg class=\"spark\" viewBox=\"0 0 \(Int(w)) \(Int(hgt))\" width=\"\(Int(w))\" height=\"\(Int(hgt))\"><polyline points=\"\(pts)\"/></svg>"
    }

    private static func timeline(_ r: Report) -> String {
        let pts = r.timeline
        guard pts.count > 1, let t0 = pts.first?.date, let t1 = pts.last?.date, t1 > t0 else { return "" }
        let w = 960.0, hgt = 150.0
        let span = t1.timeIntervalSince(t0)
        func x(_ d: Date) -> Double { w * d.timeIntervalSince(t0) / span }
        var area = "M0,\(hgt)"
        for p in pts { area += String(format: " L%.1f,%.1f", x(p.date), hgt - (p.busyPct ?? 0) / 100 * (hgt - 4)) }
        area += " L\(w),\(hgt) Z"
        let maxW = max(pts.compactMap(\.watts).max() ?? 0, 1)
        let wpts = pts.compactMap { p in p.watts.map { String(format: "%.1f,%.1f", x(p.date), hgt - $0 / maxW * (hgt - 8) - 2) } }.joined(separator: " ")
        var h = "<h2>Linha do tempo</h2><p class=\"sub\">Área azul: CPU do Mac inteiro (0 a 100%). Linha laranja: consumo em watts (máximo \(esc(Fmt.watts(maxW)))).</p>"
        h += "<svg class=\"timeline\" viewBox=\"0 0 \(Int(w)) \(Int(hgt))\" preserveAspectRatio=\"none\"><path class=\"cpu\" d=\"\(area)\"/>"
        if !wpts.isEmpty { h += "<polyline class=\"watts\" points=\"\(wpts)\"/>" }
        h += "</svg><div class=\"axis\"><span>\(esc(Fmt.time(t0)))</span><span>\(esc(Fmt.time(t1)))</span></div>"
        return h
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root{--bg:#f6f7f9;--fg:#15171a;--muted:#62676f;--card:#fff;--border:#e3e5e8;--accent:#2f6fde;--accent-soft:rgba(47,111,222,.18);--orange:#e07b16;--red:#d23b3b;--green:#2a9d5c;--chip:#eef0f3}
    @media (prefers-color-scheme:dark){:root{--bg:#141518;--fg:#eceef1;--muted:#9aa0a8;--card:#1d1f23;--border:#2c2f35;--accent:#6c9dff;--accent-soft:rgba(108,157,255,.22);--orange:#f39a3d;--red:#f06464;--green:#4cc485;--chip:#272a30}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif}
    main{max-width:1000px;margin:0 auto;padding:32px 16px 48px}
    header h1{margin:2px 0 6px;font-size:28px;letter-spacing:-.01em}.eyebrow{margin:0;color:var(--accent);font-weight:600;font-size:13px;text-transform:uppercase;letter-spacing:.06em}
    h2{margin:36px 0 2px;font-size:20px}.sub{margin:0 0 14px;color:var(--muted)}.muted{color:var(--muted)}.small{font-size:13px}
    .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin-top:22px}
    .stat{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:12px 14px}.stat .v{font-size:22px;font-weight:650}.stat .l{font-size:13px}.stat .d{font-size:12px;color:var(--muted);margin-top:2px}
    .timeline{width:100%;height:150px;background:var(--card);border:1px solid var(--border);border-radius:12px}.timeline .cpu{fill:var(--accent-soft);stroke:var(--accent);stroke-width:1}.timeline .watts{fill:none;stroke:var(--orange);stroke-width:1.5}
    .axis{display:flex;justify-content:space-between;color:var(--muted);font-size:12px;margin-top:4px}
    .card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:16px 18px;margin:12px 0}
    .head{display:flex;align-items:center;gap:12px;flex-wrap:wrap}.rank{width:28px;height:28px;border-radius:50%;background:var(--chip);display:grid;place-items:center;font-weight:650;font-size:13px}
    .name{flex:1;min-width:180px}.name h3{margin:0;font-size:17px}
    .badge{font-size:12px;font-weight:600;padding:3px 9px;border-radius:999px;background:var(--chip)}.badge.continuo{background:var(--red);color:#fff}.badge.frequente{background:var(--orange);color:#fff}
    .spark{flex:none}.spark polyline{fill:none;stroke:var(--accent);stroke-width:1.5}
    .metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px 16px;margin:14px 0 6px}.metrics b{display:block;font-size:16px}.metrics span{font-size:12px;color:var(--muted)}
    .verdict{margin:8px 0;font-weight:500}.ex{border-top:1px solid var(--border);margin-top:10px;padding-top:10px}.ex p{margin:6px 0}.ex-title{font-weight:650;font-size:15px}
    .pills{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}.pills span{font-size:12px;background:var(--chip);border-radius:6px;padding:2px 8px;color:var(--muted)}
    code{font:12px ui-monospace,Menlo,monospace;background:var(--chip);padding:2px 6px;border-radius:5px;word-break:break-all}
    details{margin-top:10px}summary{cursor:pointer;color:var(--accent);font-size:14px}
    table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--border);border-radius:12px;overflow:hidden;font-size:14px}
    th,td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--border);vertical-align:top}tr:last-child th,tr:last-child td{border-bottom:none}
    table.facts{margin-top:8px;font-size:13px}table.facts th{width:150px;color:var(--muted);font-weight:500}table.facts td{word-break:break-word}
    .notes{color:var(--muted);font-size:14px;padding-left:18px}footer{margin-top:32px;color:var(--muted);font-size:12px}
    @media print{body{background:#fff}.card,.stat,table{break-inside:avoid}}
    """
}
