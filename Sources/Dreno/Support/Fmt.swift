import Foundation

/// Formatação em português (vírgula decimal).
enum Fmt {
    private static let lock = NSLock()
    private static let nf: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.numberStyle = .decimal
        return f
    }()

    static func num(_ v: Double, _ digits: Int = 1) -> String {
        lock.lock(); defer { lock.unlock() }
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: NSNumber(value: v)) ?? String(format: "%.\(digits)f", v)
    }

    static func pct(_ v: Double) -> String {
        if v == 0 { return "0%" }
        if v >= 10 { return num(v, 0) + "%" }
        if v < 0.1 { return "<0,1%" }
        return num(v, 1) + "%"
    }

    static func duration(_ s: Double) -> String {
        if s <= 0 { return "0 s" }
        if s < 1 { return "<1 s" }
        if s < 60 { return "\(Int(s.rounded())) s" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m) min" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h) h" : "\(h) h \(mm) min"
    }

    static func bytes(_ b: Double) -> String {
        if b >= 1_000_000_000 { return num(b / 1_000_000_000, 1) + " GB" }
        if b >= 1_000_000 { return num(b / 1_000_000, 0) + " MB" }
        return num(b / 1000, 0) + " KB"
    }

    static func watts(_ w: Double) -> String { num(w, 1) + " W" }

    static func wh(joules j: Double) -> String {
        let wh = j / 3600
        if wh > 0 && wh < 0.01 { return "<0,01 Wh" }
        return (wh < 1 ? num(wh, 2) : num(wh, 1)) + " Wh"
    }

    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func hours(_ h: Double) -> String {
        if h < 1 { return "\(Int((h * 60).rounded())) min" }
        let whole = Int(h), mins = Int(((h - Double(whole)) * 60).rounded())
        return mins == 0 ? "\(whole) h" : "\(whole) h \(mins) min"
    }

    private static func df(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = format
        return f
    }
    private static let tf = df("HH:mm")
    private static let dtf = df("dd/MM HH:mm")
    private static let longf = df("EEEE, d 'de' MMMM 'às' HH:mm")
    private static let stampf = df("yyyy-MM-dd-HHmm")

    static func time(_ d: Date) -> String { lock.lock(); defer { lock.unlock() }; return tf.string(from: d) }
    static func dateTime(_ d: Date) -> String { lock.lock(); defer { lock.unlock() }; return dtf.string(from: d) }
    static func long(_ d: Date) -> String { lock.lock(); defer { lock.unlock() }; return longf.string(from: d) }
    static func stamp(_ d: Date) -> String { lock.lock(); defer { lock.unlock() }; return stampf.string(from: d) }
}
