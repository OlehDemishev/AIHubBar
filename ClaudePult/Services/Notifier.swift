import AppKit
import Foundation
import Observation
import UserNotifications

/// What a notification is about, so a click can lead there. Stored in the notification's `userInfo`.
enum NotificationTarget: Equatable, Sendable {
    /// A Claude Code session waiting for an answer → bring its Terminal tab (or app / folder) forward.
    case session(id: String)
    /// A finished background run → its pull request if there is one, else its log.
    case run(id: String, pullRequest: String?)
    /// A file to open (the latest report).
    case file(path: String)
    /// One of ClaudePult's windows (the cleanup output).
    case window(id: String)
    /// A web page (a pull request).
    case link(URL)
    /// A permission Claude asked for: «Разрешить» / «Отклонить» right on the banner.
    case approval(sessionID: String, requestID: String)
    case none

    var userInfo: [String: String] {
        switch self {
        case let .session(id): ["target": "session", "id": id]
        case let .run(id, pullRequest): ["target": "run", "id": id, "pr": pullRequest ?? ""]
        case let .file(path): ["target": "file", "path": path]
        case let .window(id): ["target": "window", "id": id]
        case let .approval(sessionID, requestID): ["target": "approval", "id": sessionID, "request": requestID]
        case let .link(url): ["target": "link", "url": url.absoluteString]
        case .none: [:]
        }
    }

    init(userInfo: [AnyHashable: Any]) {
        let value = { (key: String) in userInfo[key] as? String ?? "" }
        switch value("target") {
        case "session" where !value("id").isEmpty: self = .session(id: value("id"))
        case "run" where !value("id").isEmpty: self = .run(id: value("id"), pullRequest: value("pr").isEmpty ? nil : value("pr"))
        case "file" where !value("path").isEmpty: self = .file(path: value("path"))
        case "window" where !value("id").isEmpty: self = .window(id: value("id"))
        case "link" where URL(string: value("url"))?.scheme == "https": self = .link(URL(string: value("url"))!)
        case "approval" where !value("id").isEmpty && !value("request").isEmpty:
            self = .approval(sessionID: value("id"), requestID: value("request"))
        default: self = .none
        }
    }

    /// Notification category: which action buttons the banner gets.
    var category: String? {
        switch self {
        case .session: NotificationAction.sessionCategory
        case .approval: NotificationAction.approvalCategory
        case let .run(_, pullRequest): pullRequest == nil ? NotificationAction.runCategory : NotificationAction.runWithPRCategory
        case .file, .window, .link, .none: nil
        }
    }
}

/// Buttons on notifications and what a click (or a button) does.
enum NotificationAction {
    static let show = "show"
    static let openPR = "open-pr"
    static let log = "log"
    static let allow = "allow"
    static let deny = "deny"
    static let approvalCategory = "approval"

    static let sessionCategory = "session"
    static let runCategory = "run"
    static let runWithPRCategory = "run-pr"

    enum Resolution: Equatable {
        case showSession(id: String)
        case decide(requestID: String, allow: Bool)
        case openURL(URL)
        case openRunLog(id: String)
        case openFile(path: String)
        case openWindow(id: String)
        case nothing
    }

    /// `action` is the button identifier, or `UNNotificationDefaultActionIdentifier` for a click on the banner.
    static func resolve(_ target: NotificationTarget, action: String) -> Resolution {
        switch target {
        case let .session(id):
            return .showSession(id: id)
        case let .run(id, pullRequest):
            if action == log { return .openRunLog(id: id) }
            if let pullRequest, let url = URL(string: pullRequest), url.scheme == "https" { return .openURL(url) }
            return .openRunLog(id: id)
        case let .file(path):
            return .openFile(path: path)
        case let .window(id):
            return .openWindow(id: id)
        case let .link(url):
            return .openURL(url)
        case let .approval(sessionID, requestID):
            if action == allow { return .decide(requestID: requestID, allow: true) }
            if action == deny { return .decide(requestID: requestID, allow: false) }
            return .showSession(id: sessionID)
        case .none:
            return .nothing
        }
    }

    static var categories: Set<UNNotificationCategory> {
        let show = UNNotificationAction(identifier: show, title: String(localized: "Показать"), options: [.foreground])
        let pr = UNNotificationAction(identifier: openPR, title: String(localized: "Открыть PR"), options: [.foreground])
        let log = UNNotificationAction(identifier: log, title: String(localized: "Журнал"), options: [.foreground])
        // No `.foreground`: the answer goes to Claude without bringing anything to the front.
        let allow = UNNotificationAction(identifier: allow, title: String(localized: "Разрешить"), options: [])
        let deny = UNNotificationAction(identifier: deny, title: String(localized: "Отклонить"), options: [.destructive])
        return [
            UNNotificationCategory(identifier: approvalCategory, actions: [allow, deny, show], intentIdentifiers: []),
            UNNotificationCategory(identifier: sessionCategory, actions: [show], intentIdentifiers: []),
            UNNotificationCategory(identifier: runCategory, actions: [log], intentIdentifiers: []),
            UNNotificationCategory(identifier: runWithPRCategory, actions: [pr, log], intentIdentifiers: []),
        ]
    }
}

/// Whether macOS lets ClaudePult show notifications; shown in the panel and Settings when it does not.
@MainActor
@Observable
final class NotificationPermission {
    enum State: Equatable {
        case unknown, allowed, denied, notAsked
    }

    private(set) var state: State = .unknown

    func refresh() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional: state = .allowed
            case .denied: state = .denied
            case .notDetermined: state = .notAsked
            @unknown default: state = .unknown
            }
        }
    }

    /// Asks macOS (shows the system prompt only if it was never answered), then re-reads the state.
    func request() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            refresh()
        }
    }

    /// System Settings → Notifications → ClaudePult.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.demishev.claudepult"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// macOS notifications. The permission is checked before every notification (not cached), so turning
/// notifications on in System Settings takes effect without restarting ClaudePult.
@MainActor
enum Notifier {
    /// «Проверить» in Settings: a notification whose click opens the help window.
    static func postTest() {
        post(id: "test", title: String(localized: "AI Hub Bar: уведомления работают"),
             body: String(localized: "Кликните — откроется окно «Помощь»."), target: .window(id: "help"))
    }

    /// The person's choice per kind (Settings); set by the app at launch.
    static var frequency: (NotificationKind) -> NotificationFrequency = { $0.defaultFrequency }

    /// «Остров у чёлки» sees every notification that gets through (SPEC-notch §3.2); true = the island showed it
    /// instead, so no system notification (only when the person chose that, SPEC-notch §4).
    static var island: ((_ id: String, _ kind: NotificationKind, _ title: String, _ body: String, _ target: NotificationTarget) -> Bool)?

    static func post(id: String, title: String, body: String, target: NotificationTarget = .none) {
        if let kind = NotificationKind(id: id) {
            let throttle = NotificationThrottle()
            guard throttle.allows(id: id, frequency: frequency(kind)) else {
                AppLog.info("Notification «\(title)» skipped (\(kind.rawValue): \(frequency(kind).rawValue))")
                return
            }
            throttle.record(id: id)
            if island?(id, kind, title, body, target) == true {
                AppLog.info("Notification «\(title)» shown in the notch island only")
                return
            }
        }
        AppLog.info("Notification: \(title)")
        Task {
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    let nsError = error as NSError
                    AppLog.error("Notification authorization failed: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
                }
                status = await center.notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional else {
                AppLog.error("Notification «\(title)» not shown: notifications are not allowed for AI Hub Bar")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = target.userInfo
            if let category = target.category { content.categoryIdentifier = category }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

/// Receives clicks on ClaudePult's notifications and hands them to the app.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()

    /// Set once at launch on the main actor; called on the main actor.
    @MainActor private var handler: ((NotificationAction.Resolution) -> Void)?

    @MainActor
    func install(_ handler: @escaping (NotificationAction.Resolution) -> Void) {
        self.handler = handler
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationAction.categories)
    }

    /// Show banners even while ClaudePult is the active app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let target = NotificationTarget(userInfo: response.notification.request.content.userInfo)
        let resolution = NotificationAction.resolve(target, action: response.actionIdentifier)
        await MainActor.run {
            AppLog.info("Notification click: \(resolution)")
            handler?(resolution)
        }
    }
}

/// Kinds of notifications, for Settings → Основные → «Какие уведомления и как часто».
enum NotificationKind: String, CaseIterable, Identifiable, Sendable {
    case waiting, context, background, limits, pullRequests, calendar, resources, commands

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waiting: String(localized: "Claude ждёт ответа или разрешения")
        case .context: String(localized: "Контекст сессии почти заполнен")
        case .background: String(localized: "Фоновые задачи: итог, пауза, ночная сводка")
        case .limits: String(localized: "Лимиты: Claude, другие AI, бюджет API")
        case .pullRequests: String(localized: "PR и CI")
        case .calendar: String(localized: "Календарь: дедлайны и публикации")
        case .resources: String(localized: "Ресурсы Mac: процессор, память, диск, батарея")
        case .commands: String(localized: "Команды: отчёты, проверки, быстрые команды")
        }
    }

    var defaultFrequency: NotificationFrequency { self == .resources ? .hourly : .always }

    /// Every notification id starts with its kind's prefix (see the `Notifier.post` calls).
    init?(id: String) {
        let prefixes: [(String, NotificationKind)] = [
            ("waiting-", .waiting), ("context-", .context), ("run-", .background), ("night-summary", .background),
            ("limit-", .limits), ("week-forecast", .limits), ("hub-", .limits), ("spendWarned-", .limits),
            ("pr-", .pullRequests), ("calendar-", .calendar), ("resources-", .resources),
            ("command-", .commands), ("quick-", .commands),
        ]
        guard let kind = prefixes.first(where: { id.hasPrefix($0.0) })?.1 else { return nil }
        self = kind
    }
}

/// How often the same notification (same id: the same session, threshold, PR…) may come again.
enum NotificationFrequency: String, CaseIterable, Identifiable, Sendable {
    case always, quarterHour, hourly, daily, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: String(localized: "каждый раз")
        case .quarterHour: String(localized: "не чаще раза в 15 мин")
        case .hourly: String(localized: "не чаще раза в час")
        case .daily: String(localized: "не чаще раза в день")
        case .off: String(localized: "не присылать")
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .always: 0
        case .quarterHour: 15 * 60
        case .hourly: 3600
        case .daily: 86_400
        case .off: nil
        }
    }
}

/// When each notification id was last shown; kept two days so a restart doesn't repeat what was just said.
struct NotificationThrottle {
    static let key = "notificationLastShown"
    var defaults: UserDefaults = .standard

    func allows(id: String, frequency: NotificationFrequency, now: Date = .now) -> Bool {
        guard let interval = frequency.interval else { return false }
        guard interval > 0, let last = (defaults.dictionary(forKey: Self.key) as? [String: Double])?[id] else { return true }
        return now.timeIntervalSince1970 - last >= interval
    }

    func record(id: String, now: Date = .now) {
        var shown = (defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:])
            .filter { now.timeIntervalSince1970 - $0.value < 2 * 86_400 }
        shown[id] = now.timeIntervalSince1970
        defaults.set(shown, forKey: Self.key)
    }
}
