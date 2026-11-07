import AppKit

/// Where the MacBook notch is and how big the island around it gets (docs/specs/SPEC-notch.md §2). Pure numbers, so
/// tests can feed it the values a real screen reports; nothing about notch sizes is hard-coded.
struct NotchGeometry: Equatable, Sendable {
    /// The notch in screen coordinates (origin bottom-left, as AppKit has it).
    var notch: CGRect
    /// The whole screen the notch belongs to.
    var screen: CGRect
    /// No notch on this screen: a black pill under the menu bar, centred, only for events and the open card
    /// (SPEC-notch §5). Its «notch» is a zero-height strip at the menu bar's bottom edge.
    var isPill = false

    /// The pill's width while it shows nothing wider.
    static let pillWidth: CGFloat = 200

    /// Room on each side of the notch for an «ear» (SPEC-notch §3.1).
    static let earWidth: CGFloat = 38
    /// The card under the notch when the island is open (SPEC-notch §3.3).
    static let cardWidth: CGFloat = 380
    static let cardHeight: CGFloat = 250
    /// Room under the notch for the tallest card (requests, limits, sessions and a task list); the window is
    /// transparent and lets clicks through below the black part.
    static let windowHeight: CGFloat = 520
    /// The open requests scroll past this height, so the buttons of the last one stay in the card.
    static let requestsHeight: CGFloat = 230

    /// The notch from what `NSScreen` reports: the gap between the two menu bar areas beside it, as tall as the top
    /// safe-area inset. nil when the screen has no notch.
    init?(screen: CGRect, safeAreaTop: CGFloat, topLeftArea: CGRect?, topRightArea: CGRect?) {
        guard safeAreaTop > 0, let left = topLeftArea, let right = topRightArea, right.minX > left.maxX else { return nil }
        notch = CGRect(x: left.maxX, y: screen.maxY - safeAreaTop, width: right.minX - left.maxX, height: safeAreaTop)
        self.screen = screen
    }

    init(notch: CGRect, screen: CGRect, isPill: Bool = false) {
        self.notch = notch
        self.screen = screen
        self.isPill = isPill
    }

    /// The pill on a screen without a notch: just under its menu bar (`menuBarBottom`), centred.
    static func pill(screen: CGRect, menuBarBottom: CGFloat) -> NotchGeometry {
        NotchGeometry(notch: CGRect(x: screen.midX - pillWidth / 2, y: menuBarBottom, width: pillWidth, height: 0),
                      screen: screen, isPill: true)
    }

    /// The notch and its ears: what the island covers at rest, and where hovering opens it.
    var restFrame: CGRect { notch.insetBy(dx: -Self.earWidth, dy: 0) }

    /// The notch and the ears that show something: what the black shape covers and what the pointer reacts to. A side
    /// with nothing on it stays free for the menus and status items there.
    func restFrame(left: Bool, right: Bool) -> CGRect {
        let (before, after) = (left ? Self.earWidth : 0, right ? Self.earWidth : 0)
        return CGRect(x: notch.minX - before, y: notch.minY, width: notch.width + before + after, height: notch.height)
    }

    /// The island's window: wide and tall enough for the open card, centred under the notch, kept on the screen.
    /// Its top is the notch's top — the screen's top edge, or the menu bar's bottom for the pill.
    var windowFrame: CGRect {
        let width = min(max(Self.cardWidth, restFrame.width), screen.width)
        let height = notch.height + Self.windowHeight
        let x = min(max(notch.midX - width / 2, screen.minX), screen.maxX - width)
        return CGRect(x: x, y: notch.maxY - height, width: width, height: height)
    }

    /// Where the notch sits inside the window, from its left edge.
    var notchOffsetInWindow: CGFloat { notch.minX - windowFrame.minX }
}

extension NotchGeometry {
    /// Pretends the main screen has a notch, for checking the island on a Mac without one:
    /// `defaults write com.demishev.claudepult notchSimulate -bool YES`. Not in the interface.
    static let simulateKey = "notchSimulate"

    /// A screen as the island needs it.
    struct Screen: Equatable, Sendable {
        var frame: CGRect
        var visibleFrame: CGRect
        var safeAreaTop: CGFloat
        var topLeftArea: CGRect?
        var topRightArea: CGRect?
        var isMain: Bool

        var notchGeometry: NotchGeometry? {
            NotchGeometry(screen: frame, safeAreaTop: safeAreaTop, topLeftArea: topLeftArea, topRightArea: topRightArea)
        }

        /// The pill, under the menu bar (the visible frame's top; a screen without a menu bar has its own top).
        var pillGeometry: NotchGeometry { .pill(screen: frame, menuBarBottom: min(visibleFrame.maxY, frame.maxY)) }

        /// A 184 pt notch in the middle of the top edge, at least as tall as the menu bar (`notchSimulate`).
        mutating func simulateNotch() {
            safeAreaTop = max(frame.maxY - visibleFrame.maxY, 32)
            let y = frame.maxY - safeAreaTop
            topLeftArea = CGRect(x: frame.minX, y: y, width: frame.width / 2 - 92, height: safeAreaTop)
            topRightArea = CGRect(x: frame.midX + 92, y: y, width: frame.width / 2 - 92, height: safeAreaTop)
        }
    }

    /// Where the islands go (SPEC-notch §5): on the chosen screen its notch, else — when the pill is on — a pill
    /// on the main screen; «на всех экранах» — one on every screen, the pill where there is no notch. Empty: nowhere.
    static func choose(_ screens: [Screen], on choice: NotchScreen, pill: Bool) -> [NotchGeometry] {
        let main = screens.first(where: \.isMain) ?? screens.first
        switch choice {
        case .notch:
            if let notched = screens.lazy.compactMap(\.notchGeometry).first { return [notched] }
        case .main:
            if let notched = main?.notchGeometry { return [notched] }
        case .all:
            return screens.compactMap { $0.notchGeometry ?? (pill ? $0.pillGeometry : nil) }
        }
        return pill ? main.map { [$0.pillGeometry] } ?? [] : []
    }

    @MainActor static var screens: [Screen] {
        let simulate = UserDefaults.standard.bool(forKey: simulateKey)
        return NSScreen.screens.map { screen in
            var result = Screen(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                                topLeftArea: screen.auxiliaryTopLeftArea, topRightArea: screen.auxiliaryTopRightArea,
                                isMain: screen == NSScreen.main)
            if simulate, result.isMain, result.notchGeometry == nil { result.simulateNotch() }
            return result
        }
    }

    /// The islands' places with these settings, simulated notch included.
    @MainActor static func places(for settings: NotchSettings) -> [NotchGeometry] {
        choose(screens, on: settings.screen, pill: settings.showsPill(macHasNotch: macHasNotch))
    }

    /// Whether this Mac has a screen with a notch right now, simulated included (the assistant offers the island only then).
    @MainActor static var macHasNotch: Bool { screens.contains { $0.notchGeometry != nil } }
}
