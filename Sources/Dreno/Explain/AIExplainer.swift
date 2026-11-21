import Foundation

/// Explicações por IA em qualquer endpoint compatível com /chat/completions.
/// Configuração no .env: AI_BASE_URL, AI_MODEL e AI_API_KEY.
enum AIExplainer {
    struct Config {
        let baseURL: URL
        let model: String
        let apiKey: String
    }

    struct Entry: Codable {
        let title: String
        let what: String
        let why: String
        let fix: String
        let stop: String
        let kind: String
        let confidence: String
        let model: String
        let date: Double
    }

    enum AIError: Error, LocalizedError {
        case notConfigured, http(Int, String), format(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "IA não configurada. Preencha AI_BASE_URL, AI_MODEL e AI_API_KEY no .env."
            case .http(let c, let b): return "A IA respondeu HTTP \(c): \(b)"
            case .format(let m): return "Resposta da IA em formato inesperado: \(m)"
            }
        }
    }

    static func config() -> Config? {
        let env = Env.load()
        guard let key = env["AI_API_KEY"], !key.isEmpty,
              let baseString = env["AI_BASE_URL"], let base = URL(string: baseString),
              let model = env["AI_MODEL"], !model.isEmpty else { return nil }
        return Config(baseURL: base, model: model, apiKey: key)
    }

    static var isConfigured: Bool { config() != nil }

    // MARK: Cache em disco

    private static let lock = NSLock()
    private static var cache: [String: Entry] = {
        guard let data = try? Data(contentsOf: Paths.aiCache),
              let d = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return d
    }()

    static func cached(_ key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private static func store(_ key: String, _ e: Entry) {
        lock.lock()
        cache[key] = e
        let snapshot = cache
        lock.unlock()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snapshot) { try? data.write(to: Paths.aiCache) }
    }

    // MARK: Chamada

    static let systemPrompt = """
    Você é especialista em macOS, Apple Silicon e diagnóstico de desempenho e bateria. \
    Explica processos para o dono do Mac, que é desenvolvedor, em português do Brasil. \
    Seja direto, frases curtas, sem enrolação. Não use travessão nem emoji. \
    Baseie a resposta nos dados fornecidos. Se não tiver certeza do que o processo é, diga isso claramente e use confianca baixa. \
    Nunca invente nomes de menus, ajustes ou comandos que você não tem certeza que existem.
    """

    private static func complete(_ cfg: Config, messages: [[String: String]], maxTokens: Int, timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: cfg.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": cfg.model, "temperature": 0.2, "max_tokens": maxTokens, "messages": messages]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AIError.http(status, String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw AIError.format(String(String(data: data, encoding: .utf8)?.prefix(200) ?? ""))
        }
        return content
    }

    static func explain(key: String, prompt: String) async throws -> Entry {
        guard let cfg = config() else { throw AIError.notConfigured }
        let content = try await complete(cfg, messages: [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": prompt],
        ], maxTokens: 4000, timeout: 180)
        let entry = try parse(content, model: cfg.model)
        store(key, entry)
        return entry
    }

    /// Teste rápido da configuração (botão Testar nos Ajustes).
    static func ping() async -> String {
        guard let cfg = config() else { return "Falta preencher endereço, modelo ou chave." }
        do {
            _ = try await complete(cfg, messages: [["role": "user", "content": "Responda apenas com a palavra ok."]], maxTokens: 300, timeout: 60)
            return "Funcionou com \(cfg.model)."
        } catch {
            return error.localizedDescription
        }
    }

    static func parse(_ content: String, model: String) throws -> Entry {
        var text = content
        if let re = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>") {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let data = String(text[a...b]).data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.format(String(content.prefix(200)))
        }
        func s(_ keys: String...) -> String {
            for k in keys { if let v = d[k] as? String, !v.isEmpty { return v.replacingOccurrences(of: "—", with: ",") } }
            return ""
        }
        let what = s("o_que_e", "what")
        guard !what.isEmpty else { throw AIError.format("sem campo o_que_e") }
        return Entry(title: s("titulo", "title"), what: what, why: s("por_que_consome", "why"), fix: s("o_que_fazer", "fix"),
                     stop: normalize(s("pode_encerrar", "stop"), allowed: ["sim", "nao", "reduzir", "cuidado"], fallback: "cuidado"),
                     kind: normalize(s("tipo", "kind"), allowed: ["sistema", "sistema-ajustavel", "app", "dev", "nuvem", "seguranca", "fundo"], fallback: "desconhecido"),
                     confidence: normalize(s("confianca", "confidence"), allowed: ["alta", "media", "baixa"], fallback: "media"),
                     model: model, date: Date().timeIntervalSince1970)
    }

    private static func normalize(_ v: String, allowed: [String], fallback: String) -> String {
        let x = v.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespaces)
        return allowed.first { x.hasPrefix($0) } ?? fallback
    }
}
