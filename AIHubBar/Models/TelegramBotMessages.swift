import Foundation

// A bot message, the menu at the bottom and the lines the screens are made of (docs/specs/SPEC-telegram.md §2).

/// A message the bot sends or edits: Telegram HTML and its inline buttons.
struct BotMessage: Equatable, Sendable {
    struct Button: Equatable, Sendable {
        var title: String
        var route: BotRoute
    }

    var html: String
    var buttons: [[Button]] = []
    /// Carries the menu at the bottom instead of inline buttons: a message has one or the other.
    var menu: BotMenu?
    /// Takes the menu at the bottom away («Где меню» → only the Menu button).
    var removesMenu = false

    var installsMenu: Bool { menu != nil }

    var replyMarkup: [String: Any] {
        if removesMenu { return ["remove_keyboard": true] }
        if let menu { return menu.replyMarkup }
        return ["inline_keyboard": buttons.map { row in row.map { ["text": $0.title, "callback_data": $0.route.data] } }]
    }
}

/// The menu that stays at the bottom of the chat instead of the keyboard (SPEC-telegram §2), as the person set it up:
/// a press sends its title as a message, which the bot reads back as an item.
struct BotMenu: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var item: BotMenuItem
        var title: String
    }

    let entries: [Entry]
    let columns: Int

    /// The chosen items that still exist (a deleted quick command drops out), 🏠 first if it was left out, titles made
    /// unique — the press is read back by its title.
    init(_ config: BotMenuConfig, commands: [QuickCommand]) {
        var items = config.items.compactMap(BotMenuItem.init(id:)).filter { item in
            if case let .command(id) = item { return commands.contains { $0.id == id } }
            return true
        }
        if !items.contains(.screen(.home)) { items.insert(.screen(.home), at: 0) }
        var seen: Set<String> = []
        var entries: [Entry] = []
        for item in items where !entries.contains(where: { $0.item == item }) {
            var title = Self.title(item, commands: commands)
            var number = 2
            while seen.contains(title) {
                title = Self.title(item, commands: commands) + " \(number)"
                number += 1
            }
            seen.insert(title)
            entries.append(Entry(item: item, title: title))
        }
        self.entries = entries
        self.columns = min(max(config.columns, 2), 3)
    }

    static func title(_ screen: BotScreen) -> String {
        switch screen {
        case .home: "🏠 " + String(localized: "Главная")
        case .reports: "📊 " + String(localized: "Отчёты")
        case .mac: "🧹 " + String(localized: "Мак")
        case .help: "❓ " + String(localized: "Команды")
        case .menu: "⚙️ " + String(localized: "Меню")
        case .sessions: "🤖 " + String(localized: "Сессии")
        case .limits: "⏳ " + String(localized: "Лимиты")
        case .task: "🚀 " + String(localized: "Задача")
        case .settings: "⚙️ " + String(localized: "Настройки")
        }
    }

    static func title(_ item: BotMenuItem, commands: [QuickCommand]) -> String {
        switch item {
        case let .screen(screen): return title(screen)
        case let .command(id):
            let name = commands.first { $0.id == id }?.title.trimmingCharacters(in: .whitespaces) ?? ""
            return "▶️ " + (name.count > 28 ? String(name.prefix(27)) + "…" : name)
        }
    }

    /// The item a menu press asks for; nil for any other text.
    func item(forText text: String) -> BotMenuItem? {
        let text = text.trimmingCharacters(in: .whitespaces)
        return entries.first { $0.title == text }?.item
    }

    var rows: [[Entry]] {
        stride(from: 0, to: entries.count, by: columns).map { Array(entries[$0..<min($0 + columns, entries.count)]) }
    }

    var replyMarkup: [String: Any] {
        ["keyboard": rows.map { row in row.map { ["text": $0.title] } }, "is_persistent": true, "resize_keyboard": true]
    }
}

/// One session in 🤖.
struct BotSessionLine: Equatable, Sendable {
    var project: String
    var agent: String
    var waiting: Bool
    /// What it waits for or does now.
    var detail: String?
    var since: Date?
}

/// One open permission request in 🤖.
struct BotRequestLine: Equatable, Sendable {
    var id: String
    var project: String
    var tool: String
    var summary: String
}

/// A project to start a 🚀 task in.
struct BotTaskProject: Equatable, Sendable {
    var key: String
    var name: String
}

/// A background run in 🚀.
struct BotRunLine: Equatable, Sendable {
    var id: String
    var project: String
    var task: String
    var state: BackgroundRun.State
    var paused: Bool
    var startedAt: Date
    var pullRequestURL: String?
}

/// One AI service in ⏳.
struct BotLimitService: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        var title: String
        var percent: Double?
        var detail: String?
        var resetsAt: Date?
        var runsOutAt: Date?
    }

    var title: String
    var windows: [Window]
    var error: String?
    var isStale = false
}

/// What 🏠 shows (§2).
struct BotHomeState: Equatable, Sendable {
    var macName: String
    var session: UsageWindow?
    var week: UsageWindow?
    var working: Int
    var waiting: Int
    var runs: Int
}
