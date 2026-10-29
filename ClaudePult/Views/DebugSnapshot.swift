import AppKit
import SwiftUI

/// Developer aid: saves a PNG of the panel window each time it opens, to ~/Library/Logs/ClaudePult/panel.png.
/// The app's windows are hidden from screen-capture automation, so this is how the panel is checked visually.
/// Enable: `defaults write com.demishev.claudepult DebugPanelSnapshot -bool YES`;
/// optionally expand one project on open: `defaults write com.demishev.claudepult DebugPanelExpand <name>`.
enum DebugSnapshot {
    static let defaultsKey = "DebugPanelSnapshot"
    static let fileURL = AppLog.directory.appending(path: "panel.png")

    static func fileURL(_ name: String) -> URL { AppLog.directory.appending(path: "\(name).png") }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    static var projectToExpand: String? {
        isEnabled ? UserDefaults.standard.string(forKey: "DebugPanelExpand") : nil
    }

    @MainActor
    static func capture(_ window: NSWindow?, name: String = "panel") {
        // Render the layer tree: SwiftUI draws symbols, shapes and colours into layers,
        // which `cacheDisplay(in:to:)` leaves out.
        guard let window = window ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.level == .popUpMenu || $0.className.contains("MenuBarExtra") }),
              let contentView = window.contentView else {
            AppLog.error("Snapshot \(name): no window")
            return
        }
        var candidates: [NSView] = [contentView]
        var parent = contentView.superview
        while let view = parent {
            candidates.append(view)
            parent = view.superview
        }
        // Debug-only: make the content view layer-backed if nothing in the chain is.
        if candidates.allSatisfy({ $0.layer == nil }) { contentView.wantsLayer = true }
        guard let view = candidates.first(where: { $0.layer != nil }), let layer = view.layer else {
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
            try png.write(to: fileURL(name))
            AppLog.info("Snapshot \(name).png saved, window frame \(NSStringFromRect(window.frame))")
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

extension View {
    /// Debug-only: saves a PNG of the hosting window to ~/Library/Logs/ClaudePult/<name>.png once it is shown.
    func debugSnapshot(_ name: String) -> some View {
        background(WindowReader { window in
            guard DebugSnapshot.isEnabled, let window else { return }
            Task {
                try? await Task.sleep(for: .seconds(1))
                DebugSnapshot.capture(window, name: name)
            }
        })
    }
}
