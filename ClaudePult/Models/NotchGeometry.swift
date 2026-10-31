import AppKit

/// Where the MacBook notch is and how big the island around it gets (docs/SPEC-notch.md §2). Pure numbers, so
/// tests can feed it the values a real screen reports; nothing about notch sizes is hard-coded.
struct NotchGeometry: Equatable, Sendable {
    /// The notch in screen coordinates (origin bottom-left, as AppKit has it).
    var notch: CGRect
    /// The whole screen the notch belongs to.
    var screen: CGRect

    /// Room on each side of the notch for an «ear» (SPEC-notch §3.1).
    static let earWidth: CGFloat = 38
    /// The card under the notch when the island is open (SPEC-notch §3.3).
    static let cardWidth: CGFloat = 380
    static let cardHeight: CGFloat = 250

    /// The notch from what `NSScreen` reports: the gap between the two menu bar areas beside it, as tall as the top
    /// safe-area inset. nil when the screen has no notch.
    init?(screen: CGRect, safeAreaTop: CGFloat, topLeftArea: CGRect?, topRightArea: CGRect?) {
        guard safeAreaTop > 0, let left = topLeftArea, let right = topRightArea, right.minX > left.maxX else { return nil }
        notch = CGRect(x: left.maxX, y: screen.maxY - safeAreaTop, width: right.minX - left.maxX, height: safeAreaTop)
        self.screen = screen
    }

    init(notch: CGRect, screen: CGRect) {
        self.notch = notch
        self.screen = screen
    }

    /// The notch and its ears: what the island covers at rest, and where hovering opens it.
    var restFrame: CGRect { notch.insetBy(dx: -Self.earWidth, dy: 0) }

    /// The island's window: wide and tall enough for the open card, centred under the notch, kept on the screen.
    var windowFrame: CGRect {
        let width = min(max(Self.cardWidth, restFrame.width), screen.width)
        let height = notch.height + Self.cardHeight
        let x = min(max(notch.midX - width / 2, screen.minX), screen.maxX - width)
        return CGRect(x: x, y: screen.maxY - height, width: width, height: height)
    }

    /// Where the notch sits inside the window, from its left edge.
    var notchOffsetInWindow: CGFloat { notch.minX - windowFrame.minX }
}

extension NotchGeometry {
    /// Pretends the main screen has a notch, for checking the island on a Mac without one:
    /// `defaults write com.demishev.claudepult notchSimulate -bool YES`. Not in the interface.
    static let simulateKey = "notchSimulate"

    /// The first screen with a notch — on a MacBook, its built-in display.
    @MainActor static func current(simulate: Bool = UserDefaults.standard.bool(forKey: simulateKey)) -> (NSScreen, NotchGeometry)? {
        for screen in NSScreen.screens {
            if let geometry = NotchGeometry(screen: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                            topLeftArea: screen.auxiliaryTopLeftArea, topRightArea: screen.auxiliaryTopRightArea) {
                return (screen, geometry)
            }
        }
        guard simulate, let screen = NSScreen.main else { return nil }
        let height = max(NSStatusBar.system.thickness, 32)
        let notch = CGRect(x: screen.frame.midX - 92, y: screen.frame.maxY - height, width: 184, height: height)
        return (screen, NotchGeometry(notch: notch, screen: screen.frame))
    }

    /// Whether this Mac has a screen with a notch right now (the assistant offers the island only then).
    @MainActor static var macHasNotch: Bool { current() != nil }
}
