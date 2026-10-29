import AppKit
import SwiftUI

/// Developer aid: saves a PNG of the panel window each time it opens, to ~/Library/Logs/ClaudePult/panel.png.
/// The app's windows are hidden from screen-capture automation, so this is how the panel is checked visually.
/// Enable: `defaults write com.demishev.claudepult DebugPanelSnapshot -bool YES`;
/// optionally expand one project on open: `defaults write com.demishev.claudepult DebugPanelExpand <name>`.
enum DebugSnapshot {
    static let defaultsKey = "DebugPanelSnapshot"
    static let fileURL = AppLog.directory.appending(path: "panel.png")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    static var projectToExpand: String? {
        isEnabled ? UserDefaults.standard.string(forKey: "DebugPanelExpand") : nil
    }

    @MainActor
    static func capture(_ window: NSWindow?) {
        // Render the layer tree: SwiftUI draws symbols, shapes and colours into layers,
        // which `cacheDisplay(in:to:)` leaves out.
        guard let window, let contentView = window.contentView,
              let view = [contentView, contentView.superview].compactMap({ $0 }).first(where: { $0.layer != nil }),
              let layer = view.layer
        else {
            AppLog.error("Panel snapshot: no layer-backed window view")
            return
        }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if view.isFlipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
        } else {
            context.scaleBy(x: scale, y: scale)
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.render(in: context)
        }
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do {
            try FileManager.default.createDirectory(at: AppLog.directory, withIntermediateDirectories: true)
            try png.write(to: fileURL)
            AppLog.info("Panel snapshot saved, window frame \(NSStringFromRect(window.frame))")
        } catch {
            AppLog.error("Panel snapshot failed: \(error.localizedDescription)")
        }
    }
}

/// Exposes the hosting `NSWindow` of a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
