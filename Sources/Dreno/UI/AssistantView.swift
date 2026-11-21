import SwiftUI

/// Chat com o assistente que investiga e executa comandos no Mac.
struct AssistantView: View {
    @State private var assistant = AssistantModel.shared
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "O que está gastando mais bateria agora?",
        "Por que o Mac não está dormindo?",
        "Quais apps abrem sozinhos quando eu ligo o Mac?",
        "Fecha o que está em uso contínuo e não é do sistema",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assistente do Dreno").font(.headline)
                    Text("Peça em português. Comando só de leitura roda na hora. O que muda alguma coisa só roda com o seu ok.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Nova conversa") { assistant.reset() }.disabled(assistant.items.isEmpty)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !AIExplainer.isConfigured {
                            Label("Configure a IA em Ajustes, na janela de relatórios, pra usar o assistente.", systemImage: "key")
                                .foregroundStyle(.orange)
                        } else if assistant.items.isEmpty {
                            Text("Exemplos").font(.caption).foregroundStyle(.secondary)
                            ForEach(suggestions, id: \.self) { s in
                                Button(s) { assistant.send(s) }.buttonStyle(.bordered)
                            }
                        }
                        ForEach(assistant.items) { item in
                            AssistantItemView(item: item, awaiting: assistant.awaitingId == item.id) { assistant.decide($0) }
                                .id(item.id)
                        }
                        if assistant.running && assistant.awaitingId == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Pensando…").font(.callout).foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: assistant.items.count) { _, _ in
                    withAnimation { proxy.scrollTo(assistant.items.last?.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Peça alguma coisa…", text: $assistant.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { assistant.send(assistant.draft) }
                Button {
                    assistant.send(assistant.draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(assistant.running || assistant.draft.trimmingCharacters(in: .whitespaces).isEmpty || !AIExplainer.isConfigured)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 540)
        .onAppear { inputFocused = true }
    }
}

struct AssistantItemView: View {
    let item: AssistantModel.Item
    let awaiting: Bool
    let onDecide: (Bool) -> Void
    @State private var showOutput = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18)))
                    .textSelection(.enabled)
            }
        case .assistant:
            Text(markdown(item.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .note:
            Label(item.text, systemImage: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
        case .command:
            commandCard
        }
    }

    private var commandCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(statusText).font(.caption.weight(.semibold)).foregroundStyle(color)
            }
            Text(item.command ?? "")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            if !item.text.isEmpty { Text(item.text).font(.callout).foregroundStyle(.secondary) }
            if awaiting {
                HStack {
                    Button(item.admin ? "Executar (pede senha)" : "Executar") { onDecide(true) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    Button("Recusar") { onDecide(false) }
                }
            }
            if let out = item.output, !out.isEmpty {
                DisclosureGroup("Saída", isExpanded: $showOutput) {
                    ScrollView {
                        Text(out)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))
    }

    private var statusText: String {
        switch item.status {
        case .awaiting: return item.admin ? "Esperando sua aprovação (vai pedir a senha de administrador)" : "Esperando sua aprovação"
        case .running: return "Rodando…"
        case .done(let code): return code == 0 ? (item.auto ? "Rodou sozinho (só leitura)" : "Executado") : "Terminou com código \(code)"
        case .denied: return "Você recusou"
        case .blocked(let why): return "Bloqueado pelo app: \(why)"
        case .none: return ""
        }
    }

    private var icon: String {
        switch item.status {
        case .awaiting: return "hand.raised.fill"
        case .running: return "hourglass"
        case .done(let code): return code == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .denied: return "xmark.circle"
        case .blocked: return "nosign"
        case .none: return "terminal"
        }
    }

    private var color: Color {
        switch item.status {
        case .awaiting: return .orange
        case .done(let code): return code == 0 ? .green : .red
        case .blocked, .denied: return .red
        default: return .secondary
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
