import SwiftUI
import AppKit

extension Notification.Name {
    static let drenoOpenReports = Notification.Name("drenoOpenReports")
}

/// Abrir o app de novo (Finder, Spotlight) mostra a janela de relatórios.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .drenoOpenReports, object: nil)
        return true
    }
}

enum Launch {
    /// Mostra a janela na primeira vez ou com --window. Depois disso o app abre só na barra de menus.
    static let showWindow: Bool = {
        let first = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        return first || CommandLine.arguments.contains("--window")
    }()
}

struct DrenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(model)
        } label: {
            MenuBarLabel(recording: model.isRecording)
        }
        .menuBarExtraStyle(.window)

        Window("Dreno", id: "reports") {
            ReportsWindow()
                .environment(model)
                .frame(minWidth: 940, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 820)
        .defaultLaunchBehavior(Launch.showWindow ? .presented : .suppressed)
    }
}

struct MenuBarLabel: View {
    let recording: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: recording ? "record.circle.fill" : "drop")
            .onReceive(NotificationCenter.default.publisher(for: .drenoOpenReports)) { _ in
                openWindow(id: "reports")
                NSApp.activate()
            }
    }
}
