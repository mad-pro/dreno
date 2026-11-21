import Foundation

/// Comandos de terminal: testes e relatórios sem abrir a interface.
enum CLI {
    static let help = """
    Dreno: monitor de processos e bateria

    Uso (sem argumentos abre o app na barra de menus):
      Dreno --selftest [segundos] [--interval s] [--html arquivo.html] [--processo]
            grava num banco temporário e imprime o relatório
      Dreno --list                         lista as gravações salvas
      Dreno --report <id> [--html arquivo] [--bateria] [--processo]
      Dreno --explain <nome|caminho>       mostra a explicação de um processo
      Dreno --ai-test [nome|caminho]       testa a IA configurada no .env
    """

    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let grouping: Grouping = args.contains("--processo") ? .processo : .app
        switch args[1] {
        case "--help", "-h":
            print(help)
            return 0
        case "--selftest":
            let secs = args.count > 2 ? Double(args[2]) ?? 30 : 30
            let interval = value("--interval").flatMap(Double.init) ?? 3
            let path = value("--db") ?? (NSTemporaryDirectory() + "dreno-selftest-\(getpid()).sqlite")
            return selftest(seconds: secs, interval: interval, dbPath: path, html: value("--html"), grouping: grouping)
        case "--list":
            for s in Store.sessions() {
                print("\(s.id)\t\(s.displayTitle)\t\(Fmt.duration(s.duration))\t\(s.trigger)")
            }
            return 0
        case "--report":
            guard args.count > 2, let id = Int64(args[2]), let db = Store.reader,
                  let s = Store.sessions(in: db).first(where: { $0.id == id }) else {
                print("Sessão não encontrada. Use --list.")
                return 1
            }
            return printReport(db: db, session: s, filter: args.contains("--bateria") ? .battery : .all, grouping: grouping, html: value("--html"))
        case "--snapshot":
            guard args.count > 3, let id = Int64(args[2]), let db = Store.reader,
                  let s = Store.sessions(in: db).first(where: { $0.id == id }) else {
                print("Uso: --snapshot <id> <arquivo.png> [--dark] [--processo]")
                return 1
            }
            let r = Analyzer.run(db: db, session: s, filter: .all, grouping: grouping, settings: AnalyzerSettings())
            let b = ReportBundle(report: r, explanations: Explainer.explainAll(r.displayedGroups))
            let ok = MainActor.assumeIsolated { Snapshot.render(b, to: args[3], dark: args.contains("--dark")) }
            print(ok ? "PNG: \(args[3])" : "falhou")
            return ok ? 0 : 1
        case "--explain", "--ai-test":
            guard let g = fakeGroup(args.count > 2 ? args[2] : "WindowServer") else {
                print("Não achei esse processo rodando. Passe o caminho completo.")
                return 1
            }
            var ex = Explainer.explain(g)
            if args[1] == "--ai-test" {
                print("Base: \(Paths.envFiles.map(\.path).joined(separator: ", "))")
                guard AIExplainer.isConfigured else { print("IA não configurada (AI_API_KEY ausente)."); return 1 }
                let sem = DispatchSemaphore(value: 0)
                var failure: Error?
                let base = ex
                Task {
                    do { ex = try await Explainer.askAI(g, base: base) } catch { failure = error }
                    sem.signal()
                }
                sem.wait()
                if let failure { print("Erro: \(failure.localizedDescription)"); return 1 }
            }
            printExplanation(g, ex)
            return 0
        default:
            return nil
        }
    }

    private static func selftest(seconds: Double, interval: Double, dbPath: String, html: String?, grouping: Grouping) -> Int32 {
        do {
            let db = try Database(path: dbPath)
            let rec = try Recorder(db: db, interval: interval, trigger: "teste")
            rec.onTick = { s in
                let line = "amostra \(s.ticks): CPU do Mac \(s.busyPct.map { Fmt.pct($0) } ?? "-"), \(s.power.watts.map { Fmt.watts($0) } ?? "-"), overhead do Dreno \(Fmt.num(s.overheadPct, 2))%\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
            rec.start()
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
            rec.stop(sync: true)
            guard let s = Store.sessions(in: db).first(where: { $0.id == rec.sessionId }) else { print("sessão sumiu"); return 1 }
            print("banco: \(dbPath)")
            return printReport(db: db, session: s, filter: .all, grouping: grouping, html: html)
        } catch {
            print("erro: \(error.localizedDescription)")
            return 1
        }
    }

    private static func printReport(db: Database, session: SessionSummary, filter: TickFilter, grouping: Grouping, html: String?) -> Int32 {
        let t0 = Date()
        let r = Analyzer.run(db: db, session: session, filter: filter, grouping: grouping, settings: AnalyzerSettings())
        let t1 = Date()
        let b = ReportBundle(report: r, explanations: Explainer.explainAll(r.displayedGroups))
        let t2 = Date()
        print(TextReport.render(b))
        print(String(format: "\n(análise %.0f ms, explicações %.0f ms)", t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000))
        if let html {
            do {
                try HTMLReport.render(b).write(toFile: html, atomically: true, encoding: .utf8)
                print("HTML: \(html)")
            } catch {
                print("erro salvando HTML: \(error.localizedDescription)")
                return 1
            }
        }
        return 0
    }

    /// Monta um grupo de mentira a partir de um processo rodando (pra testar explicações).
    private static func fakeGroup(_ target: String) -> GroupStat? {
        var path = target
        var uid = Int(getuid())
        if !target.hasPrefix("/") {
            guard let row = ProcessLister.list().first(where: { ($0.command as NSString).lastPathComponent == target }) else { return nil }
            path = row.command
            uid = Int(row.uid)
        }
        let name = (path as NSString).lastPathComponent
        let appPath = AppCatalog.shared.outermostAppPath(path)
        let app = appPath.flatMap { AppCatalog.shared.appInfo(appPath: $0) }
        let id = GroupIdentity(key: path, displayName: name, mainName: name, path: path, appPath: appPath, appName: app?.name,
                               bundleId: app?.bundleId, isAppGroup: false, names: [name], uids: [uid], responsibleApps: [],
                               commands: [], isResidual: false)
        return GroupStat(id: path, identity: id)
    }

    private static func printExplanation(_ g: GroupStat, _ ex: Explanation) {
        print("\(ex.title)  [\(Labels.kind(ex.kind)) · \(Labels.stop(ex.stop)) · fonte: \(ex.source)\(ex.confidence.map { " · confiança \($0)" } ?? "")]")
        print("O que é: \(ex.what)")
        print("Por que consome: \(ex.why)")
        print("O que fazer: \(ex.fix)")
        if let c = ex.stopCommand { print("Comando: \(c)") }
        for f in ex.facts { print("  \(f.label): \(f.value)") }
    }
}
