import Foundation

/// Texto coletado no Mac pra mandar pro agente.
struct Evidence {
    var sections: [(title: String, body: String)] = []

    mutating func add(_ title: String, _ body: String) {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { sections.append((title, b)) }
    }

    var text: String { sections.map { "## \($0.title)\n\($0.body)" }.joined(separator: "\n\n") }
}

/// Mascara dados sensíveis antes de mandar qualquer coisa pra IA.
enum Redact {
    private static let rules: [(NSRegularExpression, String)] = [
        ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>"),
        ("(?i)((?:token|secret|password|passwd|apikey|api_key|api-key|authorization|bearer|auth|key)[\"']?\\s*[=: ]\\s*)[^\\s\"'&,]+", "$1<oculto>"),
        ("(https?://[^\\s?\"']+)\\?[^\\s\"']*", "$1?<oculto>"),
        ("[A-Za-z0-9_\\-]{32,}", "<token>"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    static func text(_ s: String) -> String {
        var t = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for (re, template) in rules {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
        }
        return t
    }
}

/// Ferramentas só de leitura usadas pelo agente investigador.
enum LocalTools {
    static let maxChars = 3500

    // MARK: Coleta inicial

    static func gather(_ g: GroupStat) -> Evidence {
        let id = g.identity
        var ev = Evidence()
        let all = ProcessLister.list()
        let rows = matching(id, in: all)
        let me = getuid()
        let minePids = rows.filter { $0.uid == me }.map(\.pid)

        ev.add("Identidade", Explainer.buildFacts(id).filter { $0.label != "Comandos" }.map { "\($0.label): \($0.value)" }.joined(separator: "\n"))
        ev.add("Rodando agora", instances(rows, all: all))
        if let path = id.path, let job = launchDetails(path: path) { ev.add("Como inicia (launchd)", job) }
        if let app = id.appPath, let b = bundle(app) { ev.add("Pacote do app", b) }
        if !minePids.isEmpty {
            if let n = network(Array(minePids.prefix(30))) { ev.add("Conexões de rede agora", n) }
            if let f = openFiles(Array(minePids.prefix(30)), ownApp: id.appPath) { ev.add("Pastas que ele está usando", f) }
        } else if !rows.isEmpty {
            ev.add("Limite", "Processo de outro usuário (sistema). Conexões e arquivos abertos não aparecem sem administrador.")
        } else {
            ev.add("Limite", "Não está rodando neste momento.")
        }
        return ev
    }

    static func matching(_ id: GroupIdentity, in all: [PSRow]) -> [PSRow] {
        if id.isAppGroup, let app = id.appPath { return all.filter { $0.command.hasPrefix(app + "/") } }
        if let p = id.path { return all.filter { $0.command == p } }
        return all.filter { ($0.command as NSString).lastPathComponent == id.mainName }
    }

    private static func instances(_ rows: [PSRow], all: [PSRow]) -> String {
        guard !rows.isEmpty else { return "Nenhuma instância rodando agora." }
        let names = Dictionary(all.map { ($0.pid, ($0.command as NSString).lastPathComponent) }, uniquingKeysWith: { a, _ in a })
        let pids = rows.prefix(15).map { String($0.pid) }.joined(separator: ",")
        var details: [Int32: (etime: String, cpu: String, args: String)] = [:]
        if let out = run("/bin/ps", ["-o", "pid=,etime=,%cpu=,args=", "-p", pids]) {
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count >= 3, let pid = Int32(parts[0]) else { continue }
                details[pid] = (String(parts[1]), String(parts[2]), parts.count > 3 ? String(parts[3]) : "")
            }
        }
        let me = getuid()
        var lines = ["\(rows.count) processo(s). Os primeiros:"]
        for r in rows.prefix(15) {
            let d = details[r.pid]
            var l = "pid \(r.pid), aberto por \(names[r.ppid] ?? "?") (pid \(r.ppid)), usuário \(MacInfo.userName(uid: Int(r.uid)))"
            if let d { l += ", rodando há \(d.etime), CPU agora \(d.cpu)%" }
            l += ", memória \(Fmt.bytes(r.rss))"
            if r.uid == me, let a = d?.args, !a.isEmpty { l += "\n  comando: " + String(Redact.text(a).prefix(300)) }
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }

    static func launchDetails(path: String) -> String? {
        guard let job = AppCatalog.shared.launchJob(for: path) else { return nil }
        var lines = ["label: \(job.label)", "onde: \(job.domain)"]
        if !job.plist.isEmpty {
            lines.append("arquivo: \(MacInfo.tilde(job.plist))")
            if let d = NSDictionary(contentsOfFile: job.plist) as? [String: Any] {
                for key in ["Program", "ProgramArguments", "BundleProgram", "RunAtLoad", "KeepAlive", "StartInterval", "StartCalendarInterval", "WatchPaths", "QueueDirectories", "ProcessType", "LimitLoadToSessionType", "AssociatedBundleIdentifiers"] {
                    if let v = d[key] { lines.append("\(key): \(compact(v))") }
                }
                if let mach = d["MachServices"] as? [String: Any] { lines.append("MachServices: \(mach.keys.sorted().prefix(5).joined(separator: ", "))") }
            }
            let target = job.isDaemon ? "system/\(job.label)" : "gui/\(getuid())/\(job.label)"
            if let out = run("/bin/launchctl", ["print", target], timeout: 5) {
                let keep = ["state =", "runs =", "pid =", "last exit", "type =", "spawn type", "active count", "run interval", "properties ="]
                let picked = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { l in keep.contains { l.hasPrefix($0) } }.prefix(12)
                if !picked.isEmpty { lines.append("estado no launchctl: " + picked.joined(separator: "; ")) }
            }
        }
        return Redact.text(lines.joined(separator: "\n"))
    }

    static func bundle(_ appPath: String) -> String? {
        let fm = FileManager.default
        guard appPath.hasSuffix(".app"), fm.fileExists(atPath: appPath) else { return nil }
        var lines: [String] = []
        if let d = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") as? [String: Any] {
            for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "LSUIElement", "LSBackgroundOnly", "LSMinimumSystemVersion"] {
                if let v = d[key] { lines.append("\(key): \(compact(v))") }
            }
        }
        if let attrs = try? fm.attributesOfItem(atPath: appPath) {
            if let c = attrs[.creationDate] as? Date { lines.append("instalado em: \(Fmt.dateTime(c))") }
            if let m = attrs[.modificationDate] as? Date { lines.append("modificado em: \(Fmt.dateTime(m))") }
        }
        lines.append("origem: " + (fm.fileExists(atPath: appPath + "/Contents/_MASReceipt/receipt") ? "Mac App Store" : "fora da App Store"))
        for (label, sub) in [("itens de início", "Contents/Library/LoginItems"), ("agentes", "Contents/Library/LaunchAgents"),
                             ("serviços de sistema", "Contents/Library/LaunchDaemons"), ("ajudantes privilegiados", "Contents/Library/LaunchServices"),
                             ("serviços XPC", "Contents/XPCServices")] {
            if let items = try? fm.contentsOfDirectory(atPath: appPath + "/" + sub), !items.isEmpty {
                lines.append("\(label): \(items.sorted().prefix(8).joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func network(_ pids: [Int32]) -> String? {
        guard !pids.isEmpty, let out = run("/usr/sbin/lsof", ["-nP", "-i", "-a", "-p", pids.map(String.init).joined(separator: ",")], timeout: 8) else { return nil }
        var listen = Set<String>()
        var remote: [String: Int] = [:]
        var udp = 0, total = 0
        for line in out.split(separator: "\n").dropFirst() {
            let s = String(line)
            total += 1
            if s.contains("(LISTEN)"), let name = s.split(separator: " ").dropLast().last { listen.insert(String(name)) }
            else if let r = s.range(of: "->") {
                let rest = s[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                remote[rest, default: 0] += 1
            } else if s.contains(" UDP ") { udp += 1 }
        }
        guard total > 0 else { return "Nenhuma conexão de rede aberta agora." }
        var lines = ["\(total) conexões abertas."]
        if !listen.isEmpty { lines.append("Escutando em: " + listen.sorted().prefix(8).joined(separator: ", ")) }
        if !remote.isEmpty {
            lines.append("Conectado a: " + remote.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)\($0.value > 1 ? " ×\($0.value)" : "")" }.joined(separator: ", "))
        }
        if udp > 0 { lines.append("UDP: \(udp)") }
        return lines.joined(separator: "\n")
    }

    static func openFiles(_ pids: [Int32], ownApp: String?) -> String? {
        guard !pids.isEmpty, let out = run("/usr/sbin/lsof", ["-Fn", "-p", pids.map(String.init).joined(separator: ",")], timeout: 8) else { return nil }
        let skip = ["/System/", "/usr/lib/", "/usr/share/", "/dev/", "/private/var/db/", "/Library/Preferences/", "/private/var/folders/", "/Library/Apple/"]
        let home = NSHomeDirectory()
        var counts: [String: Int] = [:]
        for line in out.split(separator: "\n") where line.hasPrefix("n/") {
            let p = String(line.dropFirst())
            if skip.contains(where: { p.hasPrefix($0) }) || p.hasSuffix(".dylib") { continue }
            if let own = ownApp, p.hasPrefix(own + "/") { continue }
            let dir = (p as NSString).deletingLastPathComponent
            var comps = (dir as NSString).pathComponents
            let depth = dir.hasPrefix(home) ? (home as NSString).pathComponents.count + 4 : 5
            if comps.count > depth { comps = Array(comps.prefix(depth)) }
            counts[NSString.path(withComponents: comps), default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        let lines = counts.sorted { $0.value > $1.value }.prefix(12).map { "\(MacInfo.tilde($0.key)) (\($0.value))" }
        return Redact.text(lines.joined(separator: "\n"))
    }

    static func logs(process: String, minutes: Int) -> String {
        guard process.range(of: "^[A-Za-z0-9._ ()+-]{1,80}$", options: .regularExpression) != nil else { return "Nome de processo inválido." }
        let m = max(1, min(minutes, 10))
        guard let out = run("/usr/bin/log", ["show", "--last", "\(m)m", "--style", "compact", "--predicate", "process == \"\(process)\""], timeout: 20) else {
            return "Não consegui ler os logs."
        }
        let lines = out.split(separator: "\n").filter { !$0.hasPrefix("Timestamp") && !$0.hasPrefix("Filtering") }
        guard !lines.isEmpty else { return "Nenhum log desse processo nos últimos \(m) minutos." }
        return Redact.text(lines.suffix(40).map { String($0.prefix(220)) }.joined(separator: "\n"))
    }

    // MARK: Ferramentas chamadas pela IA

    static func callTool(name: String, arguments: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        func str(_ k: String) -> String { (args[k] as? String)?.trimmingCharacters(in: .whitespaces) ?? "" }
        let out: String
        switch name {
        case "inspect_process": out = inspect(str("query"))
        case "read_launchd_plist": out = readPlist(label: str("label"))
        case "recent_logs": out = logs(process: str("process"), minutes: (args["minutes"] as? Int) ?? 3)
        case "network_connections":
            let pids = ProcessLister.list().filter { $0.uid == getuid() && ($0.command as NSString).lastPathComponent == str("process") }.map(\.pid)
            out = pids.isEmpty ? "Nenhum processo do seu usuário com esse nome rodando." : (network(Array(pids.prefix(30))) ?? "Sem conexões.")
        case "list_app_bundle": out = bundle(str("app_path").replacingOccurrences(of: "~", with: NSHomeDirectory())) ?? "App não encontrado."
        default: out = "Ferramenta desconhecida."
        }
        return String(out.prefix(maxChars))
    }

    static func inspect(_ query: String) -> String {
        let all = ProcessLister.list()
        let byPid = Int32(query).flatMap { pid in all.first { $0.pid == pid } }
        let found = byPid.map { [$0] } ?? all.filter { ($0.command as NSString).lastPathComponent == query }
        guard !found.isEmpty else { return "Nenhum processo rodando com esse nome ou PID." }
        let names = Dictionary(all.map { ($0.pid, ($0.command as NSString).lastPathComponent) }, uniquingKeysWith: { a, _ in a })
        let cat = AppCatalog.shared
        var lines = ["\(found.count) instância(s)."]
        for r in found.prefix(3) {
            var l = "pid \(r.pid), executável \(MacInfo.tilde(r.command)), usuário \(MacInfo.userName(uid: Int(r.uid))), aberto por \(names[r.ppid] ?? "?") (pid \(r.ppid))"
            l += ", assinatura: \(cat.signing(r.command).summary)"
            if let app = cat.app(forExecutable: r.command) { l += ", app: \(app.name) (\(app.bundleId ?? "?"))" }
            if let j = cat.launchJob(for: r.command) { l += ", inicia por: \(j.label), \(j.domain)" }
            lines.append(l)
        }
        return Redact.text(lines.joined(separator: "\n"))
    }

    static func readPlist(label: String) -> String {
        guard let path = AppCatalog.shared.plistPath(forLabel: label), let d = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return "Nenhum serviço do launchd com esse label."
        }
        var lines = ["arquivo: \(MacInfo.tilde(path))"]
        for (k, v) in d.sorted(by: { $0.key < $1.key }) {
            if k == "EnvironmentVariables", let env = v as? [String: Any] {
                lines.append("EnvironmentVariables: \(env.keys.sorted().joined(separator: ", ")) (valores ocultos)")
            } else {
                lines.append("\(k): \(compact(v))")
            }
        }
        return Redact.text(lines.joined(separator: "\n"))
    }

    // MARK: Utilidades

    private static func compact(_ v: Any) -> String {
        if let a = v as? [Any] { return "[" + a.map { compact($0) }.joined(separator: ", ") + "]" }
        if let d = v as? [String: Any] { return "{" + d.sorted { $0.key < $1.key }.map { "\($0.key): \(compact($0.value))" }.joined(separator: ", ") + "}" }
        let s = "\(v)"
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
