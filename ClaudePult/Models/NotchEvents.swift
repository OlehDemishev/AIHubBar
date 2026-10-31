import CoreGraphics
import Foundation

/// What the island can announce (docs/SPEC-notch.md §3.2), most important first: the order is the queue's priority.
enum NotchEventKind: String, Codable, CaseIterable, Sendable {
    case request, waiting, done, background, limits, context, pullRequests, calendar, resources, commands

    var title: String {
        switch self {
        case .request: String(localized: "Запросы разрешений")
        case .waiting: String(localized: "Claude ждёт ответа")
        case .done: String(localized: "Сессия закончила")
        case .background: NotificationKind.background.title
        case .limits: NotificationKind.limits.title
        case .context: NotificationKind.context.title
        case .pullRequests: NotificationKind.pullRequests.title
        case .calendar: NotificationKind.calendar.title
        case .resources: NotificationKind.resources.title
        case .commands: NotificationKind.commands.title
        }
    }

    var symbol: String {
        switch self {
        case .request: "hand.raised.fill"
        case .waiting: "bubble.left.fill"
        case .done: "checkmark.circle.fill"
        case .background: "gearshape.2.fill"
        case .limits: "gauge.with.dots.needle.67percent"
        case .context: "text.alignleft"
        case .pullRequests: "arrow.triangle.pull"
        case .calendar: "calendar"
        case .resources: "cpu"
        case .commands: "terminal"
        }
    }

    /// How long a banner stays; a request stays until it is answered or Claude cancels it.
    var duration: TimeInterval? {
        switch self {
        case .request: nil
        case .waiting: 6
        default: 4
        }
    }

    /// The ones in the spec's table are on by default; calendar, resources and commands are there to switch on.
    static let defaultOn: [NotchEventKind] = [.request, .waiting, .done, .background, .limits, .context, .pullRequests]

    init(_ kind: NotificationKind) {
        switch kind {
        case .waiting: self = .waiting
        case .context: self = .context
        case .background: self = .background
        case .limits: self = .limits
        case .pullRequests: self = .pullRequests
        case .calendar: self = .calendar
        case .resources: self = .resources
        case .commands: self = .commands
        }
    }
}

/// One banner in the island.
struct NotchEvent: Equatable, Identifiable, Sendable {
    /// The same id replaces an older banner (a notification's id; `request-<id>` for a request).
    var id: String
    var kind: NotchEventKind
    var title: String
    var body: String
    /// Where «Открыть» (or a click on the banner) leads; a request's target carries its id for the buttons.
    var target: NotificationTarget
    var arrived: Date

    static func request(_ request: ApprovalRequest, project: String, now: Date = .now) -> NotchEvent {
        NotchEvent(id: "request-\(request.id)", kind: .request, title: "\(project) · \(request.tool)", body: request.summary,
                   target: .approval(sessionID: request.sessionID, requestID: request.id), arrived: now)
    }
}

/// The banners waiting to be shown (SPEC-notch §3.2): one at a time, the most important first, a request ahead of
/// everything. A banner's time starts when it is first shown; while the pointer rests on it, it does not run out.
struct NotchEventQueue: Equatable, Sendable {
    private(set) var items: [NotchEvent] = []
    private var shownAt: [String: Date] = [:]

    /// More than this and the least important, oldest banners are dropped.
    static let limit = 10

    var current: NotchEvent? {
        items.min { a, b in
            let pa = NotchEventKind.allCases.firstIndex(of: a.kind)!, pb = NotchEventKind.allCases.firstIndex(of: b.kind)!
            return pa != pb ? pa < pb : a.arrived < b.arrived
        }
    }

    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ event: NotchEvent) {
        if let index = items.firstIndex(where: { $0.id == event.id }) {
            items[index] = event
            shownAt[event.id] = nil
        } else {
            items.append(event)
        }
        while items.count > Self.limit, let drop = items.min(by: lessImportant) {
            remove(drop.id)
        }
    }

    /// The open requests right now: new ones come in, answered or cancelled ones go.
    mutating func syncRequests(_ requests: [NotchEvent]) {
        let ids = Set(requests.map(\.id))
        for item in items where item.kind == .request && !ids.contains(item.id) { remove(item.id) }
        for request in requests where !items.contains(where: { $0.id == request.id }) { push(request) }
    }

    mutating func remove(_ id: String) {
        items.removeAll { $0.id == id }
        shownAt[id] = nil
    }

    /// Marks the current banner as shown (its time starts now) and drops it once its time is up.
    /// `paused`: the pointer is on the banner, so it stays and gets its full time again afterwards.
    mutating func tick(now: Date, paused: Bool) {
        while let current {
            guard let duration = current.kind.duration else { return }
            guard let shown = shownAt[current.id], !paused else {
                shownAt[current.id] = now
                return
            }
            guard now.timeIntervalSince(shown) >= duration else { return }
            remove(current.id)
        }
    }

    /// When the current banner runs out, if it does.
    var deadline: Date? {
        guard let current, let duration = current.kind.duration, let shown = shownAt[current.id] else { return nil }
        return shown.addingTimeInterval(duration)
    }

    /// `a` goes before `b` when banners have to be dropped: a less important kind, or the older of the same kind.
    private func lessImportant(_ a: NotchEvent, than b: NotchEvent) -> Bool {
        let pa = NotchEventKind.allCases.firstIndex(of: a.kind)!, pb = NotchEventKind.allCases.firstIndex(of: b.kind)!
        return pa != pb ? pa > pb : a.arrived < b.arrived
    }
}

/// «Разрешить» and «Отклонить» wake up only a moment after the island appears, and only once the pointer has moved:
/// the island opens where the pointer often already is, and a click meant for the menu bar must not answer Claude
/// (SPEC-notch §4).
struct NotchClickGuard: Equatable, Sendable {
    static let delay: TimeInterval = 0.6
    static let minimumMove: CGFloat = 3

    var shownAt: Date
    var origin: CGPoint
    private(set) var moved = false

    init(shownAt: Date, pointer: CGPoint) {
        self.shownAt = shownAt
        origin = pointer
    }

    mutating func pointer(at location: CGPoint) {
        if hypot(location.x - origin.x, location.y - origin.y) >= Self.minimumMove { moved = true }
    }

    func isArmed(now: Date) -> Bool {
        moved && now.timeIntervalSince(shownAt) >= Self.delay
    }
}
