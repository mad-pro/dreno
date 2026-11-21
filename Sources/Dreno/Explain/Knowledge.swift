import Foundation

struct KBEntry: Decodable {
    let id: String
    var names: [String]?
    var regex: [String]?
    var bundle: [String]?
    var path: [String]?
    let title: String
    let kind: String
    let stop: String
    let what: String
    let why: String
    let fix: String
}

/// Base curada de processos (Resources/processes.json).
final class Knowledge {
    static let shared = Knowledge()

    private(set) var entries: [KBEntry] = []
    private var byName: [String: Int] = [:]
    private var byBundle: [String: Int] = [:]
    private var regexes: [(NSRegularExpression, Int)] = []

    init() {
        // A base do usuário entra primeiro pra ter prioridade.
        let sources = [Paths.userKnowledgeBase] + (Paths.knowledgeBase.map { [$0] } ?? [])
        for url in sources {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                entries += try JSONDecoder().decode([KBEntry].self, from: data)
            } catch {
                NSLog("Dreno: erro lendo %@: %@", url.path, "\(error)")
            }
        }
        if entries.isEmpty { NSLog("Dreno: base de processos não encontrada") }
        for (i, e) in entries.enumerated() {
            for n in e.names ?? [] where byName[n] == nil { byName[n] = i }
            for b in e.bundle ?? [] where byBundle[b] == nil { byBundle[b] = i }
            for r in e.regex ?? [] {
                if let re = try? NSRegularExpression(pattern: r) { regexes.append((re, i)) }
            }
        }
    }

    func entry(id: String) -> KBEntry? { entries.first { $0.id == id } }

    func byBundle(_ id: String) -> KBEntry? { byBundle[id].map { entries[$0] } }

    func match(name: String, path: String?) -> KBEntry? {
        if let i = byName[name] { return entries[i] }
        let range = NSRange(name.startIndex..., in: name)
        for (re, i) in regexes where re.firstMatch(in: name, range: range) != nil {
            if let req = entries[i].path, !req.isEmpty {
                guard let p = path, req.contains(where: { p.contains($0) }) else { continue }
            }
            return entries[i]
        }
        if let p = path {
            for e in entries where e.names == nil && e.regex == nil {
                if let req = e.path, req.contains(where: { p.contains($0) }) { return e }
            }
        }
        return nil
    }
}

enum Labels {
    static func kind(_ k: String) -> String {
        switch k {
        case "sistema": return "Sistema (macOS)"
        case "sistema-ajustavel": return "Sistema, dá pra reduzir"
        case "app": return "App"
        case "dev": return "Desenvolvimento"
        case "nuvem": return "Nuvem e sincronização"
        case "seguranca": return "Segurança"
        case "fundo": return "Segundo plano"
        default: return "Não identificado"
        }
    }

    static func stop(_ s: String) -> String {
        switch s {
        case "nao": return "Não encerre, o sistema precisa"
        case "reduzir": return "Não encerre, mas dá pra reduzir"
        case "sim": return "Pode fechar ou desativar"
        case "cuidado": return "Pode, com cuidado"
        default: return "Avalie antes de mexer"
        }
    }
}
