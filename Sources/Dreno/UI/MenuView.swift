import SwiftUI
import AppKit

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "drop.fill").foregroundStyle(.orange)
                Text("Dreno").font(.headline)
                Spacer()
                if model.isRecording {
                    Label("Gravando", systemImage: "record.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }

            if model.isRecording {
                RecordingBlock(live: model.live)
            } else {
                Text("Grave um período de uso e depois veja o que mais gastou CPU, energia e memória, com a explicação de cada processo.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PowerLine(power: model.live?.power ?? model.lastPower)

            Divider()

            HStack {
                if model.isRecording {
                    Button {
                        model.stop()
                        openReports()
                    } label: {
                        Label("Parar e ver relatório", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button { model.start() } label: {
                        Label("Começar a gravar", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Relatórios") { openReports() }
            }

            Divider()

            Toggle("Gravar sozinho quando sair da tomada", isOn: Binding(get: { model.autoBattery }, set: { model.setAutoBattery($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)

            HStack {
                Text("Amostra a cada").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Intervalo", selection: Binding(get: { model.interval }, set: { model.setInterval($0) })) {
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                    Text("30 s").tag(30.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(model.isRecording)
            }

            HStack {
                Text("Versão \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Sair") { model.quit() }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { model.refreshPower() }
    }

    private func openReports() {
        openWindow(id: "reports")
        NSApp.activate()
        dismiss()
    }
}

struct RecordingBlock: View {
    let live: LiveStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let live {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Gravando há \(Fmt.clock(ctx.date.timeIntervalSince(live.started)))")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
                if !live.top.isEmpty {
                    Text("Mais ativos no último minuto").font(.caption).foregroundStyle(.secondary)
                    ForEach(live.top) { item in
                        HStack {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.pct(item.pct))
                                .monospacedDigit()
                                .foregroundStyle(item.pct >= 50 ? Color.red : Color.secondary)
                        }
                        .font(.callout)
                    }
                }
                Text("CPU do Mac \(live.busyPct.map { Fmt.pct($0) } ?? "-") · o Dreno usa \(Fmt.num(live.overheadPct, 1))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Começando a gravar…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct PowerLine: View {
    let power: PowerReading

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: power.onBattery ? "battery.100" : "powerplug.fill")
                .foregroundStyle(power.onBattery ? Color.orange : Color.green)
            Text(text).font(.callout)
        }
    }

    private var text: String {
        guard power.hasBattery else { return power.watts.map { "Consumo agora: \(Fmt.watts($0))" } ?? "Sem bateria" }
        var parts: [String] = []
        if let p = power.percent { parts.append("\(Int(p.rounded()))%") }
        parts.append(power.onBattery ? "na bateria" : (power.charging ? "carregando" : "na tomada"))
        if let w = power.watts { parts.append("\(Fmt.watts(w)) agora") }
        return parts.joined(separator: " · ")
    }
}
