// Generates Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
    ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]

let background = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.19, alpha: 1)
let background2 = NSColor(calibratedRed: 0.17, green: 0.23, blue: 0.42, alpha: 1)
let amber = NSColor(calibratedRed: 1.0, green: 0.63, blue: 0.22, alpha: 1)

func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

func render(_ px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.09
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: background2, ending: background)?.draw(in: shape, angle: -90)
    if let drop = symbol("drop.fill", size: rect.width * 0.5, color: amber) {
        let s = drop.size
        drop.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2 - rect.height * 0.01, width: s.width, height: s.height))
    }
    if let bolt = symbol("bolt.fill", size: rect.width * 0.2, color: background) {
        let s = bolt.size
        bolt.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2 - rect.height * 0.07, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (name, px) in sizes {
    if let data = render(px) {
        try? data.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
    }
}
print("iconset: \(out)")
