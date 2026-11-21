import SwiftUI
import AppKit

/// Tela do agente investigador de um processo.
struct InvestigationSheet: View {
    let group: GroupStat
    let report: Report
    let explanation: Explanation?
    var onOpenAssistant: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var steps: [String] = []
    @State private var outcome: InvestigationOutcome?
    @State private var errorText: String?
    @State private var running = false
    @State private var pending: AgentAction?
    @State private var results: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppIcon(path: group.identity.appPath ?? group.identity.path, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Investigação: \(group.identity.displayName)").font(.headline)
                    Text("A IA olha os dados técnicos desse processo no seu Mac e sugere o que fazer. Nada roda sem o seu clique.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if running || (outcome == nil && errorText == nil) { progress }
                    if let e = errorText {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if let o = outcome, !running {
                        InvestigationResultView(outcome: o, results: results) { pending = $0 }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let o = outcome {
                    Text("Feito em \(Fmt.dateTime(Date(timeIntervalSince1970: o.result.date))) com \(o.result.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let open = onOpenAssistant {
                    Button("Perguntar mais no assistente") {
                        dismiss()
                        open("Sobre \(group.identity.displayName): ")
                    }
                    .disabled(running)
                }
                Button(outcome == nil ? "Investigar" : "Investigar de novo") { start() }
                    .disabled(running)
            }
            .padding(12)
        }
        .frame(width: 780, height: 720)
        .task { loadOrStart() }
        .confirmationDialog(pending?.title ?? "Confirmar", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { a in
            Button(a.risk == "nenhum" ? "Abrir" : "Executar", role: a.risk == "nenhum" ? nil : .destructive) { execute(a) }
            Button("Cancelar", role: .cancel) {}
        } message: { a in
            Text(a.detail + (a.undo.map { "\n\nPra desfazer: \($0)" } ?? ""))
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 8) {
                    if i == steps.count - 1 && running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(s).font(.callout)
                }
            }
            if steps.isEmpty { ProgressView().controlSize(.small) }
        }
    }

    private func loadOrStart() {
        guard outcome == nil, !running else { return }
        if let saved = InvestigationStore.load(Explainer.aiKey(group.identity)) {
            outcome = InvestigationOutcome(result: saved.result, evidence: saved.evidence, actions: AgentActions.available(for: group))
        } else {
            start()
        }
    }

    private func start() {
        running = true
        errorText = nil
        steps = []
        results = [:]
        let inv = Investigator(group: group, report: report, explanation: explanation, actions: AgentActions.available(for: group))
        inv.onStep = { s in Task { @MainActor in steps.append(s) } }
        Task {
            do {
                outcome = try await inv.run(webSearch: AIExplainer.webSearchEnabled)
            } catch {
                errorText = error.localizedDescription
            }
            running = false
        }
    }

    private func execute(_ a: AgentAction) {
        results[a.id] = "Executando…"
        Task { results[a.id] = await AgentActions.execute(a, for: group) }
    }
}

struct InvestigationResultView: View {
    let outcome: InvestigationOutcome
    let results: [String: String]
    let onAction: (AgentAction) -> Void
    @State private var showEvidence = false

    var body: some View {
        let r = outcome.result
        let recommended: [(AgentAction, String)] = r.actions.compactMap { rec in
            outcome.actions.first { $0.id == rec.id }.map { ($0, rec.reason) }
        }
        let others = outcome.actions.filter { a in !r.actions.contains { $0.id == a.id } }
        VStack(alignment: .leading, spacing: 14) {
            Text(r.title).font(.title3.weight(.semibold))
            if !r.summary.isEmpty { Text(r.summary).font(.body).textSelection(.enabled) }
            HStack(spacing: 8) {
                verdict(r.worthStopping)
                if !r.impact.isEmpty {
                    Text(r.impact.lowercased().hasPrefix("se parar") ? r.impact : "Se parar: \(r.impact)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            block("O que é", r.what)
            block("Por que está rodando", r.why)
            block("O que está fazendo agora", r.doing)
            if !recommended.isEmpty {
                Text("Ações recomendadas").font(.headline).padding(.top, 4)
                ForEach(recommended, id: \.0.id) { item in actionRow(item.0, reason: item.1) }
            }
            if !r.manualSteps.isEmpty {
                Text("Passo a passo").font(.headline).padding(.top, 4)
                ForEach(Array(r.manualSteps.enumerated()), id: \.offset) { i, s in
                    Text("\(i + 1). \(s)").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !others.isEmpty {
                DisclosureGroup("Outras ações disponíveis") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(others) { a in actionRow(a, reason: "") }
                    }
                    .padding(.top, 6)
                }
            }
            if !r.sources.isEmpty {
                Text("Fontes na web").font(.headline)
                ForEach(r.sources, id: \.self) { s in
                    if let u = URL(string: s.url) { Link(s.title, destination: u).font(.callout) }
                }
            }
            ForEach(r.notes, id: \.self) { n in Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                if !r.confidence.isEmpty { Pill("Confiança \(r.confidence)") }
                if !r.toolsUsed.isEmpty { Pill("Consultou: " + r.toolsUsed.joined(separator: ", ")) }
            }
            DisclosureGroup("Evidências enviadas pra IA", isExpanded: $showEvidence) {
                Text(outcome.evidence)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }

    private func verdict(_ v: String) -> some View {
        let (text, color): (String, Color) = v == "sim" ? ("Vale parar", .green) : (v == "nao" ? ("Melhor não parar", .red) : ("Depende", .orange))
        return Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func block(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actionRow(_ a: AgentAction, reason: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.title).font(.callout.weight(.semibold))
                if !reason.isEmpty { Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true) }
                Text(a.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let res = results[a.id] { Text(res).font(.caption.weight(.medium)).foregroundStyle(.blue) }
            }
            Spacer()
            Button(a.risk == "nenhum" ? "Abrir" : "Executar") { onAction(a) }
                .buttonStyle(.borderedProminent)
                .tint(a.risk == "nenhum" ? .accentColor : (a.risk == "medio" ? .orange : .accentColor))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}
