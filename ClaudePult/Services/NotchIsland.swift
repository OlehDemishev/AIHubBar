import AppKit
import Observation
import SwiftUI

/// What one «ear» beside the notch shows (SPEC-notch §3.1).
enum NotchEar: String, Codable, CaseIterable, Sendable {
    case sessionLimit, weekLimit, sessions, background, none

    var title: String {
        switch self {
        case .sessionLimit: String(localized: "Лимит сессии")
        case .weekLimit: String(localized: "Лимит недели")
        case .sessions: String(localized: "Сессии Claude Code")
        case .background: String(localized: "Фоновые задачи")
        case .none: String(localized: "Ничего")
        }
    }
}

/// Settings → «Модули» → «Остров у чёлки» (SPEC-notch §6). Unknown keys from newer versions are ignored.
struct NotchSettings: Codable, Equatable, Sendable {
    var leftEar: NotchEar = .sessionLimit
    var rightEar: NotchEar = .sessions
    /// Open the card when the pointer rests on the notch; off = only on a click.
    var openOnHover = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NotchSettings()
        leftEar = (try? c.decodeIfPresent(NotchEar.self, forKey: .leftEar)) ?? defaults.leftEar
        rightEar = (try? c.decodeIfPresent(NotchEar.self, forKey: .rightEar)) ?? defaults.rightEar
        openOnHover = (try? c.decodeIfPresent(Bool.self, forKey: .openOnHover)) ?? defaults.openOnHover
    }
}

/// The island around the notch (docs/SPEC-notch.md): a borderless panel above the menu bar that never takes focus.
/// At rest it lets every click through to the menu bar; hovering over the notch (or a click) opens the card, moving
/// away closes it. Nothing runs on a timer: the window is moved only when screens change, the pointer is watched only
/// while the module is installed and the Mac has a notch.
@MainActor
@Observable
final class NotchIsland {
    private(set) var isOpen = false
    private(set) var geometry: NotchGeometry?
    /// The open card's height under the notch, measured by the view.
    var cardHeight: CGFloat = NotchGeometry.cardHeight

    /// Whether the module is installed (set by the app).
    @ObservationIgnored var isActive: () -> Bool = { false }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var content: (() -> AnyView)?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    /// How long the pointer rests on the notch before the card opens, and how long it may stray before it closes.
    static let openDelay: Duration = .milliseconds(300)
    static let closeDelay: Duration = .milliseconds(400)

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start(content: @escaping () -> AnyView) {
        self.content = content
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        observe()
    }

    /// Re-runs `update` whenever the installed modules change.
    private func observe() {
        withObservationTracking {
            _ = isActive()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update()
    }

    func update() {
        guard isActive(), let (_, geometry) = NotchGeometry.current() else {
            tearDown()
            return
        }
        if self.geometry != geometry {
            AppLog.info("Notch island at \(NSStringFromRect(geometry.notch))")
            self.geometry = geometry
        }
        let panel = self.panel ?? makePanel()
        panel.setFrame(geometry.windowFrame, display: true)
        panel.ignoresMouseEvents = !isOpen
        panel.orderFrontRegardless()
        if monitors.isEmpty { watchPointer() }
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel()
        if let content {
            let host = NSHostingView(rootView: content())
            host.sizingOptions = []
            panel.contentView = host
        }
        self.panel = panel
        return panel
    }

    private func tearDown() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        pending?.cancel()
        isOpen = false
        panel?.orderOut(nil)
        panel = nil
        if geometry != nil { AppLog.info("Notch island hidden") }
        geometry = nil
    }

    // MARK: - Pointer

    private func watchPointer() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged]
        // Global: the pointer over other apps and the menu bar (mouse events need no permission). Local: over the
        // island itself once it takes clicks.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointer(event.type) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events.union(.keyDown), handler: { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown, event.keyCode == 53 { self?.close() } else { self?.pointer(event.type) }
            }
            return event
        }) { monitors.append(local) }
    }

    /// The open card in screen coordinates.
    private var cardFrame: CGRect? {
        guard let geometry else { return nil }
        let window = geometry.windowFrame
        let height = min(geometry.notch.height + cardHeight, window.height)
        return CGRect(x: window.minX, y: window.maxY - height, width: window.width, height: height)
    }

    private func pointer(_ type: NSEvent.EventType) {
        guard let geometry else { return }
        let location = NSEvent.mouseLocation
        if isOpen {
            let inside = cardFrame?.contains(location) ?? false
            if inside {
                pending?.cancel()
            } else if type == .leftMouseDown {
                close()
            } else if !isPending {
                schedule(after: Self.closeDelay) { [weak self] in self?.close() }
            }
        } else if geometry.restFrame.contains(location) {
            if type == .leftMouseDown {
                open()
            } else if settings.notch.openOnHover, !isPending {
                schedule(after: Self.openDelay) { [weak self] in
                    guard let self, let geometry = self.geometry, geometry.restFrame.contains(NSEvent.mouseLocation) else { return }
                    self.open()
                }
            }
        } else {
            pending?.cancel()
        }
    }

    private var isPending: Bool { pending.map { !$0.isCancelled } ?? false }

    private func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            action()
        }
    }

    func open() {
        pending?.cancel()
        guard !isOpen, geometry != nil else { return }
        isOpen = true
        panel?.ignoresMouseEvents = false
    }

    func close() {
        pending?.cancel()
        guard isOpen else { return }
        isOpen = false
        panel?.ignoresMouseEvents = true
    }
}

/// A panel that floats above the menu bar on every desktop, never activates the app and may sit over the notch.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // Not over full-screen apps yet: there the island shows only requests (SPEC-notch §5, stage 3).
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        setAccessibilityLabel(String(localized: "Остров у чёлки"))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps windows below the menu bar; this one belongs over it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
