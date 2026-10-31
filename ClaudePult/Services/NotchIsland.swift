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
    /// Which events get a banner (SPEC-notch §3.2).
    var events: [NotchEventKind] = NotchEventKind.defaultOn
    /// «Только остров»: no system notification about a request or a wait while the island is on screen (SPEC-notch §4).
    var replaceNotifications = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NotchSettings()
        leftEar = (try? c.decodeIfPresent(NotchEar.self, forKey: .leftEar)) ?? defaults.leftEar
        rightEar = (try? c.decodeIfPresent(NotchEar.self, forKey: .rightEar)) ?? defaults.rightEar
        openOnHover = (try? c.decodeIfPresent(Bool.self, forKey: .openOnHover)) ?? defaults.openOnHover
        // Kinds from a newer version are skipped rather than dropping the whole list.
        events = (try? c.decodeIfPresent([String].self, forKey: .events))?.compactMap(NotchEventKind.init(rawValue:)) ?? defaults.events
        replaceNotifications = (try? c.decodeIfPresent(Bool.self, forKey: .replaceNotifications)) ?? defaults.replaceNotifications
    }
}

/// The island around the notch (docs/SPEC-notch.md): a borderless panel above the menu bar that never takes focus.
/// At rest it lets every click through to the menu bar; hovering over the notch (or a click) opens the card, moving
/// away closes it. Events come as banners, one at a time (§3.2); a permission request stays until it is answered
/// (§4). Nothing runs on a timer: the window is moved only when screens change, a banner's end is one sleep, the
/// pointer is watched only while the module is installed and the Mac has a notch.
@MainActor
@Observable
final class NotchIsland {
    private(set) var isOpen = false
    private(set) var geometry: NotchGeometry?
    private(set) var queue = NotchEventQueue()
    /// «Разрешить» / «Отклонить» are live (SPEC-notch §4).
    private(set) var armed = false
    /// The open card's and the banner's height under the notch, measured by the view.
    var cardHeight: CGFloat = NotchGeometry.cardHeight
    var bannerHeight: CGFloat = 44

    /// The banner on screen: the most important event, while the card is closed.
    var banner: NotchEvent? { isOpen ? nil : queue.current }
    /// Requests shown in the open card.
    var requests: [NotchEvent] { queue.items.filter { $0.kind == .request } }

    // Set by the app.
    /// Whether the module is installed.
    @ObservationIgnored var isActive: () -> Bool = { false }
    /// The open permission requests, as banners.
    @ObservationIgnored var openRequests: () -> [NotchEvent] = { [] }
    /// The sessions, to notice one that has finished.
    @ObservationIgnored var sessionItems: () -> [SessionStore.Item] = { [] }
    /// What a click on a banner or a button does: the same as on a notification.
    @ObservationIgnored var perform: (NotificationAction.Resolution) -> Void = { _ in }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var content: (() -> AnyView)?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var bannerTimer: Task<Void, Never>?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var clickGuard: NotchClickGuard?
    @ObservationIgnored private var shownBannerID: String?
    @ObservationIgnored private var pointerOnBanner = false
    @ObservationIgnored private var lastStates: [String: Session.State]?
    /// Requests answered here: their file stays until Claude's hook reads the answer, and must not come back meanwhile.
    @ObservationIgnored private var answered: Set<String> = []

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

    /// Re-runs `update` when the installed modules change, and follows requests and sessions.
    private func observe() {
        let (requests, items) = withObservationTracking {
            _ = isActive()
            return (openRequests(), sessionItems())
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update()
        guard geometry != nil else { return }
        answered.formIntersection(requests.map(\.id))
        queue.syncRequests(settings.notch.events.contains(.request) ? requests.filter { !answered.contains($0.id) } : [])
        noticeFinished(items)
        showNext()
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
        panel.ignoresMouseEvents = interactiveFrame?.contains(NSEvent.mouseLocation) != true
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
        bannerTimer?.cancel()
        isOpen = false
        queue = NotchEventQueue()
        lastStates = nil
        panel?.orderOut(nil)
        panel = nil
        if geometry != nil { AppLog.info("Notch island hidden") }
        geometry = nil
    }

    /// The island is on screen: not on a full-screen desktop, the display awake, the Mac unlocked.
    private var isVisible: Bool { panel?.occlusionState.contains(.visible) == true }

    // MARK: - Events (SPEC-notch §3.2)

    /// A notification that got through (`Notifier.island`). true = the island showed it and the person chose
    /// «только остров» for requests and waits, so no system notification.
    func notification(id: String, kind: NotificationKind, title: String, body: String, target: NotificationTarget) -> Bool {
        guard geometry != nil else { return false }
        let eventKind: NotchEventKind = if case .approval = target { .request } else { NotchEventKind(kind) }
        guard settings.notch.events.contains(eventKind) else { return false }
        // Requests come from the open request files, so they stay exactly as long as the request does.
        if eventKind != .request {
            queue.push(NotchEvent(id: id, kind: eventKind, title: title, body: body, target: target, arrived: .now))
            showNext()
        }
        return settings.notch.replaceNotifications && [.request, .waiting].contains(eventKind) && isVisible
    }

    /// A session that went from working to done gets a short banner (no system notification has this).
    private func noticeFinished(_ items: [SessionStore.Item]) {
        let states = Dictionary(items.map { ($0.id, $0.state) }) { first, _ in first }
        defer { lastStates = states }
        guard let lastStates, settings.notch.events.contains(.done) else { return }
        for item in items where item.state == .done && [.running, .waiting].contains(lastStates[item.id]) {
            let duration = item.session.startedAt.map { DurationText.short(from: $0, to: item.session.updatedAt) }
            queue.push(NotchEvent(
                id: "done-\(item.id)", kind: .done,
                title: String(localized: "Готово: \(item.session.displayProject)"),
                body: duration ?? "", target: .session(id: item.id), arrived: .now
            ))
        }
    }

    /// Starts the current banner's time, re-arms the guard for a new banner and sleeps until it runs out.
    private func showNext() {
        guard !isOpen else { return }
        queue.tick(now: .now, paused: pointerOnBanner)
        if let banner, banner.id != shownBannerID {
            shownBannerID = banner.id
            resetGuard()
        } else if banner == nil {
            shownBannerID = nil
        }
        panel?.ignoresMouseEvents = interactiveFrame?.contains(NSEvent.mouseLocation) != true
        bannerTimer?.cancel()
        guard let deadline = queue.deadline else { return }
        bannerTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0.05)))
            guard !Task.isCancelled else { return }
            self?.showNext()
        }
    }

    func answer(_ event: NotchEvent, allow: Bool) {
        guard armed, case let .approval(_, requestID) = event.target else { return }
        AppLog.info("Permission \(allow ? "allowed" : "denied") from the notch island")
        perform(.decide(requestID: requestID, allow: allow))
        answered.insert(event.id)
        queue.remove(event.id)
        showNext()
    }

    /// «Открыть», or a click on the banner: where the notification would lead.
    func openTarget(of event: NotchEvent) {
        perform(NotificationAction.resolve(event.target, action: NotificationAction.show))
        if event.kind != .request { queue.remove(event.id) }
        close()
        showNext()
    }

    private func resetGuard() {
        clickGuard = NotchClickGuard(shownAt: .now, pointer: NSEvent.mouseLocation)
        armed = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchClickGuard.delay))
            self?.updateArmed()
        }
    }

    private func updateArmed() {
        let now = clickGuard?.isArmed(now: .now) ?? false
        if now != armed { armed = now }
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

    /// The black part of the window under the notch, in screen coordinates.
    private func frame(height: CGFloat) -> CGRect? {
        guard let geometry else { return nil }
        let window = geometry.windowFrame
        let height = min(geometry.notch.height + height, window.height)
        return CGRect(x: window.minX, y: window.maxY - height, width: window.width, height: height)
    }

    private var cardFrame: CGRect? { frame(height: cardHeight) }
    private var bannerFrame: CGRect? { banner == nil ? nil : frame(height: bannerHeight) }

    /// Where the window takes clicks; everywhere else they go through to what is underneath.
    private var interactiveFrame: CGRect? { isOpen ? cardFrame : bannerFrame }

    private func pointer(_ type: NSEvent.EventType) {
        guard let geometry else { return }
        let location = NSEvent.mouseLocation
        clickGuard?.pointer(at: location)
        updateArmed()
        panel?.ignoresMouseEvents = interactiveFrame?.contains(location) != true

        if isOpen {
            let inside = cardFrame?.contains(location) ?? false
            if inside {
                pending?.cancel()
            } else if type == .leftMouseDown {
                close()
            } else if !isPending {
                schedule(after: Self.closeDelay) { [weak self] in self?.close() }
            }
        } else if let bannerFrame {
            // A banner: the pointer on it keeps it; leaving gives it its full time again.
            let onBanner = bannerFrame.contains(location)
            if onBanner != pointerOnBanner {
                pointerOnBanner = onBanner
                showNext()
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
        pointerOnBanner = false
        resetGuard()
        panel?.ignoresMouseEvents = false
    }

    func close() {
        pending?.cancel()
        guard isOpen else { return }
        isOpen = false
        shownBannerID = nil
        showNext()
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
