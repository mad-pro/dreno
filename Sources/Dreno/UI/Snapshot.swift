import SwiftUI
import AppKit

/// Renderiza o relatório em PNG sem abrir janela (usado pelo comando --snapshot).
@MainActor
enum Snapshot {
    static func render(_ b: ReportBundle, to path: String, dark: Bool) -> Bool {
        let view = ReportContent(bundle: b, selection: .constant(nil), aiAvailable: false, onApplyRange: {}, onAskAI: { _ in })
            .environment(\.colorScheme, dark ? .dark : .light)
        return renderView(view, width: 1100, to: path)
    }

    static func renderView<V: View>(_ content: V, width: CGFloat, to path: String) -> Bool {
        let view = content
            .padding(24)
            .frame(width: width)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
