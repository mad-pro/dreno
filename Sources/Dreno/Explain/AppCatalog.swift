import Foundation
import Security

struct AppInfo {
    let path: String
    let name: String
    let bundleId: String?
    let version: String?
}

struct SigningInfo {
    let isSigned: Bool
    let isApple: Bool          // binário da Apple ("Software Signing")
    let isAppStore: Bool
    let authority: String?
    let team: String?

    /// Nome do desenvolvedor extraído do certificado ("Developer ID Application: Google LLC (EQHXZ8M8AV)").
    var developerName: String? {
        if isApple { return "Apple" }
        guard let a = authority else { return nil }
        if let r = a.range(of: ": ") {
            var s = String(a[r.upperBound...])
            if let p = s.range(of: " (", options: .backwards) { s = String(s[..<p.lowerBound]) }
            return s
        }
        return a
    }

    var summary: String {
        if !isSigned { return "Sem assinatura (provavelmente instalado à mão, Homebrew ou projeto local)" }
        if isApple { return "Apple (componente do macOS)" }
        if isAppStore { return "Mac App Store" + (team.map { " · time \($0)" } ?? "") }
        if let a = authority { return a }
        return "Assinatura ad-hoc (sem desenvolvedor identificado)"
    }
}

struct LaunchJob {
    let label: String
    let plist: String
    let domain: String
    let runAtLoad: Bool
    let keepAlive: Bool
    let isUserAgent: Bool
    let isDaemon: Bool

    var sentence: String {
        var s = "Inicia sozinho pelo launchd como \(label) (\(domain))."
        if keepAlive { s += " Se for fechado, o sistema abre de novo." }
        return s
    }

    var stopCommand: String? {
        if plist.hasPrefix("/System/") { return nil }
        if isDaemon { return "sudo launchctl bootout system/\(label)" }
        return "launchctl bootout gui/\(getuid())/\(label)"
    }
}

/// Informações sobre executáveis: app dono, assinatura, launchd e manual. Tudo com cache.
final class AppCatalog {
    static let shared = AppCatalog()

    private let lock = NSLock()
    private var apps: [String: AppInfo?] = [:]
    private var signings: [String: SigningInfo] = [:]
    private var launchIndex: [String: LaunchJob]?
    private var embeddedScanned: Set<String> = []
    private var man: [String: String] = [:]
    private var manLoaded = false

    // MARK: App

    func outermostAppPath(_ path: String) -> String? {
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    func appInfo(appPath: String) -> AppInfo? {
        lock.lock()
        if let c = apps[appPath] { lock.unlock(); return c }
        lock.unlock()
        let info = Self.readApp(appPath)
        lock.lock(); apps[appPath] = info; lock.unlock()
        return info
    }

    func app(forExecutable path: String) -> AppInfo? {
        outermostAppPath(path).flatMap { appInfo(appPath: $0) }
    }

    func liveName(path: String) -> String {
        app(forExecutable: path)?.name ?? (path as NSString).lastPathComponent
    }

    private static func readApp(_ appPath: String) -> AppInfo? {
        let fallback = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let url = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: url) as? [String: Any] else {
            return AppInfo(path: appPath, name: fallback, bundleId: nil, version: nil)
        }
        var name = (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String) ?? fallback
        if name.isEmpty || name.hasPrefix("$(") { name = fallback }
        return AppInfo(path: appPath, name: name, bundleId: d["CFBundleIdentifier"] as? String,
                       version: d["CFBundleShortVersionString"] as? String)
    }

    // MARK: Assinatura

    func signing(_ path: String) -> SigningInfo {
        lock.lock()
        if let s = signings[path] { lock.unlock(); return s }
        lock.unlock()
        let s = Self.readSigning(path)
        lock.lock(); signings[path] = s; lock.unlock()
        return s
    }

    private static func readSigning(_ path: String) -> SigningInfo {
        let none = SigningInfo(isSigned: false, isApple: false, isAppStore: false, authority: nil, team: nil)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return none }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else { return none }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        var authority: String?
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            authority = SecCertificateCopySubjectSummary(leaf) as String?
        }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adhoc = (flags & 0x2) != 0
        if authority == nil && !adhoc && info[kSecCodeInfoIdentifier as String] == nil { return none }
        let isApple = authority == "Software Signing"
        let isStore = authority == "Apple Mac OS Application Signing"
        return SigningInfo(isSigned: true, isApple: isApple, isAppStore: isStore, authority: authority, team: team)
    }

    // MARK: launchd

    func launchJob(for path: String) -> LaunchJob? {
        if path.contains("/Contents/Library/LoginItems/"), let outer = outermostAppPath(path), let app = appInfo(appPath: outer) {
            let helper = ((path.components(separatedBy: "/Contents/Library/LoginItems/").last ?? "") as NSString).pathComponents.first ?? "helper"
            return LaunchJob(label: helper, plist: "", domain: "item de início do app \(app.name)", runAtLoad: true, keepAlive: false, isUserAgent: true, isDaemon: false)
        }
        lock.lock()
        if launchIndex == nil { launchIndex = Self.buildIndex() }
        if let outer = outermostAppPath(path), !embeddedScanned.contains(outer) {
            embeddedScanned.insert(outer)
            for (k, v) in Self.scanEmbedded(appPath: outer) { launchIndex?[k] = v }
        }
        let job = launchIndex?[path]
        lock.unlock()
        return job
    }

    func plistPath(forLabel label: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if launchIndex == nil { launchIndex = Self.buildIndex() }
        return launchIndex?.values.first { $0.label == label && !$0.plist.isEmpty }?.plist
    }

    private static func buildIndex() -> [String: LaunchJob] {
        let home = NSHomeDirectory()
        let dirs: [(String, String, Bool)] = [
            ("/System/Library/LaunchDaemons", "serviço do sistema", true),
            ("/System/Library/LaunchAgents", "agente do sistema", false),
            ("/Library/LaunchDaemons", "serviço de terceiro, roda como administrador desde o boot", true),
            ("/Library/LaunchAgents", "agente de terceiro, abre em todo login", false),
            (home + "/Library/LaunchAgents", "agente do seu usuário, abre no seu login", false),
        ]
        var out: [String: LaunchJob] = [:]
        for (dir, domain, daemon) in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") {
                let p = dir + "/" + f
                guard let d = NSDictionary(contentsOfFile: p) as? [String: Any], let job = makeJob(d, plist: p, domain: domain, daemon: daemon) else { continue }
                if let prog = (d["Program"] as? String) ?? ((d["ProgramArguments"] as? [String])?.first) {
                    out[prog] = job
                }
            }
        }
        return out
    }

    private static func scanEmbedded(appPath: String) -> [String: LaunchJob] {
        var out: [String: LaunchJob] = [:]
        for (sub, daemon) in [("Contents/Library/LaunchAgents", false), ("Contents/Library/LaunchDaemons", true)] {
            let dir = appPath + "/" + sub
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") {
                let p = dir + "/" + f
                guard let d = NSDictionary(contentsOfFile: p) as? [String: Any],
                      let job = makeJob(d, plist: p, domain: "registrado pelo próprio app, aparece em Itens de Início", daemon: daemon) else { continue }
                if let bp = d["BundleProgram"] as? String { out[appPath + "/" + bp] = job }
                if let prog = (d["Program"] as? String) ?? ((d["ProgramArguments"] as? [String])?.first) { out[prog] = job }
            }
        }
        return out
    }

    private static func makeJob(_ d: [String: Any], plist: String, domain: String, daemon: Bool) -> LaunchJob? {
        guard let label = d["Label"] as? String else { return nil }
        let keep: Bool
        if let b = d["KeepAlive"] as? Bool { keep = b } else { keep = d["KeepAlive"] is [String: Any] }
        return LaunchJob(label: label, plist: plist, domain: domain, runAtLoad: (d["RunAtLoad"] as? Bool) ?? false,
                         keepAlive: keep, isUserAgent: !daemon, isDaemon: daemon)
    }

    // MARK: Manual (man)

    func manSummary(for name: String) -> String? {
        guard name.range(of: "^[A-Za-z0-9._+-]{2,60}$", options: .regularExpression) != nil else { return nil }
        lock.lock()
        if !manLoaded {
            manLoaded = true
            if let data = try? Data(contentsOf: Paths.manCache), let d = try? JSONDecoder().decode([String: String].self, from: data) { man = d }
        }
        if let c = man[name] { lock.unlock(); return c.isEmpty ? nil : c }
        lock.unlock()

        let text = Self.runMan(name)
        let summary = text.flatMap { Self.parseMan($0, name: name) } ?? ""
        lock.lock()
        man[name] = summary
        let snapshot = man
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Paths.manCache) }
        return summary.isEmpty ? nil : summary
    }

    private static func runMan(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "/usr/bin/man \(name) 2>/dev/null | /usr/bin/col -b"]
        var env = ProcessInfo.processInfo.environment
        env["MANPAGER"] = "cat"; env["PAGER"] = "cat"; env["MANWIDTH"] = "120"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func parseMan(_ text: String, name: String) -> String? {
        var nameLine: String?
        var desc: [String] = []
        var section = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isHeader = !raw.hasPrefix(" ") && !raw.hasPrefix("\t") && !line.isEmpty && line == line.uppercased() && line.count < 40
            if isHeader {
                section = line
                if section != "NAME" && section != "DESCRIPTION" && !desc.isEmpty { break }
                continue
            }
            if section == "NAME", nameLine == nil, !line.isEmpty { nameLine = line }
            if section == "DESCRIPTION" {
                if line.isEmpty { if desc.isEmpty { continue } else { break } }
                desc.append(line)
            }
        }
        guard let nl = nameLine, nl.lowercased().hasPrefix(name.lowercased()) else { return nil }
        var out = nl.replacingOccurrences(of: " – ", with: ": ").replacingOccurrences(of: " - ", with: ": ")
        if !desc.isEmpty { out += ". " + desc.joined(separator: " ") }
        return out.count > 520 ? String(out.prefix(520)) + "…" : out
    }
}
