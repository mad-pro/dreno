import SwiftUI
import AppKit

/// Grade adaptativa simples: quantas colunas couberem com a largura mínima, linhas com a mesma altura.
struct AdaptiveGrid: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat = 10

    private func columns(_ width: CGFloat) -> (count: Int, itemWidth: CGFloat) {
        let count = max(1, Int((width + spacing) / (minWidth + spacing)))
        return (count, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    private func rowHeights(_ subviews: Subviews, cols: Int, itemWidth: CGFloat) -> [CGFloat] {
        var rows: [CGFloat] = []
        for (i, s) in subviews.enumerated() {
            let h = s.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height
            if i % cols == 0 { rows.append(h) } else { rows[rows.count - 1] = max(rows[rows.count - 1], h) }
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let c = columns(width)
        let rows = rowHeights(subviews, cols: c.count, itemWidth: c.itemWidth)
        let height = rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let c = columns(bounds.width)
        let rows = rowHeights(subviews, cols: c.count, itemWidth: c.itemWidth)
        var y = bounds.minY
        for (i, s) in subviews.enumerated() {
            let row = i / c.count, col = i % c.count
            if col == 0 && row > 0 { y += rows[row - 1] + spacing }
            let x = bounds.minX + CGFloat(col) * (c.itemWidth + spacing)
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: c.itemWidth, height: rows[row]))
        }
    }
}

struct PatternBadge: View {
    let pattern: Pattern

    var body: some View {
        Text(pattern.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(strong ? color : color.opacity(0.16)))
            .foregroundStyle(strong ? Color.white : Color.secondary)
    }

    private var strong: Bool { pattern == .continuo || pattern == .frequente }

    private var color: Color {
        switch pattern {
        case .continuo: return .red
        case .frequente: return .orange
        case .picos: return .blue
        case .leve: return .gray
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 5)
            Path { p in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(width: 150, height: 34)
        .accessibilityHidden(true)
    }
}

struct MetricView: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct StatCard: View {
    let value: String
    let label: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

struct AppIcon: View {
    let path: String?
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let path, let img = IconCache.shared.icon(path) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Image(systemName: "cpu").resizable().scaledToFit().padding(size * 0.2).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(_ path: String) -> NSImage? {
        if let c = cache[path] { return c }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }
}

/// Fecha processos de um grupo (só do próprio usuário).
enum Terminator {
    static func running(_ id: GroupIdentity) -> [Int32] {
        let me = getuid()
        let rows = ProcessLister.list().filter { $0.uid == me && $0.pid != getpid() }
        if id.isAppGroup, let app = id.appPath {
            return rows.filter { $0.command.hasPrefix(app + "/") }.map(\.pid)
        }
        guard let p = id.path else { return [] }
        return rows.filter { $0.command == p }.map(\.pid)
    }

    @discardableResult
    static func terminate(_ id: GroupIdentity) -> Int {
        var count = 0
        if id.isAppGroup, let app = id.appPath {
            for ra in NSWorkspace.shared.runningApplications where ra.bundleURL?.path == app {
                if ra.terminate() { count += 1 }
            }
            if count > 0 { return count }
        }
        for pid in running(id) where kill(pid, SIGTERM) == 0 { count += 1 }
        return count
    }
}
