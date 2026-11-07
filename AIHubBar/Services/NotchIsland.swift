import AppKit
import Observation
import SwiftUI

/// The island around the notch (docs/specs/SPEC-notch.md): a borderless panel above the menu bar that never takes focus,
/// one per screen with «на всех экранах» (the same events on each; the card opens on the one being hovered).
/// At rest it lets every click through to the menu bar; hovering over the notch (or a click) opens the card, moving
/// away closes it. Events come as banners, one at a time (§3.2); a permission request stays until it is answered
/// (§4). Nothing runs on a timer: the window is moved only when screens change, a banner's end is one sleep, the
/// pointer is watched only while the module is installed and the Mac has a notch.
@MainActor
@Observable
final class NotchIsland {
    /// The screens the island is on; empty — nowhere.
    private(set) var places: [NotchPlace] = []
    /// The place whose card is open.
    private(set) var openIndex: Int?
    /// A file is being dragged over this place's drop zone (SPEC-notch §9, stage 5).
    private(set) var dropTarget: Int?
    /// The file or folder dropped on the island; the open card offers the profile's AI commands for it.
    private(set) var dropped: URL?
    private(set) var queue = NotchEventQueue()
    /// «Разрешить» / «Отклонить» are live (SPEC-notch §4).
    private(set) var armed = false
    /// The open card's and the banner's height under the notch, measured by the view.
    var cardHeight: CGFloat = NotchGeometry.cardHeight
    var bannerHeight: CGFloat = 44

    var isOpen: Bool { openIndex != nil }
    /// A full-screen app fills every screen the island is on: only requests and waits come in (SPEC-notch §5).
    var isFullScreen: Bool { !places.isEmpty && places.allSatisfy(\.isFullScreen) }

    /// The banner on screen: the most important event, while the card is closed.
    var banner: NotchEvent? { isOpen ? nil : queue.current }

    /// The banner on one screen: over a full-screen app only a request or a wait.
    func banner(on index: Int) -> NotchEvent? {
        guard let banner, places.indices.contains(index) else { return nil }
        return !places[index].isFullScreen || [.request, .waiting].contains(banner.kind) ? banner : nil
    }
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
    /// Opens the first-setup window (SPEC-notch §6.1); called once while it hasn't been answered. The app sets it
    /// while it is still being made (no `NSApp`, no menu bar item to open windows from yet), so the first check runs
    /// a few seconds later.
    @ObservationIgnored var needsSetup: (() -> Void)? {
        didSet {
            guard needsSetup != nil else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.update()
            }
        }
    }
    @ObservationIgnored private var askedForSetup = false
    @ObservationIgnored private var spaceObservers: [NSObjectProtocol] = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var panels: [NotchPanel] = []
    @ObservationIgnored private var content: ((Int) -> AnyView)?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var bannerTimer: Task<Void, Never>?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var clickGuard: NotchClickGuard?
    @ObservationIgnored private var shownBannerID: String?
    @ObservationIgnored private var pointerOnBanner = false
    @ObservationIgnored private var lastStates: [String: Session.State]?
    /// The drag pasteboard's count at the last mouse down: a new count while dragging means a real drag.
    @ObservationIgnored private var dragCount = NSPasteboard(name: .drag).changeCount
    @ObservationIgnored private var fileDragging = false
    /// Requests answered here: their file stays until Claude's hook reads the answer, and must not come back meanwhile.
    @ObservationIgnored private var answered: Set<String> = []

    /// How far under the notch a dragged file is caught.
    static let dropHeight: CGFloat = 56
    /// How far around the drop zone the window already takes a file drag, so a quick release at the edge still lands:
    /// macOS only sends a drag to a window that took the mouse before the pointer arrived.
    static let dragMargin: CGFloat = 40

    /// How long the pointer rests on the notch before the card opens, and how long it may stray before it closes.
    static let openDelay: Duration = .milliseconds(300)
    static let closeDelay: Duration = .milliseconds(400)

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// `content` makes the view for the island on `places[index]`.
    func start(content: @escaping (_ index: Int) -> AnyView) {
        self.content = content
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // A full-screen app starts or ends with a space change or another app coming forward.
        let workspace = NSWorkspace.shared.notificationCenter
        spaceObservers = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification].map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        observe()
    }

    /// Re-runs `update` when the installed modules change, and follows requests and sessions.
    private func observe() {
        let (requests, items) = withObservationTracking {
            _ = isActive()
            _ = settings.notch
            return (openRequests(), sessionItems())
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update()
        guard !places.isEmpty else { return }
        answered.formIntersection(requests.map(\.id))
        let changed = queue.syncRequests(settings.notch.events.contains(.request) ? requests.filter { !answered.contains($0.id) } : [])
        // The rows of the open card moved: the buttons wait, or a click meant for a row would land on «Разрешить».
        if changed, isOpen { resetGuard() }
        noticeFinished(items)
        showNext()
    }

    func update() {
        let geometries = isActive() && !settings.notch.hidden ? NotchGeometry.places(for: settings.notch) : []
        guard !geometries.isEmpty else {
            tearDown()
            return
        }
        let new = geometries.map { NotchPlace(geometry: $0, isFullScreen: FullScreenDetector.isFullScreen(screen: $0.screen)) }
        if new.map(\.geometry) != places.map(\.geometry) {
            AppLog.info("Notch island at \(geometries.map { NSStringFromRect($0.notch) }.joined(separator: ", "))")
        }
        if new.map(\.isFullScreen) != places.map(\.isFullScreen), !places.isEmpty || new.contains(where: \.isFullScreen) {
            let count = new.filter(\.isFullScreen).count
            AppLog.info("Notch island: full-screen apps on \(count) of \(new.count) screens")
        }
        let wasFullScreen = isFullScreen
        if new != places { places = new }
        if isFullScreen, !wasFullScreen { queue.keepOnly([.request, .waiting]) }
        if let openIndex, !places.indices.contains(openIndex) { self.openIndex = nil }
        if !settings.notch.setupDone, !askedForSetup, let needsSetup {
            askedForSetup = true
            AppLog.info("Notch island: asking for the first setup")
            needsSetup()
        }
        while panels.count < places.count { panels.append(makePanel(index: panels.count)) }
        while panels.count > places.count { panels.removeLast().orderOut(nil) }
        for (index, panel) in panels.enumerated() {
            panel.setFrame(places[index].geometry.windowFrame, display: true)
            panel.orderFrontRegardless()
        }
        updateMouse(at: NSEvent.mouseLocation)
        if monitors.isEmpty { watchPointer() }
    }

    private func makePanel(index: Int) -> NotchPanel {
        let panel = NotchPanel()
        if let content {
            let host = NotchHostingView(rootView: content(index))
            host.sizingOptions = []
            host.onDrop = { [weak self] urls in self?.drop(urls, on: index) ?? false }
            host.onDragOver = { [weak self] point in self?.dragOver(point, on: index) ?? false }
            panel.contentView = host
        }
        return panel
    }

    private func tearDown() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        pending?.cancel()
        bannerTimer?.cancel()
        openIndex = nil
        dropTarget = nil
        dropped = nil
        queue = NotchEventQueue()
        lastStates = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
        if !places.isEmpty { AppLog.info("Notch island hidden") }
        places = []
    }

    /// The island is on screen: not on a full-screen desktop, the display awake, the Mac unlocked.
    private var isVisible: Bool { panels.contains { $0.occlusionState.contains(.visible) } }

    /// The ears on one screen show the summary: a real notch (the pill has no ears), no full-screen app there,
    /// not «только в строке меню».
    func showsSummary(on index: Int) -> Bool {
        places.indices.contains(index) && !places[index].geometry.isPill && !places[index].isFullScreen && settings.notch.summary != .menuBar
    }

    /// «Только в острове»: the menu bar keeps only its icon while some ears show the summary.
    var takesMenuBarSummary: Bool { settings.notch.summary == .island && places.indices.contains { showsSummary(on: $0) } }

    // MARK: - Events (SPEC-notch §3.2)

    /// A notification that got through (`Notifier.island`). true = the island showed it and the person chose
    /// «только остров» for requests and waits, so no system notification.
    func notification(id: String, kind: NotificationKind, title: String, body: String, target: NotificationTarget) -> Bool {
        guard !places.isEmpty else { return false }
        let eventKind: NotchEventKind = if case .approval = target { .request } else { NotchEventKind(kind) }
        guard settings.notch.events.contains(eventKind), !isFullScreen || [.request, .waiting].contains(eventKind) else { return false }
        // Requests come from the open request files, so they stay exactly as long as the request does.
        if eventKind != .request {
            queue.push(NotchEvent(id: id, kind: eventKind, title: title, body: body, target: target, arrived: .now))
            showNext()
        }
        return settings.notch.replaceNotifications && [.request, .waiting].contains(eventKind) && isVisible
    }

    /// A session that went from working to done gets a short banner (no system notification has this). With the
    /// live activity on it says how far the task list got, how long the answer took and how many files changed.
    private func noticeFinished(_ items: [SessionStore.Item]) {
        let states = Dictionary(items.map { ($0.id, $0.state) }) { first, _ in first }
        defer { lastStates = states }
        guard let lastStates, settings.notch.events.contains(.done), !isFullScreen else { return }
        for item in items where item.state == .done && [.running, .waiting].contains(lastStates[item.id]) {
            let session = item.session
            let event = { (body: String) in
                NotchEvent(id: "done-\(item.id)", kind: .done, title: String(localized: "Готово: \(session.displayProject)"),
                           body: body, target: .session(id: item.id), arrived: .now)
            }
            guard settings.notch.liveActivity else {
                queue.push(event(session.startedAt.map { DurationText.short(from: $0, to: session.updatedAt) } ?? ""))
                continue
            }
            let duration = (session.promptAt ?? session.startedAt).map { DurationText.short(from: $0, to: session.updatedAt) }
            // The files come from git; the banner waits for them (a second at most, usually).
            Task { @MainActor [weak self] in
                let changes = session.cwd.isEmpty ? nil : await SessionChangesStore.read(folder: session.cwd, since: session.startedAt)
                guard let self, !self.places.isEmpty else { return }
                self.queue.push(event(NotchText.finishedBody(progress: session.progress, duration: duration, files: changes?.files.count)))
                self.showNext()
            }
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
        updateMouse(at: NSEvent.mouseLocation)
        bannerTimer?.cancel()
        guard let deadline = queue.deadline else { return }
        bannerTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0.05)))
            guard !Task.isCancelled else { return }
            self?.showNext()
        }
    }

    func answer(_ event: NotchEvent, allow: Bool) {
        guard armed else { return }
        decide(event, allow: allow, how: "the notch island")
    }

    /// ⌃⌥Y / ⌃⌥N: the request on screen — the banner, or the first one in the open card — once it has been shown
    /// long enough to read.
    func answerByKey(allow: Bool) {
        guard settings.notch.hotKeys, clickGuard?.keysArmed(now: .now) == true,
              let event = isOpen ? requests.first : banner.flatMap({ $0.kind == .request ? $0 : nil }) else { return }
        decide(event, allow: allow, how: allow ? "⌃⌥Y" : "⌃⌥N")
    }

    private func decide(_ event: NotchEvent, allow: Bool, how: String) {
        guard case let .approval(_, requestID) = event.target else { return }
        AppLog.info("Permission \(allow ? "allowed" : "denied") from \(how)")
        perform(.decide(requestID: requestID, allow: allow))
        answered.insert(event.id)
        queue.remove(event.id)
        // The next request slides up under the pointer: a second click must not answer it unread.
        if isOpen { resetGuard() }
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

    // MARK: - A dropped file (SPEC-notch §9, stage 5)

    /// Where a dragged file is caught: the notch and a strip under it, as wide as the card.
    private func dropZone(on index: Int) -> CGRect? { frame(on: index, height: Self.dropHeight) }

    /// While a mouse button is down, a file drag (a new drag pasteboard holding files) near the notch makes the
    /// island a drop target. true = a file drag is going on, so the pointer means nothing else.
    private func trackDrag(_ type: NSEvent.EventType, at location: CGPoint) -> Bool {
        if type == .leftMouseDown { dragCount = NSPasteboard(name: .drag).changeCount }
        let board = NSPasteboard(name: .drag)
        let dragging = settings.notch.fileDrop && type == .leftMouseDragged && board.changeCount != dragCount
            && board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        fileDragging = dragging
        setDropTarget(dragging ? places.indices.first { dropZone(on: $0)?.contains(location) == true } : nil)
        return dragging
    }

    private func setDropTarget(_ target: Int?) {
        guard target != dropTarget else { return }
        dropTarget = target
        if target != nil { pending?.cancel() }
    }

    /// A drag over one screen's window (`point` in screen coordinates, nil when it left): whether it is over the drop
    /// zone and may be dropped. Lights the island up as the global monitor does.
    func dragOver(_ point: CGPoint?, on index: Int) -> Bool {
        let inside = settings.notch.fileDrop && point.map { dropZone(on: index)?.contains($0) == true } == true
        if inside { setDropTarget(index) } else if dropTarget == index { setDropTarget(nil) }
        return inside
    }

    /// A file or folder let go over the island: its card opens with the profile's AI commands.
    func drop(_ urls: [URL], on index: Int) -> Bool {
        guard settings.notch.fileDrop, let url = urls.first(where: \.isFileURL), places.indices.contains(index) else { return false }
        AppLog.info("Notch island: «\(url.lastPathComponent)» dropped\(urls.count > 1 ? " (first of \(urls.count))" : "")")
        dropTarget = nil
        if openIndex != nil, openIndex != index { openIndex = nil }
        dropped = url
        if openIndex == nil { open(on: index) }
        // Typing a task needs the keyboard; the panel takes it without bringing the app forward.
        panels[index].makeKey()
        return true
    }

    /// A command was started on the dropped file: the card closes and a banner says so.
    func started(_ title: String, file: String) {
        let event = NotchEvent(id: "started-\(UUID().uuidString)", kind: .commands, title: String(localized: "Запущено: \(title)"),
                               body: file, target: .none, arrived: .now)
        close()
        queue.push(event)
        showNext()
    }

    // MARK: - Pointer

    private func watchPointer() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
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

    /// The black part of one screen's window under the notch, in screen coordinates.
    private func frame(on index: Int, height: CGFloat) -> CGRect? {
        guard places.indices.contains(index) else { return nil }
        let geometry = places[index].geometry
        let window = geometry.windowFrame
        let height = min(geometry.notch.height + height, window.height)
        return CGRect(x: window.minX, y: window.maxY - height, width: window.width, height: height)
    }

    private func bannerFrame(on index: Int) -> CGRect? { banner(on: index) == nil ? nil : frame(on: index, height: bannerHeight) }

    /// Where one screen's window takes clicks; everywhere else they go through to what is underneath.
    private func interactiveFrame(on index: Int) -> CGRect? {
        if fileDragging || dropTarget == index { return dropZone(on: index)?.insetBy(dx: -Self.dragMargin, dy: -Self.dragMargin) }
        guard let openIndex else { return bannerFrame(on: index) }
        return openIndex == index ? frame(on: index, height: cardHeight) : nil
    }

    private func updateMouse(at location: CGPoint) {
        for (index, panel) in panels.enumerated() {
            panel.ignoresMouseEvents = interactiveFrame(on: index)?.contains(location) != true
        }
    }

    private func pointer(_ type: NSEvent.EventType) {
        guard !places.isEmpty else { return }
        let location = NSEvent.mouseLocation
        let dragging = trackDrag(type, at: location)
        clickGuard?.pointer(at: location)
        updateArmed()
        updateMouse(at: location)
        guard !dragging, type != .leftMouseUp else { return }

        if let openIndex {
            let inside = frame(on: openIndex, height: cardHeight)?.contains(location) ?? false
            if inside {
                pending?.cancel()
            } else if type == .leftMouseDown {
                close()
            } else if !isPending, dropped == nil {
                // A dropped file's commands stay until chosen, Esc or a click elsewhere.
                schedule(after: Self.closeDelay) { [weak self] in self?.close() }
            }
        } else if banner != nil {
            // A banner: the pointer on it keeps it; leaving gives it its full time again.
            let onBanner = places.indices.contains { bannerFrame(on: $0)?.contains(location) == true }
            if onBanner != pointerOnBanner {
                pointerOnBanner = onBanner
                showNext()
            }
        } else if let index = places.firstIndex(where: { $0.geometry.restFrame.contains(location) }) {
            if type == .leftMouseDown {
                open(on: index)
            } else if settings.notch.openOnHover, !isPending {
                schedule(after: Self.openDelay) { [weak self] in
                    guard let self, self.places.indices.contains(index),
                          self.places[index].geometry.restFrame.contains(NSEvent.mouseLocation) else { return }
                    self.open(on: index)
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

    func open(on index: Int) {
        pending?.cancel()
        guard !isOpen, places.indices.contains(index) else { return }
        openIndex = index
        pointerOnBanner = false
        resetGuard()
        updateMouse(at: NSEvent.mouseLocation)
        if panels.indices.contains(index) { panels[index].ignoresMouseEvents = false }
    }

    func close() {
        pending?.cancel()
        dropped = nil
        guard isOpen else { return }
        openIndex = nil
        shownBannerID = nil
        showNext()
    }
}
