import Foundation

struct Fact: Hashable {
    let label: String
    let value: String
}

struct Explanation {
    var title: String
    var what: String
    var why: String
    var fix: String
    var kind: String
    var stop: String
    var source: String
    var confidence: String?
    var facts: [Fact] = []
    var canAskAI = false
    var aiKey = ""
    var stopCommand: String?
    var isApple = false
}

/// Monta a explicação de um grupo: base curada > cache da IA > manual do macOS + metadados.
enum Explainer {
    static func explainAll(_ groups: [GroupStat]) -> [String: Explanation] {
        var out: [String: Explanation] = [:]
        for g in groups where out[g.id] == nil { out[g.id] = explain(g) }
        return out
    }

    static func explain(_ g: GroupStat) -> Explanation {
        let id = g.identity
        if id.isResidual {
            let e = Knowledge.shared.entry(id: "_residual")
            return Explanation(title: e?.title ?? id.displayName, what: e?.what ?? "", why: e?.why ?? "", fix: e?.fix ?? "",
                               kind: "sistema", stop: "nao", source: "Base do Dreno")
        }
        let facts = buildFacts(id)
        let key = aiKey(id)
        let sig = id.path.map { AppCatalog.shared.signing($0) }
        let job = id.path.flatMap { AppCatalog.shared.launchJob(for: $0) }
        let kb = matchKB(id)
        var ex: Explanation
        if let c = AIExplainer.cached(key) {
            // A descrição vem da IA; a classificação de segurança fica com a base curada quando ela conhece o processo.
            ex = Explanation(title: c.title.isEmpty ? id.displayName : c.title, what: c.what, why: c.why, fix: c.fix,
                             kind: kb?.kind ?? c.kind, stop: kb?.stop ?? c.stop, source: "IA (\(c.model))", confidence: c.confidence)
        } else if let e = kb {
            ex = Explanation(title: fill(e.title, id), what: fill(e.what, id), why: fill(e.why, id), fix: fill(e.fix, id),
                             kind: e.kind, stop: e.stop, source: "Base do Dreno")
        } else {
            ex = metadataExplanation(id, g, sig: sig, job: job)
        }
        ex.canAskAI = true
        ex.facts = facts
        ex.aiKey = key
        ex.stopCommand = job?.stopCommand
        ex.isApple = sig?.isApple ?? false
        return ex
    }

    static func aiKey(_ id: GroupIdentity) -> String {
        if id.isAppGroup { return "app:" + (id.bundleId ?? id.appPath ?? id.displayName) }
        return MacInfo.tilde(id.path ?? id.mainName)
    }

    static func matchKB(_ id: GroupIdentity) -> KBEntry? {
        let kb = Knowledge.shared
        if id.isAppGroup {
            if let b = id.bundleId, let e = kb.byBundle(b) { return e }
            if let n = id.appName, let e = kb.match(name: n, path: id.appPath) { return e }
            if let e = kb.match(name: id.mainName, path: id.path), e.id.hasPrefix("_familia") { return e }
            return nil
        }
        if let e = kb.match(name: id.mainName, path: id.path) { return e }
        if let b = id.bundleId, let e = kb.byBundle(b), id.mainName == id.appName { return e }
        return nil
    }

    private static func fill(_ s: String, _ id: GroupIdentity) -> String {
        s.replacingOccurrences(of: "{app}", with: id.appName ?? id.responsibleApps.first ?? "o app")
    }

    // MARK: Sem base curada

    private static func metadataExplanation(_ id: GroupIdentity, _ g: GroupStat, sig: SigningInfo?, job: LaunchJob?) -> Explanation {
        let isSystem = sig?.isApple == true || (id.path.map { MacInfo.isSystemPath($0) } ?? false)
        if isSystem {
            let man = AppCatalog.shared.manSummary(for: id.mainName)
            var what = man.map { "Pelo manual do macOS: \($0)" } ?? "Componente do macOS assinado pela Apple. Ainda não está na base do Dreno."
            if let j = job { what += " Iniciado pelo launchd como \(j.label)." }
            return Explanation(
                title: id.displayName, what: what,
                why: "Processos do sistema reagem ao que acontece no Mac. Quando um deles fica em uso contínuo, quase sempre tem um app ou recurso puxando. Veja o que mais estava ativo no mesmo período.",
                fix: "Não encerre processos do sistema: o macOS abre de novo e pode dar problema. Peça a explicação da IA pra ter mais detalhe.",
                kind: "sistema", stop: "nao", source: man != nil ? "Manual do macOS" : "Metadados")
        }
        if let appName = id.appName {
            var what = "Faz parte do app \(appName)" + (sig?.developerName.map { ", do desenvolvedor \($0)" } ?? "") + "."
            if id.names.count > 1 { what += " Roda \(id.names.count) programas diferentes, \(g.pidCount) processos no período." }
            if let j = job { what += " " + j.sentence }
            let fix = job != nil
                ? "Feche o app. Como ele inicia sozinho, pra impedir que volte desative em Ajustes do Sistema > Geral > Itens de Início e Extensões."
                : "Feche o app (Cmd+Q com ele em primeiro plano). Se abre sozinho no login, tire em Ajustes do Sistema > Geral > Itens de Início e Extensões."
            return Explanation(
                title: appName, what: what,
                why: "Ainda não tem descrição curada desse app. O consumo vem do que ele faz em segundo plano: sincronização, animação, abas, extensões ou conexões abertas.",
                fix: fix, kind: job != nil ? "fundo" : "app", stop: "sim", source: "Metadados")
        }
        let path = id.path ?? id.mainName
        var what = "Programa de linha de comando em \(MacInfo.tilde(path))."
        if let dev = sig?.developerName { what += " Assinado por \(dev)." }
        else if sig?.isSigned != true { what += " Sem assinatura de desenvolvedor, então foi instalado à mão (Homebrew, npm, pip, projeto local) ou veio junto de alguma ferramenta." }
        if !id.responsibleApps.isEmpty { what += " Foi aberto por: \(id.responsibleApps.joined(separator: ", "))." }
        if let j = job { what += " " + j.sentence }
        let devPaths = ["/opt/homebrew", "/usr/local", "/.nvm/", "node_modules", "/.cargo/", "/extensions/", "/go/bin/", "/Sites/"]
        return Explanation(
            title: id.displayName, what: what,
            why: "Consome enquanto está rodando a tarefa dele. Servidores, watchers e daemons ficam ativos até alguém parar.",
            fix: job != nil ? "Pare o serviço (comando abaixo) ou desative em Ajustes do Sistema > Geral > Itens de Início e Extensões." : "Se não reconhece, veja quem abriu e encerre pelo terminal ou app onde ele roda.",
            kind: devPaths.contains { path.contains($0) } ? "dev" : "desconhecido", stop: "cuidado", source: "Metadados")
    }

    static func buildFacts(_ id: GroupIdentity) -> [Fact] {
        var f: [Fact] = []
        let cat = AppCatalog.shared
        if let ap = id.appPath, let app = cat.appInfo(appPath: ap) {
            var v = app.name
            if let ver = app.version { v += " \(ver)" }
            if let b = app.bundleId { v += " (\(b))" }
            f.append(Fact(label: "App", value: v))
        }
        if let p = id.path {
            f.append(Fact(label: "Executável", value: MacInfo.tilde(p)))
            f.append(Fact(label: "Assinatura", value: cat.signing(p).summary))
            if let j = cat.launchJob(for: p) {
                var v = "\(j.label), \(j.domain)"
                if j.keepAlive { v += ", reabre se fechar" }
                f.append(Fact(label: "Inicialização", value: v))
            }
        }
        let users = id.uids.sorted().map { MacInfo.userName(uid: $0) }
        if !users.isEmpty { f.append(Fact(label: "Usuário", value: users.joined(separator: ", "))) }
        if !id.responsibleApps.isEmpty { f.append(Fact(label: "Aberto por", value: id.responsibleApps.joined(separator: ", "))) }
        if id.names.count > 1 {
            f.append(Fact(label: "Programas", value: id.names.prefix(6).joined(separator: ", ") + (id.names.count > 6 ? " e mais \(id.names.count - 6)" : "")))
        }
        if !id.commands.isEmpty { f.append(Fact(label: "Comandos", value: id.commands.prefix(4).joined(separator: "\n"))) }
        return f
    }

    // MARK: IA

    static func aiPrompt(_ g: GroupStat, base: Explanation) -> String {
        let id = g.identity
        var lines: [String] = []
        lines.append("Mac: \(MacInfo.model), \(MacInfo.osVersion), Apple Silicon")
        lines.append("Nome exibido: \(id.displayName)")
        lines.append("Processo principal: \(id.mainName)")
        if id.names.count > 1 { lines.append("Programas do grupo: \(id.names.prefix(8).joined(separator: ", "))") }
        for f in base.facts where f.label != "Comandos" { lines.append("\(f.label): \(f.value)") }
        if let man = AppCatalog.shared.manSummary(for: id.mainName) { lines.append("Manual do macOS: \(man)") }
        if let kb = matchKB(id) {
            lines.append("Descrição da base curada do app (confiável, use como ponto de partida e aprofunde): \(fill(kb.title, id)). O que é: \(fill(kb.what, id)) Por que consome: \(fill(kb.why, id)) O que fazer: \(fill(kb.fix, id))")
        }
        return """
        Explique este processo do macOS pro dono do Mac, que é desenvolvedor e quer decidir se pode parar ele pra economizar bateria e CPU. \
        Explique de forma geral, sem citar números de uma medição específica, pra que a explicação sirva sempre que esse processo aparecer.

        \(lines.joined(separator: "\n"))

        Responda SOMENTE com um objeto JSON, sem texto antes ou depois, neste formato:
        {"titulo": "nome curto e claro", "o_que_e": "3 a 5 frases: o que é, de quem é, pra que serve e de onde vem", "por_que_consome": "2 a 3 frases sobre quando e por que ele costuma gastar CPU, energia ou memória", "o_que_fazer": "passos práticos e seguros pra reduzir ou parar, com o caminho certo nos Ajustes quando existir", "pode_encerrar": "sim | nao | reduzir | cuidado", "tipo": "sistema | sistema-ajustavel | app | dev | nuvem | seguranca | fundo", "confianca": "alta | media | baixa"}
        """
    }

    static func askAI(_ g: GroupStat, base: Explanation) async throws -> Explanation {
        let entry = try await AIExplainer.explain(key: base.aiKey, prompt: aiPrompt(g, base: base))
        var ex = base
        ex.title = entry.title.isEmpty ? base.title : entry.title
        ex.what = entry.what
        ex.why = entry.why
        ex.fix = entry.fix
        let kb = matchKB(g.identity)
        ex.kind = kb?.kind ?? entry.kind
        ex.stop = kb?.stop ?? entry.stop
        ex.source = "IA (\(entry.model))"
        ex.confidence = entry.confidence
        return ex
    }
}
