import AppKit
import SwiftUI

/// The island's content view, also the drop destination for a file dragged onto it. The window takes the drag only
/// while a file drag is near the notch (it ignores the mouse otherwise), and accepts it only over the drop zone.
final class NotchHostingView: NSHostingView<AnyView> {
    var onDrop: ([URL]) -> Bool = { _ in false }
    /// Screen point of the drag (nil: it left) → whether it is over the drop zone.
    var onDragOver: (CGPoint?) -> Bool = { _ in false }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty, let window else { return [] }
        return onDragOver(window.convertPoint(toScreen: sender.draggingLocation)) ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { _ = onDragOver(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { operation(sender) == .copy && onDrop(urls(sender)) }
}

/// A panel that floats above the menu bar on every desktop, never activates the app and may sit over the notch.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // Over full-screen apps too: there the island shows only requests and waits (SPEC-notch §5).
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        // Moves inside the card reach the local monitor only with this; without them the click guard never lets go.
        acceptsMouseMovedEvents = true
        setAccessibilityLabel(String(localized: "Остров у чёлки"))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps windows below the menu bar; this one belongs over it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Whether a full-screen app fills a screen (SPEC-notch §5): a normal window of another app as large as the whole
/// screen, menu bar included. Window bounds need no permission (only titles would).
enum FullScreenDetector {
    struct Window: Equatable, Sendable {
        var bounds: CGRect
        var layer: Int
        var pid: Int32
    }

    /// `windows` in Quartz coordinates (origin top-left of the main display, y down); `screen` in AppKit's.
    static func covers(_ windows: [Window], screen: CGRect, mainHeight: CGFloat, ownPID: Int32) -> Bool {
        let target = CGRect(x: screen.minX, y: mainHeight - screen.maxY, width: screen.width, height: screen.height)
        return windows.contains { window in
            window.layer == 0 && window.pid != ownPID && abs(window.bounds.minX - target.minX) < 1 && abs(window.bounds.minY - target.minY) < 1
                && abs(window.bounds.width - target.width) < 1 && abs(window.bounds.height - target.height) < 1
        }
    }

    @MainActor static func isFullScreen(screen: CGRect) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.height else { return false }
        let windows = info.compactMap { entry -> Window? in
            guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = entry[kCGWindowLayer as String] as? Int, let pid = entry[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            return Window(bounds: CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0),
                          layer: layer, pid: pid)
        }
        return covers(windows, screen: screen, mainHeight: mainHeight, ownPID: ProcessInfo.processInfo.processIdentifier)
    }
}
