import Foundation

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Dreno", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var database: URL { support.appendingPathComponent("dreno.sqlite") }
    static var aiCache: URL { support.appendingPathComponent("ai-cache.json") }
    static var manCache: URL { support.appendingPathComponent("man-cache.json") }

    static var reportsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Dreno", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pasta do projeto (gravada no Info.plist pelo build), usada pra achar o .env e a base em modo dev.
    static let projectDir: URL? = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "DrenoProjectDir") as? String, !s.isEmpty, !s.hasPrefix("__") {
            return URL(fileURLWithPath: s)
        }
        guard var u = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path) { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }()

    /// Descrições extras do próprio usuário (opcional). Têm prioridade sobre a base que vem no app.
    static var userKnowledgeBase: URL { support.appendingPathComponent("processes.json") }

    static var knowledgeBase: URL? {
        if let u = Bundle.main.url(forResource: "processes", withExtension: "json") { return u }
        if let p = projectDir?.appendingPathComponent("Resources/processes.json"),
           FileManager.default.fileExists(atPath: p.path) { return p }
        return nil
    }

    /// Onde o app procura o .env (o último da lista tem prioridade).
    static var envFiles: [URL] {
        var files: [URL] = []
        if let p = projectDir { files.append(p.appendingPathComponent(".env")) }
        files.append(support.appendingPathComponent(".env"))
        return files
    }
}
