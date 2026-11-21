import SwiftUI
import AppKit

struct SleepSection: View {
    let groups: [GroupStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Impediram o Mac de dormir",
                          subtitle: "Seguraram o sono do Mac ou a tela acesa. Gasta bateria mesmo com você parado.")
            VStack(spacing: 0) {
                ForEach(groups) { g in
                    ForEach(g.holds.prefix(2)) { h in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(g.identity.displayName).font(.callout.weight(.medium)).frame(width: 190, alignment: .leading)
                            Text(h.label).font(.callout).frame(width: 190, alignment: .leading)
                            Text(Fmt.duration(h.seconds)).font(.callout).monospacedDigit().frame(width: 80, alignment: .leading)
                            Text(h.names.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        Divider()
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

struct CompactSection: View {
    let title: String
    let subtitle: String
    let groups: [GroupStat]
    let explanations: [String: Explanation]
    let value: (GroupStat) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, subtitle: subtitle)
            VStack(spacing: 0) {
                ForEach(groups) { g in
                    CompactRow(group: g, explanation: explanations[g.id], value: value(g))
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

struct CompactRow: View {
    let group: GroupStat
    let explanation: Explanation?
    let value: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    AppIcon(path: group.identity.appPath ?? group.identity.path, size: 22)
                    Text(group.identity.displayName).font(.callout.weight(.medium))
                    Text(explanation?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(value).font(.callout).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open, let ex = explanation {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ex.what).font(.callout)
                    if !ex.fix.isEmpty {
                        Text("O que fazer: " + ex.fix).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 56)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}

struct MethodNotes: View {
    var body: some View {
        DisclosureGroup("Como ler esses números") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ReportText.methodNotes, id: \.self) { note in
                    Text("• " + note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        }
    }
}

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var aiBase = ""
    @State private var aiModel = ""
    @State private var aiKey = ""
    @State private var aiStatus = ""
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ajustes").font(.title2.weight(.semibold))
            Form {
                Section("Gravação") {
                    Toggle("Gravar sozinho quando sair da tomada",
                           isOn: Binding(get: { model.autoBattery }, set: { model.setAutoBattery($0) }))
                    Picker("Amostra a cada", selection: Binding(get: { model.interval }, set: { model.setInterval($0) })) {
                        Text("5 segundos").tag(5.0)
                        Text("10 segundos").tag(10.0)
                        Text("30 segundos").tag(30.0)
                    }
                    .disabled(model.isRecording)
                    Toggle("Abrir o Dreno quando o Mac ligar",
                           isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
                Section("Análise") {
                    LabeledContent("Conta como ativo acima de") {
                        HStack {
                            Slider(value: Binding(get: { model.busyPct }, set: { model.setBusyPct($0) }), in: 1...10, step: 0.5)
                                .frame(width: 160)
                            Text("\(Fmt.num(model.busyPct, 1))% de um núcleo").monospacedDigit()
                        }
                    }
                }
                Section("Explicações por IA (opcional)") {
                    TextField("Endereço da API", text: $aiBase, prompt: Text("https://api.provedor.com/v1"))
                    TextField("Modelo", text: $aiModel, prompt: Text("nome-do-modelo"))
                    SecureField("Chave da API", text: $aiKey, prompt: Text("cole sua chave aqui"))
                    HStack(spacing: 10) {
                        Button("Salvar") { saveAI() }
                        Button("Testar") { testAI() }.disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        Text(aiStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("Com a chave, o Dreno explica processos que não estão na base dele e você pode pedir uma explicação mais completa de qualquer um. Serve qualquer provedor com API no formato chat/completions. Vão pro provedor só nome, caminho, assinatura e números dos processos, com a sua pasta de usuário trocada por ~. A chave fica em \(MacInfo.tilde(Paths.support.appendingPathComponent(".env").path)), que só o seu usuário lê.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Dados") {
                    Button("Abrir pasta de dados") { NSWorkspace.shared.open(Paths.support) }
                    Text("Suas próprias descrições de processos ficam em \(MacInfo.tilde(Paths.userKnowledgeBase.path)), no mesmo formato da base do app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 680)
        .onAppear {
            let env = Env.load()
            aiBase = env["AI_BASE_URL"] ?? ""
            aiModel = env["AI_MODEL"] ?? ""
            aiKey = env["AI_API_KEY"] ?? ""
            aiStatus = AIExplainer.isConfigured ? "Configurada" : "Não configurada"
        }
    }

    private func saveAI() {
        do {
            try Env.saveAI(base: aiBase, model: aiModel, key: aiKey)
            aiStatus = AIExplainer.isConfigured ? "Salvo." : "Salvo, mas falta preencher algum campo."
            model.reportRevision += 1
        } catch {
            aiStatus = "Erro ao salvar: \(error.localizedDescription)"
        }
    }

    private func testAI() {
        saveAI()
        testing = true
        Task {
            aiStatus = await AIExplainer.ping()
            testing = false
        }
    }
}
