import Foundation
import AppKit

/// Ação que o app sabe executar. O agente só escolhe entre as disponíveis; quem executa é o app, depois do clique.
struct AgentAction: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let risk: String
    let needsAdmin: Bool
    let undo: String?
}

enum AgentActions {
    private static let spotlight: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd", "Spotlight"]
    private static let notifications: Set<String> = ["NotificationCenter", "usernoted", "chronod"]

    /// Ações possíveis pra esse grupo, calculadas com dados locais (nunca com texto vindo da IA).
    static func available(for g: GroupStat) -> [AgentAction] {
        let id = g.identity
        guard !id.isResidual else { return [] }
        let cat = AppCatalog.shared
        let isApple = (id.path.map { cat.signing($0).isApple } ?? false) || (id.path.map { MacInfo.isSystemPath($0) } ?? false)
        let mine = id.uids.contains(Int(getuid()))
        let name = id.appName ?? id.displayName
        var out: [AgentAction] = []

        if !isApple && mine {
            if let app = id.appPath, runningApp(app) != nil {
                out.append(AgentAction(id: "quit_app", title: "Fechar o \(name)",
                                       detail: "Pede pro app fechar normalmente, igual Cmd+Q. Ele pode perguntar se quer salvar alguma coisa.",
                                       risk: "baixo", needsAdmin: false, undo: "Abrir o app de novo."))
            }
            let running = Terminator.running(id)
            if !running.isEmpty {
                out.append(AgentAction(id: "terminate", title: running.count == 1 ? "Encerrar o processo" : "Encerrar os \(running.count) processos",
                                       detail: "Manda o sinal de encerrar (SIGTERM) pros processos de \(id.displayName). O que não estiver salvo neles se perde.",
                                       risk: "medio", needsAdmin: false, undo: "Abrir o app ou o serviço de novo."))
            }
        }
        if let path = id.path, let job = cat.launchJob(for: path), !job.plist.isEmpty, !job.plist.hasPrefix("/System/"), validLabel(job.label) {
            let domain = job.isDaemon ? "system" : "gui/\(getuid())"
            let admin = job.isDaemon ? " Pede a senha de administrador." : ""
            out.append(AgentAction(id: "stop_agent", title: "Parar \(job.label) agora",
                                   detail: "Roda launchctl bootout \(domain)/\(job.label). Fica parado até o próximo login ou reinício.\(admin)",
                                   risk: "baixo", needsAdmin: job.isDaemon, undo: "launchctl bootstrap \(domain) \(MacInfo.tilde(job.plist))"))
            out.append(AgentAction(id: "disable_agent", title: "Impedir que \(job.label) abra sozinho",
                                   detail: "Roda launchctl disable \(domain)/\(job.label) e depois bootout. Não volta nem reiniciando o Mac.\(admin)",
                                   risk: "medio", needsAdmin: job.isDaemon, undo: "launchctl enable \(domain)/\(job.label)"))
        }
        if !isApple {
            out.append(AgentAction(id: "open_login_items", title: "Abrir Itens de Início e Extensões",
                                   detail: "Abre os Ajustes do Sistema na tela onde você desliga o que abre sozinho e o que roda em segundo plano.",
                                   risk: "nenhum", needsAdmin: false, undo: nil))
        }
        if spotlight.contains(id.mainName) {
            out.append(AgentAction(id: "open_spotlight", title: "Abrir os ajustes do Spotlight",
                                   detail: "Abre os Ajustes do Sistema no Spotlight, onde dá pra tirar pastas da indexação.",
                                   risk: "nenhum", needsAdmin: false, undo: nil))
        }
        if notifications.contains(id.mainName) {
            out.append(AgentAction(id: "open_notifications", title: "Abrir os ajustes de Notificações",
                                   detail: "Abre os Ajustes do Sistema em Notificações.", risk: "nenhum", needsAdmin: false, undo: nil))
        }
        if let p = id.appPath ?? id.path, FileManager.default.fileExists(atPath: p) {
            out.append(AgentAction(id: "show_in_finder", title: "Mostrar no Finder", detail: "Abre a pasta onde ele está instalado.",
                                   risk: "nenhum", needsAdmin: false, undo: nil))
        }
        return out
    }

    static func validLabel(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil }

    private static func runningApp(_ appPath: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == appPath }
    }

    /// Executa depois da confirmação. Revalida tudo de novo antes de mexer.
    @MainActor
    static func execute(_ action: AgentAction, for g: GroupStat) async -> String {
        guard let current = available(for: g).first(where: { $0.id == action.id }) else { return "Essa ação não está mais disponível." }
        let id = g.identity
        switch current.id {
        case "quit_app":
            guard let app = id.appPath, let ra = runningApp(app) else { return "O app não está aberto." }
            return ra.terminate() ? "Pedido de fechar enviado." : "O app recusou fechar."
        case "terminate":
            let n = Terminator.terminate(id, graceful: false)
            return n > 0 ? "Encerrado (\(n) processo\(n == 1 ? "" : "s"))." : "Nada foi encerrado."
        case "stop_agent", "disable_agent":
            guard let path = id.path, let job = AppCatalog.shared.launchJob(for: path), validLabel(job.label) else { return "Serviço não encontrado." }
            let target = job.isDaemon ? "system/\(job.label)" : "gui/\(getuid())/\(job.label)"
            var cmds = [["bootout", target]]
            if current.id == "disable_agent" { cmds.insert(["disable", target], at: 0) }
            let result = await Task.detached { launchctl(cmds, admin: job.isDaemon) }.value
            return result
        case "open_login_items":
            return open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        case "open_spotlight":
            return open("x-apple.systempreferences:com.apple.Spotlight-Settings.extension")
        case "open_notifications":
            return open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        case "show_in_finder":
            guard let p = id.appPath ?? id.path else { return "Caminho não encontrado." }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            return "Aberto no Finder."
        default:
            return "Ação desconhecida."
        }
    }

    private static func open(_ url: String) -> String {
        guard let u = URL(string: url) else { return "Endereço inválido." }
        return NSWorkspace.shared.open(u) ? "Ajustes abertos." : "Não consegui abrir os Ajustes."
    }

    private static func launchctl(_ cmds: [[String]], admin: Bool) -> String {
        if admin {
            let shell = cmds.map { (["/bin/launchctl"] + $0).joined(separator: " ") }.joined(separator: "; ")
            let script = "do shell script \"\(shell)\" with administrator privileges"
            let out = LocalTools.run("/usr/bin/osascript", ["-e", script], timeout: 120)
            return out == nil ? "Cancelado ou sem permissão." : "Feito."
        }
        var notes: [String] = []
        for c in cmds {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = c
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return "Não consegui rodar o launchctl." }
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                notes.append("\(c[0]): \(msg.isEmpty ? "código \(p.terminationStatus)" : msg)")
            }
        }
        return notes.isEmpty ? "Feito." : "Feito com avisos: " + notes.joined(separator: "; ")
    }
}
