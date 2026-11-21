import SwiftUI
import AppKit

/// Renderiza o relatório em PNG sem abrir janela (usado pelo comando --snapshot).
@MainActor
enum Snapshot {
    static func render(_ b: ReportBundle, to path: String, dark: Bool) -> Bool {
        let view = ReportContent(bundle: b, selection: .constant(nil), aiAvailable: false, onApplyRange: {}, onAskAI: { _ in })
            .padding(24)
            .frame(width: 1100)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 1100, height: nil)
        renderer.scale = 1
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
