import AppKit
import SwiftUI

/// «Стекло» background of the menu bar panel (macOS 26+): the system's menu material is denser than Control
/// Center's, so the panel hides it and draws Liquid Glass itself (`PanelGlassBackground`). The `MenuBarExtra`
/// window's views are private, so this only touches what it recognises — a full-size `NSVisualEffectView` or
/// `NSGlassEffectView` behind the content — and leaves the window alone when it finds nothing.
@MainActor
enum PanelGlass {
    /// What was changed in the panel window, to put it back for «Обычный».
    private struct Changes {
        weak var window: NSWindow?
        var hiddenViews: [Weak] = []
        var hiddenLayers: [CALayer] = []
        var wasOpaque = true
        var background: NSColor?
        var cornerRadius: CGFloat = PanelGlass.defaultCornerRadius
    }

    private struct Weak { weak var view: NSView? }

    nonisolated static let defaultCornerRadius: CGFloat = 16
    private static var changes: Changes?
    private static var lastLogged: String?

    /// Whether the panel can use glass on this Mac now: macOS 26+ and «Уменьшить прозрачность» off.
    static func isAvailable(reduceTransparency: Bool) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return !reduceTransparency
    }

    /// Switches the panel window to glass or back. Returns the window's corner radius when glass is on, nil when
    /// the window keeps (or got back) its system background.
    @discardableResult
    static func apply(_ glass: Bool, to window: NSWindow?) -> CGFloat? {
        guard let window else { return nil }
        if !glass {
            restore()
            return nil
        }
        if let changes, changes.window === window {
            // The system may bring its background back when the panel reopens.
            for item in changes.hiddenViews { item.view?.isHidden = true }
            for layer in changes.hiddenLayers { layer.isHidden = true }
            return changes.cornerRadius
        }
        restore()
        guard let content = window.contentView else { return nil }
        var root: NSView = content
        while let parent = root.superview { root = parent }

        var found = Changes(window: window, wasOpaque: window.isOpaque, background: window.backgroundColor)
        let bounds = window.frame.size
        // Views inside the content belong to SwiftUI (including this panel's own glass), not to the window.
        for view in backgrounds(in: root, size: bounds) where view === content || !view.isDescendant(of: content) {
            if let radius = view.layer?.cornerRadius, radius > 0 { found.cornerRadius = radius }
            if content.isDescendant(of: view) {
                // The content sits inside the material view: hide only the material's own layers.
                let own = Set((view.subviews.compactMap(\.layer)).map(ObjectIdentifier.init))
                for layer in view.layer?.sublayers ?? [] where !own.contains(ObjectIdentifier(layer)) && !layer.isHidden {
                    layer.isHidden = true
                    found.hiddenLayers.append(layer)
                }
            } else if !view.isHidden {
                view.isHidden = true
                found.hiddenViews.append(Weak(view: view))
            }
        }
        guard !found.hiddenViews.isEmpty || !found.hiddenLayers.isEmpty else {
            log("Glass panel: no system background found in \(type(of: window)), keeping the standard one")
            return nil
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.invalidateShadow()
        changes = found
        log("Glass panel: hid \(found.hiddenViews.count) view(s) and \(found.hiddenLayers.count) layer(s), corner radius \(found.cornerRadius)")
        return found.cornerRadius
    }

    /// Puts the system background back.
    static func restore() {
        guard let changes else { return }
        self.changes = nil
        for item in changes.hiddenViews { item.view?.isHidden = false }
        for layer in changes.hiddenLayers { layer.isHidden = false }
        if let window = changes.window {
            window.isOpaque = changes.wasOpaque
            window.backgroundColor = changes.background
            window.invalidateShadow()
        }
    }

    /// Material views that cover (nearly) the whole window, outermost first.
    private static func backgrounds(in view: NSView, size: CGSize) -> [NSView] {
        var result: [NSView] = []
        func walk(_ view: NSView) {
            if isMaterial(view), view.frame.width >= size.width - 2, view.frame.height >= size.height - 2 {
                result.append(view)
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return result
    }

    private static func isMaterial(_ view: NSView) -> Bool {
        if view is NSVisualEffectView { return true }
        if #available(macOS 26.0, *), view is NSGlassEffectView { return true }
        return false
    }

    private static func log(_ message: String) {
        guard message != lastLogged else { return }
        lastLogged = message
        AppLog.info(message)
    }
}

/// The panel's glass when its window background is hidden; nothing on older systems.
struct PanelGlassBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
