import SwiftUI

struct ReportsWindow: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SessionList(selection: $model.selectedSession)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            if let id = model.selectedSession, let s = model.sessions.first(where: { $0.id == id }) {
                ReportView(session: s)
                    .id("\(id)-\(model.reportRevision)")
            } else {
                ContentUnavailableView(
                    "Nenhuma gravação selecionada",
                    systemImage: "drop",
                    description: Text("Comece uma gravação pelo ícone na barra de menus. Use o Mac normalmente e depois volte aqui pra ver o que mais pesou.")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isRecording {
                    Button { model.stop() } label: { Label("Parar gravação", systemImage: "stop.circle.fill") }
                        .help("Parar a gravação atual")
                } else {
                    Button { model.start() } label: { Label("Gravar", systemImage: "record.circle") }
                        .help("Começar uma gravação")
                }
                Button { showSettings = true } label: { Label("Ajustes", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet().environment(model)
        }
        .onAppear {
            model.reloadSessions()
            if model.selectedSession == nil { model.selectedSession = model.sessions.first?.id }
        }
        .alert("Dreno", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct SessionList: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Int64?
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(model.sessions) { s in
                SessionRow(session: s, recording: s.id == model.currentSessionId)
                    .contextMenu {
                        Button("Renomear…") {
                            newTitle = s.title ?? ""
                            renaming = s
                        }
                        Button("Apagar", role: .destructive) { model.delete(s.id) }
                            .disabled(s.id == model.currentSessionId)
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sessions.isEmpty {
                Text("Nenhuma gravação ainda").font(.callout).foregroundStyle(.secondary)
            }
        }
        .alert("Renomear gravação", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newTitle)
            Button("Salvar") {
                if let r = renaming { model.rename(r.id, newTitle) }
                renaming = nil
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
    }
}

struct SessionRow: View {
    let session: SessionSummary
    let recording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.caption)
                }
                Text(session.displayTitle).font(.body.weight(.medium)).lineLimit(1)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        var parts = [Fmt.duration(session.duration)]
        if session.trigger == "bateria" { parts.append("automática") }
        if let a = session.batteryStart, let b = session.batteryEnd, a - b >= 1 {
            parts.append("bateria \(Int(a.rounded()))→\(Int(b.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }
}
