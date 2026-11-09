import Foundation

// The «Telegram» bot's decisions (docs/specs/SPEC-telegram.md): what came in, what a button means, what each screen
// says. Pure, so the tests can read them without a bot; `TelegramBotController` does the talking.

/// The module's settings of this Mac (SPEC-telegram §6); not in the settings export, so each Mac keeps its own.
struct TelegramBotSettings: Codable, Equatable, Sendable {
    /// «Этот Мак отвечает боту»; nil = the default (a desktop answers, a laptop doesn't).
    var answersHere: Bool?
    /// «Общий бот» (SPEC-telegram §7); nil = the shared bot unless an own bot is already set up.
    var shared: Bool?
    /// The menu at the bottom of the chat (§2, «Меню в боте»); nil = the default four.
    var menu: BotMenuConfig?
    /// A profile's own menu, by profile id; profiles without one use `menu`.
    var profileMenus: [String: BotMenuConfig]?
    /// Quick commands from the shared bot's menu run only with this on (§7: the relay must not be able to run them).
    var commandsOverShared: Bool?
    /// Permission requests answered over the shared bot only with this on (§7); without it they come without buttons.
    var answersOverShared: Bool?
    /// 🚀 tasks started and runs stopped over the shared bot only with this on (§7).
    var tasksOverShared: Bool?
    /// ⚙️ «Тихие часы»: notifications to Telegram wait for the morning (from, to: hours); nil = none.
    var quietHours: QuietHours?
    /// ⚙️ «Тишина на 1 ч».
    var mutedUntil: Date?
    /// «Где меню» (§10): false — only the Menu button (the Mini App with the shared bot), no keyboard at the bottom.
    var bottomMenu: Bool?

    /// Alerts to Telegram are held back now: muted, or inside the quiet hours. Requests and replies still come.
    func isQuiet(now: Date, calendar: Calendar = .current) -> Bool {
        if let mutedUntil, mutedUntil > now { return true }
        guard let quietHours else { return false }
        let hour = calendar.component(.hour, from: now)
        return quietHours.from <= quietHours.to
            ? (quietHours.from..<quietHours.to).contains(hour)
            : hour >= quietHours.from || hour < quietHours.to
    }

    /// The menu the chat gets while `profile` is the current one.
    func menu(for profile: String?) -> BotMenuConfig {
        profile.flatMap { profileMenus?[$0] } ?? menu ?? BotMenuConfig()
    }

    func hasOwnMenu(_ profile: String) -> Bool { profileMenus?[profile] != nil }

    /// `profile` nil edits the common menu; a profile id edits that profile's own one.
    mutating func setMenu(_ config: BotMenuConfig, for profile: String?) {
        if let profile {
            profileMenus = (profileMenus ?? [:]).merging([profile: config]) { $1 }
        } else {
            menu = config == BotMenuConfig() ? nil : config
        }
    }

    /// «Своё меню у профиля»: on copies the common menu, off forgets the profile's one.
    mutating func setOwnMenu(_ on: Bool, for profile: String) {
        if on {
            setMenu(menu(for: nil), for: profile)
        } else {
            profileMenus?[profile] = nil
            if profileMenus?.isEmpty == true { profileMenus = nil }
        }
    }
}

/// Hours when alerts to Telegram are held back, e.g. 23 → 8.
struct QuietHours: Codable, Equatable, Hashable, Sendable {
    var from: Int
    var to: Int

    /// What ⚙️ and Settings offer.
    static let presets = [QuietHours(from: 22, to: 8), QuietHours(from: 23, to: 8), QuietHours(from: 0, to: 9)]

    var title: String { String(format: "%02d:00–%02d:00", from, to) }
}

/// The notifications ⚙️ switches; each is a setting the modules' «Telegram» chips show too.
enum BotEvent: String, CaseIterable, Sendable {
    case backgroundResults = "bg", limitAlerts = "lim", calendarReminders = "cal", pullRequests = "pr", requests = "req", weeklySummary = "wk"

    var title: String {
        switch self {
        case .backgroundResults: String(localized: "Итоги фоновых задач")
        case .limitAlerts: String(localized: "Пороги лимитов")
        case .calendarReminders: String(localized: "Напоминания календаря")
        case .pullRequests: String(localized: "PR и CI")
        case .requests: String(localized: "Запросы разрешений")
        case .weeklySummary: String(localized: "Недельная сводка")
        }
    }
}

/// What the menu at the bottom holds and how it is laid out. Items are `BotMenuItem` ids, in order.
struct BotMenuConfig: Codable, Equatable, Sendable {
    var items: [String] = BotMenuConfig.defaultItems
    /// Buttons in a row: 2 or 3.
    var columns = 2

    static let defaultItems = BotScreen.menuScreens.map { BotMenuItem.screen($0).id }

    func contains(_ item: BotMenuItem) -> Bool { item == .screen(.home) || items.contains(item.id) }

    /// 🏠 always stays: it is what sets the menu again.
    mutating func toggle(_ item: BotMenuItem) {
        guard item != .screen(.home) else { return }
        if items.contains(item.id) { items.removeAll { $0 == item.id } } else { items.append(item.id) }
    }

    /// Moves an item up (`by` < 0) or down among the chosen ones.
    mutating func move(_ item: BotMenuItem, by offset: Int) {
        guard let index = items.firstIndex(of: item.id) else { return }
        let target = min(max(index + offset, 0), items.count - 1)
        items.insert(items.remove(at: index), at: target)
    }
}

/// One button of the menu at the bottom: a screen, or a quick command from the library (by its id).
enum BotMenuItem: Equatable, Hashable, Sendable {
    case screen(BotScreen)
    case command(String)

    var id: String {
        switch self {
        case let .screen(screen): "screen:\(screen.rawValue)"
        case let .command(id): "cmd:\(id)"
        }
    }

    init?(id: String) {
        if id.hasPrefix("screen:"), let screen = BotScreen(rawValue: String(id.dropFirst(7))), BotScreen.menuScreens.contains(screen) {
            self = .screen(screen)
        } else if id.hasPrefix("cmd:"), BotMenuItem.isCommandID(String(id.dropFirst(4))) {
            self = .command(String(id.dropFirst(4)))
        } else {
            return nil
        }
    }

    /// Quick command ids are lowercase UUIDs; anything else is not trusted from a button.
    static func isCommandID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }
}
