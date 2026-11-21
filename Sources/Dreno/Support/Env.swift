import Foundation

/// Lê variáveis de arquivos .env simples (KEY=valor).
enum Env {
    static func load() -> [String: String] {
        var out: [String: String] = [:]
        for file in Paths.envFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (k, v) in parse(text) where !v.isEmpty { out[k] = v }
        }
        for (k, v) in ProcessInfo.processInfo.environment where k.hasPrefix("AI_") && !v.isEmpty {
            out[k] = v
        }
        return out
    }

    /// Salva a configuração de IA feita nos Ajustes (arquivo legível só pelo usuário).
    static func saveAI(base: String, model: String, key: String) throws {
        let url = Paths.support.appendingPathComponent(".env")
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let text = """
        # Configuração de IA do Dreno (gerado pelos Ajustes do app)
        AI_BASE_URL=\(clean(base))
        AI_MODEL=\(clean(model))
        AI_API_KEY=\(clean(key))

        """
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.count >= 2,
               (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            out[key] = val
        }
        return out
    }
}
