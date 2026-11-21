import SwiftUI
import AppKit

/// Card de um app ou processo que pesou: números, explicação e ações.
struct GroupCard: View {
    let rank: Int
    let group: GroupStat
    let explanation: Explanation?
    let report: Report
    let aiAvailable: Bool
    let onAskAI: (GroupStat) -> Void

    @State private var expanded = false
    @State private var pendingKill: [Int32] = []
    @State private var confirmKill = false
    @State private var notRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            head
            metrics
            let verdict = ReportText.verdict(group, explanation)
            if !verdict.isEmpty {
                Text(verdict).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            if let ex = explanation {
                ExplanationView(ex: ex, expanded: expanded)
            }
            if expanded { details }
            footer
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .confirmationDialog("Encerrar \(group.identity.displayName)?", isPresented: $confirmKill) {
            Button("Encerrar", role: .destructive) { Terminator.terminate(group.identity) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Vai fechar \(pendingKill.count == 1 ? "1 processo" : "\(pendingKill.count) processos"). Salve o que estiver aberto nele antes. Se ele inicia sozinho, pode voltar depois.")
        }
        .alert("\(group.identity.displayName) não está rodando agora", isPresented: $notRunning) {
            Button("OK", role: .cancel) {}
        }
    }

    private var head: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(rank)")
                .font(.callout.weight(.bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            AppIcon(path: group.identity.appPath ?? group.identity.path)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(group.identity.displayName).font(.headline)
                    PatternBadge(pattern: group.pattern)
                }
                Text(ReportText.subtitle(group)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Sparkline(values: group.series)
        }
    }

    private var metrics: some View {
        AdaptiveGrid(minWidth: 150, spacing: 10) {
            ForEach(Array(ReportText.metrics(group, report).enumerated()), id: \.offset) { item in
                MetricView(value: item.element.value, label: item.element.label)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let ex = explanation, !ex.facts.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(ex.facts, id: \.self) { f in
                        GridRow {
                            Text(f.label).font(.caption).foregroundStyle(.secondary)
                            Text(f.value).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if group.members.count > 1 {
                Text("Processos do grupo").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(group.members.prefix(8)) { m in
                    HStack {
                        Text(m.name + (m.pidCount > 1 ? " ×\(m.pidCount)" : "")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Fmt.duration(m.cpuSec) + " de CPU" + (m.memAvg.map { " · " + Fmt.bytes($0) } ?? ""))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            ForEach(group.holds) { h in
                Text("\(h.label) por \(Fmt.duration(h.seconds))" + (h.names.isEmpty ? "" : " (\(h.names.joined(separator: ", ")))"))
                    .font(.caption)
            }
            if let cmd = explanation?.stopCommand {
                HStack(spacing: 8) {
                    Text("Pra parar agora:").font(.caption).foregroundStyle(.secondary)
                    Text(cmd).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copiar") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, 4)
    }

    private var canTerminate: Bool {
        guard let ex = explanation, !group.identity.isResidual, !ex.isApple, ex.stop != "nao" else { return false }
        return group.identity.uids.contains(Int(getuid()))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(expanded ? "Menos detalhes" : "Mais detalhes") {
                withAnimation(.snappy) { expanded.toggle() }
            }
            .buttonStyle(.link)
            if let p = group.identity.appPath ?? group.identity.path, FileManager.default.fileExists(atPath: p) {
                Button("Mostrar no Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
                .buttonStyle(.link)
            }
            if aiAvailable, let ex = explanation, ex.canAskAI {
                Button(ex.source.hasPrefix("IA") ? "Perguntar de novo à IA" : "Explicar com IA") { onAskAI(group) }
                    .buttonStyle(.link)
            }
            Spacer()
            if canTerminate {
                Button(role: .destructive) {
                    pendingKill = Terminator.running(group.identity)
                    if pendingKill.isEmpty { notRunning = true } else { confirmKill = true }
                } label: {
                    Label("Encerrar", systemImage: "xmark.circle")
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
    }
}

struct ExplanationView: View {
    let ex: Explanation
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(ex.title).font(.callout.weight(.semibold))
            labeled("O que é", ex.what)
            if expanded { labeled("Por que consome", ex.why) }
            labeled("O que fazer", ex.fix)
            HStack(spacing: 6) {
                Pill(Labels.kind(ex.kind))
                Pill(Labels.stop(ex.stop), tint: ex.stop == "sim" ? .green : (ex.stop == "nao" ? .red : .orange))
                Pill("Fonte: " + ex.source + (ex.confidence.map { ", confiança \($0)" } ?? ""))
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func labeled(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            Text("\(Text(title + ".").bold()) \(text)")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
