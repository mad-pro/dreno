import SwiftUI
import AppKit
import Observation
import ServiceManagement
import IOKit.ps

/// Estado do app: gravação atual, sessões salvas e ajustes.
@Observable
final class AppModel {
    static let shared = AppModel()

    var isRecording = false
    var currentSessionId: Int64?
    var live: LiveStatus?
    var sessions: [SessionSummary] = []
    var selectedSession: Int64?
    var lastPower = PowerReading()
    var autoBattery: Bool
    var interval: Double
    var busyPct: Double
    var errorMessage: String?
    var reportRevision = 0
    var loginRevision = 0

    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var trigger = "manual"
    @ObservationIgnored private var powerSource: CFRunLoopSource?

    var analyzerSettings: AnalyzerSettings { AnalyzerSettings(busyPct: busyPct, minStreakSec: 60) }

    var launchAtLogin: Bool {
        _ = loginRevision
        return SMAppService.mainApp.status == .enabled
    }

    private init() {
        let d = UserDefaults.standard
        autoBattery = (d.object(forKey: "autoBattery") as? Bool) ?? true
        interval = (d.object(forKey: "interval") as? Double) ?? 10
        busyPct = (d.object(forKey: "busyPct") as? Double) ?? 2
        lastPower = PowerProbe.read()
        Store.closeDangling()
        sessions = Store.sessions()
        watchPower()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.recorder?.stop(sync: true)
        }
        if autoBattery, lastPower.hasBattery, lastPower.onBattery {
            DispatchQueue.main.async { [weak self] in self?.start(trigger: "bateria") }
        }
    }

    // MARK: Gravação

    func start(trigger: String = "manual") {
        guard recorder == nil else { return }
        do {
            let db = try Database(path: Paths.database.path)
            let r = try Recorder(db: db, interval: interval, trigger: trigger)
            r.onTick = { [weak self] status in
                guard let self, self.currentSessionId == status.sessionId else { return }
                self.live = status
                self.lastPower = status.power
            }
            recorder = r
            self.trigger = trigger
            currentSessionId = r.sessionId
            live = nil
            isRecording = true
            r.start()
            sessions = Store.sessions()
        } catch {
            errorMessage = "Não consegui começar a gravar: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let r = recorder else { return }
        recorder = nil
        isRecording = false
        let id = r.sessionId
        r.stop { [weak self] in
            guard let self else { return }
            self.currentSessionId = nil
            self.live = nil
            self.sessions = Store.sessions()
            self.selectedSession = id
            self.reportRevision += 1
        }
    }

    func quit() {
        recorder?.stop(sync: true)
        recorder = nil
        NSApp.terminate(nil)
    }

    // MARK: Energia (liga/desliga a gravação automática)

    private func watchPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<AppModel>.fromOpaque(ctx).takeUnretainedValue().powerChanged()
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        powerSource = src
    }

    func powerChanged() {
        let p = PowerProbe.read()
        lastPower = p
        guard autoBattery, p.hasBattery else { return }
        if p.onBattery && recorder == nil {
            start(trigger: "bateria")
        } else if !p.onBattery && recorder != nil && trigger == "bateria" {
            stop()
        }
    }

    func refreshPower() { lastPower = PowerProbe.read() }

    // MARK: Ajustes

    func setAutoBattery(_ v: Bool) {
        autoBattery = v
        UserDefaults.standard.set(v, forKey: "autoBattery")
        if v { powerChanged() }
    }

    func setInterval(_ v: Double) {
        interval = v
        UserDefaults.standard.set(v, forKey: "interval")
    }

    func setBusyPct(_ v: Double) {
        busyPct = v
        UserDefaults.standard.set(v, forKey: "busyPct")
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Não deu pra mudar o início automático: \(error.localizedDescription)"
        }
        loginRevision += 1
    }

    // MARK: Sessões

    func reloadSessions() { sessions = Store.sessions() }

    func delete(_ id: Int64) {
        guard id != currentSessionId else { return }
        Store.delete(id)
        if selectedSession == id { selectedSession = nil }
        sessions = Store.sessions()
    }

    func rename(_ id: Int64, _ title: String) {
        Store.rename(id, title)
        sessions = Store.sessions()
    }
}
