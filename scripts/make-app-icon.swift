// Generates ClaudePult/Resources/Assets.xcassets/AppIcon.appiconset from code, so the icon is reproducible.
// Usage: swift scripts/make-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appending(path: "ClaudePult/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

/// macOS icon grid: 1024 canvas, 824 body with ~185 corner radius, drop shadow below.
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

    // Shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.set()
    NSColor(calibratedRed: 0.80, green: 0.42, blue: 0.29, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Warm gradient, lighter at the top.
    NSGradient(colors: [
        NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.43, alpha: 1),
        NSColor(calibratedRed: 0.78, green: 0.38, blue: 0.26, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // A "panel" card under the sparkle: the app is a control panel in the menu bar.
    let card = NSRect(x: body.minX + 170 * scale, y: body.minY + 150 * scale, width: 484 * scale, height: 120 * scale)
    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: card, xRadius: 36 * scale, yRadius: 36 * scale).fill()
    for (index, width) in [300.0, 200.0].enumerated() {
        let line = NSRect(x: card.minX + 40 * scale, y: card.maxY - (44 + Double(index) * 38) * scale, width: width * scale, height: 16 * scale)
        NSColor.white.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: line, xRadius: 8 * scale, yRadius: 8 * scale).fill()
    }

    // The sparkle.
    let config = NSImage.SymbolConfiguration(pointSize: 360 * scale, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = sparkle.size
        sparkle.draw(in: NSRect(x: body.midX - s.width / 2, y: body.minY + 330 * scale, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = points * factor
        let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        let data = drawIcon(size: CGFloat(pixels)).representation(using: .png, properties: [:])!
        try data.write(to: iconSet.appending(path: name))
        images.append(["idiom": "mac", "scale": "\(factor)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appending(path: "Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.deletingLastPathComponent().appending(path: "Contents.json"))
print("Wrote \(images.count) images to \(iconSet.path)")
