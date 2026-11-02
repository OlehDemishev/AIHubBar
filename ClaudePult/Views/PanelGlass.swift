import AppKit
import SwiftUI

/// «Стекло» background of the menu bar panel (macOS 26+). The `MenuBarExtra` window's own background is a
/// Liquid Glass backdrop SwiftUI draws inside the hosting view — a full-size `CABackdropLayer` (seen on macOS 27),
/// denser than Control Center's; `containerBackground(for: .window)` doesn't reach it. With «Стекло» the panel
/// hides only that backdrop layer (its holder also carries the portal SwiftUI draws the content through — hiding
/// the holder blanks the panel) and puts a clear `NSGlassEffectView` behind the hosting view; the cards turn into
/// glass tiles (`panelCard()`). When the backdrop isn't found, the window is left alone.
@MainActor
enum PanelGlass {
    /// Corner radius of the system panel window (its backdrop's rounded shape on macOS 27).
    nonisolated static let defaultCornerRadius: CGFloat = 16

    private static var hiddenLayers: [CALayer] = []
    private static weak var glassView: NSView?
    private static var lastLogged: String?

    /// Whether the panel can use glass on this Mac now: macOS 26+ and «Уменьшить прозрачность» off.
    static func isAvailable(reduceTransparency: Bool) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return !reduceTransparency
    }

    /// Switches the panel window to glass or back. Returns whether the panel now draws glass.
    @discardableResult
    static func apply(_ glass: Bool, to window: NSWindow?) -> Bool {
        guard glass, #available(macOS 26.0, *), let hosting = window?.contentView, let frame = hosting.superview else {
            restore()
            return false
        }
        let backdrops = systemBackdrops(in: hosting)
        guard !backdrops.isEmpty else {
            if glassView?.superview == nil {
                log("Glass panel: no system backdrop found in \(type(of: window!)), keeping the standard background")
            }
            return glassView?.superview != nil
        }
        for layer in backdrops where !layer.isHidden {
            layer.isHidden = true
            if !hiddenLayers.contains(where: { $0 === layer }) { hiddenLayers.append(layer) }
        }
        if glassView?.superview !== frame {
            glassView?.removeFromSuperview()
            let view = NSGlassEffectView(frame: hosting.frame)
            view.style = .clear
            view.cornerRadius = cornerRadius(of: backdrops) ?? defaultCornerRadius
            view.autoresizingMask = [.width, .height]
            frame.addSubview(view, positioned: .below, relativeTo: hosting)
            glassView = view
            log("Glass panel: hid \(backdrops.count) system backdrop(s), clear glass with corner radius \(view.cornerRadius)")
        }
        return true
    }

    /// Puts the system background back.
    static func restore() {
        for layer in hiddenLayers { layer.isHidden = false }
        hiddenLayers = []
        glassView?.removeFromSuperview()
        glassView = nil
    }

    /// Backdrop layers as large as the hosting view: the window's background, not a card's glass.
    private static func systemBackdrops(in hosting: NSView) -> [CALayer] {
        let size = hosting.bounds.size
        var result: [CALayer] = []
        func walk(_ layer: CALayer) {
            if String(describing: type(of: layer)) == "CABackdropLayer",
               layer.frame.width >= size.width - 1, layer.frame.height >= size.height - 1 {
                result.append(layer)
                return
            }
            // A view's layer lists its subviews' layers too; those are walked with their views.
            layer.sublayers?.filter { !($0.delegate is NSView) }.forEach(walk)
        }
        func walk(_ view: NSView) {
            guard view.frame.width >= size.width - 1 || view === hosting else { return }
            if let layer = view.layer { walk(layer) }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        return result
    }

    /// The rounded shape SwiftUI masks the backdrop with, if it has one.
    private static func cornerRadius(of backdrops: [CALayer]) -> CGFloat? {
        var radius: CGFloat?
        func walk(_ layer: CALayer) {
            if radius == nil, layer.cornerRadius > 0 { radius = layer.cornerRadius }
            layer.sublayers?.forEach(walk)
        }
        backdrops.forEach(walk)
        return radius
    }

    private static func log(_ message: String) {
        guard message != lastLogged else { return }
        lastLogged = message
        AppLog.info(message)
    }
}
