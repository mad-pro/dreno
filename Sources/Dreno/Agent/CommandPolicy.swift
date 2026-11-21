import Foundation

/// Decide o que pode rodar sozinho, o que precisa da aprovação do usuário e o que nunca roda.
enum CommandRisk: Equatable {
    case auto
    case confirm
    case admin
    case blocked(String)
}

enum CommandPolicy {
    /// Comandos que só leem o estado do sistema.
    private static let readOnly: Set<String> = [
        "ps", "top", "lsof", "pgrep", "pmset", "sysctl", "sw_vers", "uname", "df", "du", "ioreg", "system_profiler",
        "launchctl", "log", "codesign", "spctl", "mdutil", "defaults", "which", "file", "stat", "ls", "netstat",
        "scutil", "networksetup", "uptime", "vm_stat", "memory_pressure", "date", "whoami", "id", "csrutil", "hostname",
    ]
    /// Filtros aceitos depois de um pipe (sem awk e sed, que conseguem executar coisas).
    private static let filters: Set<String> = ["grep", "egrep", "head", "tail", "sort", "uniq", "wc", "cut", "tr", "column"]

    private static let hardBlocks: [(String, String)] = [
        ("\\brm\\s+-[a-zA-Z]*[rR][a-zA-Z]*\\s+[\"']?(/|~|\\$HOME|\\$\\{HOME\\})/?\\*?[\"']?(?=$|[\\s)\"';|&])", "apagar a raiz ou a pasta de usuário inteira"),
        ("\\brm\\s+-[a-zA-Z]*[rR][a-zA-Z]*\\s+[^|;]*(/System|/usr|/bin|/sbin|/Library/Apple|/private/var/db)", "apagar pastas do sistema"),
        ("\\bsudo\\s+rm\\s+-[a-zA-Z]*[rR]", "apagar pastas como administrador"),
        ("\\bdiskutil\\s+(erase|partition|zero|secureErase|apfs\\s+delete|reformat)", "apagar ou particionar disco"),
        ("\\bcsrutil\\s+(disable|clear|authenticated-root)", "desligar a proteção do sistema (SIP)"),
        ("\\bspctl\\s+--master-disable", "desligar o Gatekeeper"),
        ("\\bnvram\\s+(-c|-d|[A-Za-z0-9_-]+=)", "alterar a NVRAM"),
        ("\\bdd\\s+[^|;]*of=/dev/", "escrever direto no disco"),
        ("\\b(mkfs|newfs_[a-z]+)\\b", "formatar disco"),
        (":\\(\\)\\s*\\{", "bomba de processos"),
        ("\\b(curl|wget)\\b[^|]*\\|\\s*(sudo\\s+)?(sh|bash|zsh|python3?)\\b", "baixar e executar script da internet"),
        ("\\bch(mod|own)\\s+-R\\s+\\S+\\s+/(\\s|$)", "mudar permissões do disco inteiro"),
        ("\\blaunchctl\\s+(bootout|disable|unload|remove|kill)\\s+\\S*com\\.apple\\.", "parar serviços da Apple"),
        ("\\b(killall|pkill)\\s+(-[A-Za-z0-9]+\\s+)*(WindowServer|loginwindow|launchd|kernel_task|logd|opendirectoryd)\\b", "encerrar processo essencial do macOS"),
        ("\\bkill\\s+(-[A-Za-z0-9]+\\s+)*1(\\s|$)", "encerrar o launchd"),
        ("\\b(shutdown|reboot|halt)\\b", "desligar ou reiniciar o Mac"),
        (">\\s*/dev/(r?disk|mem)", "escrever direto no disco"),
        ("\\bsudo\\s+(-s|-i|su\\b|bash|zsh|sh)\\b", "abrir terminal de administrador"),
    ]

    static func classify(_ raw: String) -> CommandRisk {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return .blocked("comando vazio") }
        guard cmd.count <= 2000 else { return .blocked("comando grande demais") }
        for (pattern, why) in hardBlocks where cmd.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return .blocked(why)
        }
        let words = cmd.split(separator: " ").map(String.init)
        if words.first == "sudo" {
            let rest = words.dropFirst().joined(separator: " ")
            if rest.contains("sudo") || containsShellOperators(rest, allowPipes: false) {
                return .blocked("com sudo só aceito um comando simples, sem pipe nem encadeamento")
            }
            return .admin
        }
        if cmd.range(of: "\\bsudo\\b", options: .regularExpression) != nil {
            return .blocked("sudo só no começo de um comando simples")
        }
        return isReadOnly(cmd) ? .auto : .confirm
    }

    private static func containsShellOperators(_ s: String, allowPipes: Bool) -> Bool {
        let ops = [";", "&&", "||", ">", "<", "`", "$(", "\n", "&"]
        if ops.contains(where: { s.contains($0) }) { return true }
        return !allowPipes && s.contains("|")
    }

    /// Operadores perigosos fora de aspas simples. Substituição de comando vale até dentro de aspas duplas.
    private static func hasUnsafeOperators(_ s: String) -> Bool {
        var single = false, double = false
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "'" && !double { single.toggle(); continue }
            if c == "\"" && !single { double.toggle(); continue }
            if single { continue }
            if c == "`" || (c == "$" && next == "(") { return true }
            if !double && [";", ">", "<", "&", "\n"].contains(c) { return true }
        }
        return single || double
    }

    /// Separa por pipe, ignorando os que estão dentro de aspas.
    private static func splitPipes(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var single = false, double = false
        for c in s {
            if c == "'" && !double { single.toggle() } else if c == "\"" && !single { double.toggle() }
            if c == "|" && !single && !double {
                parts.append(cur)
                cur = ""
                continue
            }
            cur.append(c)
        }
        parts.append(cur)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isReadOnly(_ cmd: String) -> Bool {
        // Redirecionar erro pra saída ou pro nada é inofensivo; qualquer outro operador pede aprovação.
        let sanitized = cmd.replacingOccurrences(of: "2>&1", with: "").replacingOccurrences(of: "2>/dev/null", with: "")
        if hasUnsafeOperators(sanitized) { return false }
        let segments = splitPipes(sanitized)
        for (i, seg) in segments.enumerated() {
            let w = seg.split(separator: " ").map(String.init)
            guard let first = w.first else { return false }
            let exe = (first as NSString).lastPathComponent
            if i > 0 {
                if filters.contains(exe) { continue }
                return false
            }
            guard readOnly.contains(exe) else { return false }
            let arg1 = w.count > 1 ? w[1] : ""
            switch exe {
            case "launchctl": if !["print", "list", "blame", "print-disabled", "procinfo", "hostinfo", "managerpid"].contains(arg1) { return false }
            case "log": if arg1 != "show" { return false }
            case "defaults": if !["read", "domains", "find", "read-type"].contains(arg1) { return false }
            case "pmset": if !w.contains(where: { $0.hasPrefix("-g") }) { return false }
            case "mdutil": if !w.contains("-s") || w.contains(where: { ["-i", "-E", "-X", "-a"].contains($0) }) { return false }
            case "codesign": if !w.contains(where: { $0.hasPrefix("-d") || $0 == "--display" || $0 == "-v" || $0 == "--verify" }) || w.contains(where: { $0 == "-s" || $0 == "--sign" || $0 == "-f" || $0 == "--remove-signature" }) { return false }
            case "spctl": if !w.contains(where: { ["--assess", "-a", "--status"].contains($0) }) { return false }
            case "networksetup": if !(arg1.hasPrefix("-get") || arg1.hasPrefix("-list") || arg1 == "-printcommands") { return false }
            case "scutil": if !["--get", "--dns", "--proxy", "-r"].contains(arg1) { return false }
            case "top": if !w.contains(where: { $0.hasPrefix("-l") }) { return false }
            case "csrutil": if arg1 != "status" { return false }
            case "hostname": if w.count > 1 { return false }
            case "date": if w.count > 2 { return false }
            default: break
            }
        }
        return true
    }
}

/// Executa um comando no Mac (com zsh ou, com admin, pelo pedido de senha do macOS).
enum CommandRunner {
    struct Result {
        let output: String
        let status: Int32
        let timedOut: Bool
    }

    static func run(_ command: String, admin: Bool, timeout: TimeInterval) -> Result {
        let p = Process()
        if admin {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", command]
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = "en_US.UTF-8"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return Result(output: "Não consegui executar: \(error.localizedDescription)", status: -1, timedOut: false) }
        var timedOut = false
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        var out = String(data: data, encoding: .utf8) ?? ""
        if out.count > 20000 { out = String(out.prefix(20000)) + "\n… (saída cortada)" }
        return Result(output: out, status: p.terminationStatus, timedOut: timedOut)
    }
}
