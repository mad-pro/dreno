import SwiftUI
import Charts
import UniformTypeIdentifiers

struct ReportView: View {
    let session: SessionSummary
    @Environment(AppModel.self) private var model
    @State private var bundle: ReportBundle?
    @State private var loading = false
    @State private var filterMode: FilterMode = .all
    @State private var grouping: Grouping = .app
    @State private var selection: ClosedRange<Date>?
    @State private var appliedRange: ClosedRange<Date>?
    @State private var aiStatus: String?
    @State private var refresh = 0

    enum FilterMode: String, CaseIterable, Identifiable {
        case all = "Tudo"
        case battery = "Só na bateria"
        case range = "Trecho escolhido"
        var id: String { rawValue }
    }

    private var filter: TickFilter {
        switch filterMode {
        case .all: return .all
        case .battery: return .battery
        case .range: return appliedRange.map { .range($0.lowerBound, $0.upperBound) } ?? .all
        }
    }

    private var loadKey: String {
        let r = appliedRange.map { "\($0.lowerBound.timeIntervalSince1970)-\($0.upperBound.timeIntervalSince1970)" } ?? ""
        return "\(session.id)|\(filterMode.rawValue)|\(grouping.rawValue)|\(r)|\(refresh)|\(model.busyPct)"
    }

    private var isLive: Bool { model.currentSessionId == session.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReportHeader(session: session, isLive: isLive)
                controls
                if let b = bundle {
                    ReportContent(bundle: b, selection: $selection, aiAvailable: AIExplainer.isConfigured,
                                  onApplyRange: applyRange, onAskAI: askAI)
                        .opacity(loading ? 0.5 : 1)
                } else {
                    ProgressView("Calculando…").frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(24)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: loadKey) { await load() }
        .toolbar {
            ToolbarItem {
                Button { exportHTML() } label: { Label("Exportar relatório", systemImage: "square.and.arrow.up") }
                    .disabled(bundle == nil)
                    .help("Salvar o relatório em HTML")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Período", selection: $filterMode) {
                ForEach(FilterMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            Picker("Agrupar", selection: $grouping) {
                ForEach(Grouping.allCases) { g in Text(g.rawValue).tag(g) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            if isLive {
                Button { refresh += 1 } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
            }
            Spacer()
            if let s = aiStatus {
                ProgressView().controlSize(.small)
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func applyRange() {
        guard let s = selection else { return }
        appliedRange = s
        filterMode = .range
    }

    private func load() async {
        loading = true
        let s = session, f = filter, g = grouping, st = model.analyzerSettings
        let result: ReportBundle? = await Task.detached(priority: .userInitiated) {
            guard let db = try? Database(path: Paths.database.path) else { return nil }
            let r = Analyzer.run(db: db, session: s, filter: f, grouping: g, settings: st)
            return ReportBundle(report: r, explanations: Explainer.explainAll(r.displayedGroups))
        }.value
        bundle = result
        loading = false
        await autoAI()
    }

    /// Pede à IA explicação dos grupos que não estão na base curada (fica em cache).
    private func autoAI() async {
        guard AIExplainer.isConfigured, let b = bundle else { return }
        let items = Array(b.report.displayedGroups.filter { g in
            guard let ex = b.explanations[g.id] else { return false }
            return ex.canAskAI && !ex.source.hasPrefix("IA")
        }.prefix(10))
        guard !items.isEmpty else { return }
        var done = 0
        aiStatus = "Pedindo explicações pra IA (0 de \(items.count))"
        for start in stride(from: 0, to: items.count, by: 3) {
            if Task.isCancelled { break }
            let chunk = Array(items[start..<min(start + 3, items.count)])
            await withTaskGroup(of: (String, Explanation?).self) { tg in
                for g in chunk {
                    guard let base = b.explanations[g.id] else { continue }
                    tg.addTask { (g.id, try? await Explainer.askAI(g, base: base)) }
                }
                for await (id, ex) in tg {
                    done += 1
                    if let ex { bundle?.explanations[id] = ex }
                    aiStatus = "Pedindo explicações pra IA (\(done) de \(items.count))"
                }
            }
        }
        aiStatus = nil
    }

    private func askAI(_ g: GroupStat) {
        guard let base = bundle?.explanations[g.id] else { return }
        aiStatus = "Pedindo explicação de \(g.identity.displayName)…"
        Task {
            do {
                bundle?.explanations[g.id] = try await Explainer.askAI(g, base: base)
            } catch {
                model.errorMessage = error.localizedDescription
            }
            aiStatus = nil
        }
    }

    private func exportHTML() {
        guard let b = bundle else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "dreno-\(Fmt.stamp(b.report.start)).html"
        panel.directoryURL = Paths.reportsDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HTMLReport.render(b).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            model.errorMessage = "Não consegui salvar: \(error.localizedDescription)"
        }
    }
}

struct ReportHeader: View {
    let session: SessionSummary
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(session.displayTitle).font(.title2.weight(.semibold))
                if isLive {
                    Label("gravando", systemImage: "record.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts = [Fmt.long(session.started), Fmt.duration(session.duration)]
        if let h = session.host { parts.append(h) }
        parts.append("amostra a cada \(Int(session.interval)) s")
        return parts.joined(separator: " · ")
    }
}

struct ReportContent: View {
    let bundle: ReportBundle
    @Binding var selection: ClosedRange<Date>?
    let aiAvailable: Bool
    let onApplyRange: () -> Void
    let onAskAI: (GroupStat) -> Void

    var body: some View {
        let r = bundle.report
        VStack(alignment: .leading, spacing: 22) {
            if r.tickCount == 0 {
                ContentUnavailableView(
                    "Sem amostras nesse filtro",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Troque o período. Se escolheu Só na bateria, essa gravação pode ter sido toda na tomada.")
                )
            } else {
                SummaryGrid(report: r)
                TimelineSection(points: r.timeline, selection: $selection, onApply: onApplyRange)
                SectionHeader(title: "O que mais pesou", subtitle: "Uso contínuo ou frequente. É aqui que a bateria vai embora.")
                ForEach(Array(r.offenders.enumerated()), id: \.element.id) { item in
                    GroupCard(rank: item.offset + 1, group: item.element, explanation: bundle.explanations[item.element.id],
                              report: r, aiAvailable: aiAvailable, onAskAI: onAskAI)
                }
                if !r.sleepers.isEmpty { SleepSection(groups: r.sleepers) }
                if !r.spikes.isEmpty {
                    CompactSection(title: "Só picos", subtitle: "Subiram e desceram rápido. Isso é normal.",
                                   groups: r.spikes, explanations: bundle.explanations) { "pico de \(Fmt.pct($0.peakPct))" }
                }
                if !r.memoryHogs.isEmpty {
                    CompactSection(title: "Memória", subtitle: "Quem mais ocupou memória em média.",
                                   groups: r.memoryHogs, explanations: bundle.explanations) { g in
                        var s = Fmt.bytes(g.memAvg ?? 0)
                        if let growth = g.memGrowth, growth >= 300_000_000 { s += ", cresceu \(Fmt.bytes(growth))" }
                        return s
                    }
                }
                MethodNotes()
            }
        }
    }
}

struct SummaryGrid: View {
    let report: Report

    var body: some View {
        let r = report
        AdaptiveGrid(minWidth: 175, spacing: 10) {
            StatCard(value: Fmt.duration(r.windowSec), label: "gravados", detail: "\(r.tickCount) amostras")
            if let wh = r.battery.energyWh {
                StatCard(value: Fmt.num(wh, 1) + " Wh", label: "de energia do Mac",
                         detail: r.battery.avgWatts.map { "média de \(Fmt.watts($0)), pico de \(Fmt.watts(r.battery.peakWatts ?? $0))" } ?? "")
            }
            if r.battery.hasBattery {
                StatCard(value: r.battery.endPct.map { "\(Int($0.rounded()))%" } ?? "-", label: "de bateria no fim", detail: ReportText.batteryLine(r))
            }
            if let a = r.battery.autonomyHours {
                StatCard(value: Fmt.hours(a), label: "de autonomia nesse ritmo", detail: r.battery.autonomyBasis)
            }
            if let busy = r.avgBusyPct {
                StatCard(value: Fmt.pct(busy), label: "de CPU do Mac em média", detail: "\(r.ncpu) núcleos no total")
            }
            StatCard(value: ReportText.thermal(r.maxThermal), label: "temperatura máxima",
                     detail: r.session.overhead.map { "o Dreno usou \(Fmt.num($0, 2))% de CPU" } ?? "")
        }
    }
}

struct TimelineSection: View {
    let points: [TickPoint]
    @Binding var selection: ClosedRange<Date>?
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Linha do tempo", subtitle: "CPU do Mac inteiro. Arraste no gráfico pra escolher um trecho.")
                Spacer()
                if let s = selection {
                    Text("\(Fmt.time(s.lowerBound)) às \(Fmt.time(s.upperBound))").font(.callout).monospacedDigit()
                    Button("Analisar só esse trecho", action: onApply).buttonStyle(.borderedProminent)
                    Button("Limpar") { selection = nil }
                }
            }
            cpuChart
            if points.contains(where: { $0.watts != nil }) {
                Text("Consumo do Mac em watts").font(.caption).foregroundStyle(.secondary)
                wattsChart
            }
        }
    }

    private var cpuChart: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Hora", p.date), y: .value("CPU", p.busyPct ?? 0))
                    .foregroundStyle(Color.accentColor.opacity(0.25))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Hora", p.date), y: .value("CPU", p.busyPct ?? 0))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
            }
            if let s = selection {
                RectangleMark(xStart: .value("Início", s.lowerBound), xEnd: .value("Fim", s.upperBound))
                    .foregroundStyle(Color.orange.opacity(0.18))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Int.self) { Text("\(d)%") }
                }
            }
        }
        .chartXSelection(range: $selection)
        .frame(height: 130)
    }

    private var wattsChart: some View {
        Chart(points.filter { $0.watts != nil }) { p in
            LineMark(x: .value("Hora", p.date), y: .value("Watts", p.watts ?? 0))
                .foregroundStyle(Color.orange)
                .interpolationMethod(.stepEnd)
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text("\(Int(d)) W") }
                }
            }
        }
        .frame(height: 70)
    }
}
