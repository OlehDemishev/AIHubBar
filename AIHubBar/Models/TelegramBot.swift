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

/// One update from `getUpdates` the bot looks at: a text message or a button press.
struct BotUpdate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case message(text: String, messageID: Int?)
        case press(callbackID: String, data: String, messageID: Int?)
    }

    var updateID: Int
    var chatID: String
    var fromID: String
    var isPrivate: Bool
    /// When a message was sent; presses carry no time of their own.
    var date: Date?
    var kind: Kind

    /// From the bound chat itself: a private chat where the sender is that chat (SPEC-telegram §1).
    func isFrom(chat: String) -> Bool {
        !chat.isEmpty && isPrivate && chatID == chat && fromID == chat
    }

    /// The Mac was asleep: a message older than this is skipped (§4).
    static let maxAge: TimeInterval = 30 * 60

    func isStale(now: Date) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) > Self.maxAge
    }

    /// Updates worth handling and the offset that confirms everything read, even updates of other kinds.
    static func parse(_ data: Data) -> (updates: [BotUpdate], nextOffset: Int?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["result"] as? [[String: Any]] else { return ([], nil) }
        var updates: [BotUpdate] = []
        var offset: Int?
        for result in results {
            guard let id = result["update_id"] as? Int else { continue }
            offset = max(offset ?? 0, id + 1)
            if let message = result["message"] as? [String: Any], let text = message["text"] as? String,
               let chat = message["chat"] as? [String: Any] {
                updates.append(BotUpdate(
                    updateID: id, chatID: Self.id(chat["id"]), fromID: Self.id((message["from"] as? [String: Any])?["id"]),
                    isPrivate: chat["type"] as? String == "private",
                    date: (message["date"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                    kind: .message(text: text, messageID: message["message_id"] as? Int)
                ))
            } else if let callback = result["callback_query"] as? [String: Any],
                      let callbackID = callback["id"] as? String, let data = callback["data"] as? String {
                let message = callback["message"] as? [String: Any]
                let chat = message?["chat"] as? [String: Any]
                let from = Self.id((callback["from"] as? [String: Any])?["id"])
                updates.append(BotUpdate(
                    // A press on an old message may come without it: the sender's id stands for the private chat.
                    updateID: id, chatID: chat.map { Self.id($0["id"]) } ?? from, fromID: from,
                    isPrivate: chat.map { $0["type"] as? String == "private" } ?? true,
                    date: nil, kind: .press(callbackID: callbackID, data: data, messageID: message?["message_id"] as? Int)
                ))
            }
        }
        return (updates, offset)
    }

    private static func id(_ value: Any?) -> String {
        (value as? NSNumber)?.stringValue ?? (value as? String) ?? ""
    }
}

/// The bot's screens; each is one message, edited in place by its buttons (§2).
enum BotScreen: String, CaseIterable, Sendable {
    case home, reports, mac, help
    /// ⚙️ «Меню»: which buttons the menu at the bottom has, from the bot itself.
    case menu
    case sessions, limits, task, settings

    /// The screens a menu button can open, in the default menu's order.
    static let menuScreens: [BotScreen] = [.home, .sessions, .task, .limits, .reports, .mac, .settings, .help]
}

/// What a button's `callback_data` means (§3): at most 64 ASCII bytes, `<verb>[:<arg>]`.
enum BotRoute: Equatable, Sendable {
    case show(BotScreen)
    /// `hours` nil = since the morning report.
    case report(ai: Bool, hours: Int?)
    case cleanupCheck
    /// The confirmation screen; only `cleanupRun` cleans.
    case cleanupAsk
    case cleanupRun
    /// `_daily-report/help.txt`.
    case allCommands
    /// A permission request, in the approvals bot's format.
    case answer(requestID: String, allow: Bool)
    /// ⚙️ «Меню»: switch a button on or off; the buttons in a row.
    case menuToggle(BotMenuItem)
    case menuColumns(Int)
    /// «Готово»: the menu at the bottom is sent again.
    case menuDone
    /// A quick command, after «Запустить?».
    case runCommand(String)
    /// «Подробнее» on a permission request.
    case requestDetails(String)
    /// ⏳: limit notifications to Telegram on or off.
    case limitAlerts(Bool)
    /// 🚀: a project (by `projectKey`), then the task typed as a message, then «Запустить» or «Отмена».
    case taskProject(String)
    case taskGo
    case taskCancel
    /// After the 90 % question: start anyway, or after the reset; after «Claude already works here»: in a worktree.
    case taskForce
    case taskAfterReset
    case taskWorktree
    /// A background run: its log tail, «Остановить?», the confirmed stop.
    case runLog(String)
    case runStopAsk(String)
    case runStop(String)
    /// ⚙️: a notification on or off, the quiet hours (nil = none), «Тишина на 1 ч» on or off.
    case event(BotEvent)
    case quiet(QuietHours?)
    case mute(Bool)
    /// 🧹: «Не спать» for an hour, or off.
    case keepAwake(Bool)

    static let reportHours = [1, 3, 24]

    /// A project's path as 8 hex digits (FNV-1a), short enough for a button and stable while the list changes.
    static func projectKey(_ path: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    var data: String {
        switch self {
        case let .show(screen): "nav:\(screen.rawValue)"
        case let .report(ai, hours): ai ? (hours.map { "rep:ai:\($0)" } ?? "rep:ai") : "rep:quick"
        case .cleanupCheck: "cln:check"
        case .cleanupAsk: "cln:ask"
        case .cleanupRun: "cln:run"
        case .allCommands: "help:all"
        case let .answer(id, allow): "\(allow ? "allow" : "deny"):\(id)"
        case let .menuToggle(item): "mt:\(item.id)"
        case let .menuColumns(columns): "mc:\(columns)"
        case .menuDone: "md"
        case let .runCommand(id): "run:\(id)"
        case let .requestDetails(id): "req:\(id)"
        case let .limitAlerts(on): on ? "lim:on" : "lim:off"
        case let .taskProject(key): "tsk:p:\(key)"
        case .taskGo: "tsk:go"
        case .taskCancel: "tsk:no"
        case .taskForce: "tsk:force"
        case .taskAfterReset: "tsk:after"
        case .taskWorktree: "tsk:wt"
        case let .runLog(id): "rl:\(id)"
        case let .runStopAsk(id): "rs:\(id)"
        case let .runStop(id): "rx:\(id)"
        case let .event(event): "ev:\(event.rawValue)"
        case let .quiet(hours): hours.map { "qh:\($0.from):\($0.to)" } ?? "qh:off"
        case let .mute(on): on ? "mute:1" : "mute:0"
        case let .keepAwake(on): on ? "ka:1" : "ka:0"
        }
    }

    init?(data: String) {
        guard data.utf8.count <= 64 else { return nil }
        if data.hasPrefix("mt:") {
            guard let item = BotMenuItem(id: String(data.dropFirst(3))) else { return nil }
            self = .menuToggle(item)
            return
        }
        let parts = data.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch (parts[0], parts.count) {
        case ("nav", 2):
            guard let screen = BotScreen(rawValue: parts[1]) else { return nil }
            self = .show(screen)
        case ("rep", 2) where parts[1] == "ai": self = .report(ai: true, hours: nil)
        case ("rep", 2) where parts[1] == "quick": self = .report(ai: false, hours: nil)
        case ("rep", 3) where parts[1] == "ai":
            guard let hours = Int(parts[2]), (1...168).contains(hours) else { return nil }
            self = .report(ai: true, hours: hours)
        case ("cln", 2) where parts[1] == "check": self = .cleanupCheck
        case ("cln", 2) where parts[1] == "ask": self = .cleanupAsk
        case ("cln", 2) where parts[1] == "run": self = .cleanupRun
        case ("help", 2) where parts[1] == "all": self = .allCommands
        case ("allow", 2), ("deny", 2):
            guard ApprovalFiles.isValidID(parts[1]) else { return nil }
            self = .answer(requestID: parts[1], allow: parts[0] == "allow")
        case ("mc", 2):
            guard let columns = Int(parts[1]), [2, 3].contains(columns) else { return nil }
            self = .menuColumns(columns)
        case ("md", 1): self = .menuDone
        case ("run", 2):
            guard BotMenuItem.isCommandID(parts[1]) else { return nil }
            self = .runCommand(parts[1])
        case ("req", 2):
            guard ApprovalFiles.isValidID(parts[1]) else { return nil }
            self = .requestDetails(parts[1])
        case ("lim", 2) where ["on", "off"].contains(parts[1]): self = .limitAlerts(parts[1] == "on")
        case ("tsk", 3) where parts[1] == "p":
            guard parts[2].count == 8, parts[2].allSatisfy(\.isHexDigit) else { return nil }
            self = .taskProject(parts[2])
        case ("tsk", 2):
            switch parts[1] {
            case "go": self = .taskGo
            case "no": self = .taskCancel
            case "force": self = .taskForce
            case "after": self = .taskAfterReset
            case "wt": self = .taskWorktree
            default: return nil
            }
        case ("ev", 2):
            guard let event = BotEvent(rawValue: parts[1]) else { return nil }
            self = .event(event)
        case ("qh", 2) where parts[1] == "off": self = .quiet(nil)
        case ("qh", 3):
            guard let from = Int(parts[1]), let to = Int(parts[2]), QuietHours.presets.contains(QuietHours(from: from, to: to)) else { return nil }
            self = .quiet(QuietHours(from: from, to: to))
        case ("mute", 2) where ["0", "1"].contains(parts[1]): self = .mute(parts[1] == "1")
        case ("ka", 2) where ["0", "1"].contains(parts[1]): self = .keepAwake(parts[1] == "1")
        case ("rl", 2), ("rs", 2), ("rx", 2):
            guard BotMenuItem.isCommandID(parts[1]) else { return nil }
            self = parts[0] == "rl" ? .runLog(parts[1]) : parts[0] == "rs" ? .runStopAsk(parts[1]) : .runStop(parts[1])
        default: return nil
        }
    }

    /// Does something rather than only showing a screen: skipped right after the Mac slept (§4).
    var isAction: Bool {
        switch self {
        case .show, .cleanupAsk, .allCommands, .menuToggle, .menuColumns, .menuDone, .requestDetails, .limitAlerts,
             .taskProject, .taskCancel, .runLog, .runStopAsk, .event, .quiet, .mute: false
        case .report, .cleanupCheck, .cleanupRun, .answer, .runCommand, .taskGo, .taskForce, .taskAfterReset, .taskWorktree, .runStop,
             .keepAwake: true
        }
    }
}

/// A typed command; the old `bot.py` ones keep their meaning (§2).
enum BotCommand: Equatable, Sendable {
    case menu
    /// `/start <code>` from the link on the module's page binds the chat.
    case start(code: String?)
    case help
    /// `ai` false = `/status`, the quick one. `hours` nil = since the morning report.
    case report(ai: Bool, hours: Double?)
    case clean(check: Bool)
    /// Drops a 🚀 task being typed.
    case cancel
    case badHours
    case unknown

    /// The commands in the bot's Menu button, for `setMyCommands`.
    static var menuList: [(command: String, description: String)] {
        [
            ("menu", String(localized: "Главная: лимиты, сессии, фоновые задачи")),
            ("report", String(localized: "Отчёт с AI с утра до сейчас (или /report 3)")),
            ("status", String(localized: "Быстрая сводка без AI")),
            ("clean", String(localized: "Очистка сборок (/clean check — только показать)")),
            ("help", String(localized: "Команды бота")),
        ]
    }

    /// Nil for text that isn't a command.
    init?(text: String) {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first, first.hasPrefix("/") else { return nil }
        let name = first.dropFirst().split(separator: "@").first.map { $0.lowercased() } ?? ""
        let argument = parts.dropFirst().first
        switch name {
        case "start": self = .start(code: argument)
        case "menu", "home": self = .menu
        case "help", "commands", "помощь": self = .help
        case "report", "status":
            if let argument {
                guard let hours = Double(argument.replacingOccurrences(of: ",", with: ".")), hours.isFinite else {
                    self = .badHours
                    return
                }
                self = .report(ai: name == "report", hours: min(168, max(0.25, hours)))
            } else {
                self = .report(ai: name == "report", hours: nil)
            }
        case "clean": self = .clean(check: argument.map { ["check", "dry", "проверка", "?"].contains($0.lowercased()) } ?? false)
        case "cancel", "отмена": self = .cancel
        default: self = .unknown
        }
    }
}

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

    var installsMenu: Bool { menu != nil }

    var replyMarkup: [String: Any] {
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

/// The screens' texts and buttons.
enum BotScreens {
    static func home(_ state: BotHomeState, now: Date) -> BotMessage {
        var lines = ["🏠 <b>AI Hub Bar</b> · " + RunMessage.escape(state.macName)]
        var limits: [String] = []
        if let session = state.session {
            var text = String(localized: "сессия \(percent(session.utilization))")
            if let resets = session.resetsAt, resets > now {
                text += " (" + String(localized: "сброс через \(MenuBarComposer.countdown(to: resets, now: now, long: true))") + ")"
            }
            limits.append(text)
        }
        if let week = state.week { limits.append(String(localized: "неделя \(percent(week.utilization))")) }
        lines.append("⏳ Claude: " + (limits.isEmpty ? String(localized: "лимиты ещё не загружены") : limits.joined(separator: ", ")))
        lines.append("🤖 " + String(localized: "Сессии: \(state.working) работают, \(state.waiting) ждут"))
        lines.append("🚀 " + String(localized: "Фоновые задачи: \(state.runs)"))
        return BotMessage(html: lines.joined(separator: "\n"), buttons: [
            [button("🤖", String(localized: "Сессии"), .show(.sessions)), button("🚀", String(localized: "Задача"), .show(.task))],
            [button("⏳", String(localized: "Лимиты"), .show(.limits)), button("📊", String(localized: "Отчёты"), .show(.reports))],
            [button("🧹", String(localized: "Мак"), .show(.mac))],
            [button("🔄", String(localized: "Обновить"), .show(.home)), button("❓", String(localized: "Команды"), .show(.help))],
        ])
    }

    // MARK: 🤖 Sessions and requests (stage 2)

    /// 🤖: waiting sessions first, then working ones; open permission requests numbered, with ✅ / ❌ when this chat
    /// may answer them (`canAnswer`), and «ℹ️» always.
    static func sessions(_ lines: [BotSessionLine], requests: [BotRequestLine], canAnswer: Bool, now: Date) -> BotMessage {
        var text = ["🤖 <b>" + RunMessage.escape(String(localized: "Сессии")) + "</b>"]
        let ordered = lines.filter(\.waiting) + lines.filter { !$0.waiting }
        if ordered.isEmpty { text.append(RunMessage.escape(String(localized: "Сессий сейчас нет."))) }
        for line in ordered.prefix(15) {
            var row = (line.waiting ? "✋ " : "⚙️ ") + "<b>" + RunMessage.escape(line.project) + "</b> · " + RunMessage.escape(line.agent)
            if let since = line.since { row += " · " + RunMessage.escape(RelativeTime.ago(since, now: now)) }
            if let detail = line.detail, !detail.isEmpty { row += "\n    " + RunMessage.escape(String(detail.prefix(120))) }
            text.append(row)
        }
        if ordered.count > 15 { text.append(RunMessage.escape(String(localized: "… и ещё \(ordered.count - 15)"))) }
        var rows: [[BotMessage.Button]] = []
        if !requests.isEmpty {
            text.append("")
            text.append("✋ <b>" + RunMessage.escape(String(localized: "Запросы разрешений")) + "</b>")
            for (index, request) in requests.prefix(8).enumerated() {
                let number = index + 1
                text.append("\(number). <b>" + RunMessage.escape(request.project) + "</b>: " + RunMessage.escape(request.tool)
                            + (request.summary.isEmpty ? "" : " — <code>" + RunMessage.escape(String(request.summary.prefix(80))) + "</code>"))
                var row = [BotMessage.Button(title: "ℹ️ \(number)", route: .requestDetails(request.id))]
                if canAnswer {
                    row.insert(BotMessage.Button(title: "❌ \(number)", route: .answer(requestID: request.id, allow: false)), at: 0)
                    row.insert(BotMessage.Button(title: "✅ \(number)", route: .answer(requestID: request.id, allow: true)), at: 0)
                }
                rows.append(row)
            }
            if !canAnswer { text.append("🔒 " + RunMessage.escape(String(localized: "Отвечать отсюда нельзя — включите на Маке «Ответы на запросы через общий бот»."))) }
        }
        rows.append([button("🔄", String(localized: "Обновить"), .show(.sessions)), back])
        return BotMessage(html: text.joined(separator: "\n"), buttons: rows)
    }

    /// A new permission request, sent by the Mac where Claude asks.
    static func request(_ request: ApprovalRequest, project: String, canAnswer: Bool) -> BotMessage {
        var html = TelegramApprovalText.html(ApprovalRequest(id: request.id, sessionID: request.sessionID, project: project,
                                                              tool: request.tool, summary: request.summary, created: request.created, pid: request.pid))
        var row = [button("ℹ️", String(localized: "Подробнее"), .requestDetails(request.id))]
        if canAnswer {
            row.insert(button("❌", String(localized: "Отклонить"), .answer(requestID: request.id, allow: false)), at: 0)
            row.insert(button("✅", String(localized: "Разрешить"), .answer(requestID: request.id, allow: true)), at: 0)
        } else {
            html += "\n🔒 " + RunMessage.escape(String(localized: "Ответить можно на Маке или с включёнными «Ответами на запросы через общий бот»."))
        }
        return BotMessage(html: html, buttons: [row])
    }

    /// The request message once it is answered (here, on the Mac or by Claude itself): no more buttons.
    static func requestClosed(_ request: ApprovalRequest, project: String, outcome: Bool?) -> BotMessage {
        let base = TelegramApprovalText.html(ApprovalRequest(id: request.id, sessionID: request.sessionID, project: project,
                                                              tool: request.tool, summary: request.summary, created: request.created, pid: request.pid))
        let note = switch outcome {
        case true?: "✅ " + RunMessage.escape(String(localized: "Разрешено"))
        case false?: "❌ " + RunMessage.escape(String(localized: "Отклонено"))
        case nil: "☑️ " + RunMessage.escape(String(localized: "Ответ уже дан"))
        }
        return BotMessage(html: base + "\n" + note)
    }

    /// «Подробнее»: the whole request and what the session was asked to do.
    static func requestDetails(_ request: ApprovalRequest, project: String, task: String?, folder: String?, canAnswer: Bool) -> BotMessage {
        var lines = ["✋ <b>" + RunMessage.escape(project) + "</b> — " + RunMessage.escape(request.tool)]
        if !request.summary.isEmpty { lines.append("<pre>" + RunMessage.escape(request.summary) + "</pre>") }
        if let task, !task.isEmpty { lines.append(RunMessage.escape(String(localized: "Задача сессии:")) + " " + RunMessage.escape(String(task.prefix(300)))) }
        if let folder { lines.append("📁 <code>" + RunMessage.escape(PathText.tilde(folder)) + "</code>") }
        var rows: [[BotMessage.Button]] = [[button("🤖", String(localized: "Сессии"), .show(.sessions))]]
        if canAnswer {
            rows.insert([button("✅", String(localized: "Разрешить"), .answer(requestID: request.id, allow: true)),
                         button("❌", String(localized: "Отклонить"), .answer(requestID: request.id, allow: false))], at: 0)
        }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    // MARK: ⏳ Limits (stage 2)

    /// ⏳: every AI service's windows with a bar, the reset and the forecast; the Telegram alerts switch.
    static func limits(_ services: [BotLimitService], alertsOn: Bool, thresholds: [Int], now: Date) -> BotMessage {
        var lines = ["⏳ <b>" + RunMessage.escape(String(localized: "Лимиты")) + "</b>"]
        if services.isEmpty { lines.append(RunMessage.escape(String(localized: "лимиты ещё не загружены"))) }
        for service in services {
            lines.append("")
            lines.append("<b>" + RunMessage.escape(service.title) + "</b>" + (service.isStale ? " · " + RunMessage.escape(String(localized: "устарело")) : ""))
            if let error = service.error, service.windows.isEmpty { lines.append("⚠️ " + RunMessage.escape(error)) }
            for window in service.windows.prefix(5) {
                var line = RunMessage.escape(window.title) + " "
                if let percent = window.percent {
                    line += "<code>" + bar(percent) + "</code> " + "\(Int(percent.rounded())) %"
                } else if let detail = window.detail {
                    line += RunMessage.escape(detail)
                }
                if let resets = window.resetsAt, resets > now {
                    line += " · " + RunMessage.escape(String(localized: "сброс через \(MenuBarComposer.countdown(to: resets, now: now, long: true))"))
                }
                if let runsOut = window.runsOutAt, runsOut > now {
                    line += "\n    ⚠️ " + RunMessage.escape(String(localized: "при этом темпе кончится к \(runsOut.formatted(date: .omitted, time: .shortened))"))
                }
                lines.append(line)
            }
        }
        lines.append("")
        let levels = thresholds.map { "\($0)" }.joined(separator: "/")
        lines.append("🔔 " + RunMessage.escape(alertsOn
            ? String(localized: "Уведомления в Telegram: при \(levels) %")
            : String(localized: "Уведомления о лимитах в Telegram выключены")))
        return BotMessage(html: lines.joined(separator: "\n"), buttons: [
            [button(alertsOn ? "🔕" : "🔔", alertsOn ? String(localized: "Выключить уведомления") : String(localized: "Включить уведомления"), .limitAlerts(!alertsOn))],
            [button("🔄", String(localized: "Обновить"), .show(.limits)), back],
        ])
    }

    // MARK: 🚀 Tasks and runs (stage 3)

    /// 🚀: projects to start a task in (`locked` — over the shared bot without its switch), then the runs: running ones
    /// with 📜 / ⏹, the last finished ones with their PR link (a link only — PRs are merged in GitHub).
    static func task(projects: [BotTaskProject], runs: [BotRunLine], locked: Bool, now: Date) -> BotMessage {
        var lines = ["🚀 <b>" + RunMessage.escape(String(localized: "Задача")) + "</b>"]
        var rows: [[BotMessage.Button]] = []
        if locked {
            lines.append("🔒 " + RunMessage.escape(String(localized: "Задачи через общий бот выключены. На Маке: Настройки → Модули → Telegram → «Задачи через общий бот».")))
        } else if projects.isEmpty {
            lines.append(RunMessage.escape(String(localized: "Проектов нет: у профиля нет папки с git-проектами.")))
        } else {
            lines.append(RunMessage.escape(String(localized: "Выберите проект, затем напишите задачу. Её выполнит Claude Code в фоне.")))
            let buttons = projects.prefix(12).map { BotMessage.Button(title: "📁 " + String($0.name.prefix(24)), route: .taskProject($0.key)) }
            rows += stride(from: 0, to: buttons.count, by: 2).map { Array(buttons[$0..<min($0 + 2, buttons.count)]) }
        }
        let running = runs.filter { $0.state == .running }
        let finished = runs.filter { $0.state != .running }.prefix(3)
        if !running.isEmpty || !finished.isEmpty {
            lines.append("")
            lines.append("<b>" + RunMessage.escape(String(localized: "Фоновые задачи")) + "</b>")
        }
        for (index, run) in running.prefix(6).enumerated() {
            let number = index + 1
            let minutes = max(0, Int(now.timeIntervalSince(run.startedAt) / 60))
            lines.append("\(number). " + (run.paused ? "⏸ " : "⚙️ ") + "<b>" + RunMessage.escape(run.project) + "</b>: "
                         + RunMessage.escape(RunMessage.taskStart(run.task)) + " · " + RunMessage.escape(String(localized: "\(minutes) мин")))
            var row = [BotMessage.Button(title: "📜 \(number)", route: .runLog(run.id))]
            if !locked { row.append(BotMessage.Button(title: "⏹ \(number)", route: .runStopAsk(run.id))) }
            rows.append(row)
        }
        for run in finished {
            var line = RunMessage.icon(run.state) + " <b>" + RunMessage.escape(run.project) + "</b>: " + RunMessage.escape(RunMessage.taskStart(run.task))
            if let url = run.pullRequestURL {
                let number = url.split(separator: "/").last.map { " #\($0)" } ?? ""
                line += " — <a href=\"" + RunMessage.escape(url) + "\">PR" + number + "</a>"
            }
            lines.append(line)
        }
        rows.append([button("🔄", String(localized: "Обновить"), .show(.task)), back])
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    static func taskAskText(project: String) -> BotMessage {
        BotMessage(html: "🚀 <b>" + RunMessage.escape(project) + "</b>\n"
                   + RunMessage.escape(String(localized: "Напишите задачу одним сообщением. /cancel — отмена.")),
                   buttons: [[button("✖️", String(localized: "Отмена"), .taskCancel)]])
    }

    /// The task shown back before it starts (§4).
    static func taskConfirm(project: String, text: String) -> BotMessage {
        BotMessage(html: "🚀 " + RunMessage.escape(String(localized: "Запустить в фоне в «\(project)»?")) + "\n<blockquote>"
                   + RunMessage.escape(String(text.prefix(1500))) + "</blockquote>",
                   buttons: [[button("▶️", String(localized: "Запустить"), .taskGo), button("✖️", String(localized: "Отмена"), .taskCancel)]])
    }

    /// The launch stopped to ask: the session is above 90 %, or Claude already works in the folder.
    static func taskQuestion(_ text: String, limit: Bool) -> BotMessage {
        let rows: [[BotMessage.Button]] = limit
            ? [[button("▶️", String(localized: "Всё равно"), .taskForce), button("⏰", String(localized: "После сброса"), .taskAfterReset)],
               [button("✖️", String(localized: "Отмена"), .taskCancel)]]
            : [[button("✅", String(localized: "Да, в worktree"), .taskWorktree), button("✖️", String(localized: "Отмена"), .taskCancel)]]
        return BotMessage(html: "⚠️ " + RunMessage.escape(text), buttons: rows)
    }

    /// The last steps of a run's log.
    static func runLog(_ run: BotRunLine, entries: [StreamJSON.Entry]) -> BotMessage {
        var lines = ["📜 <b>" + RunMessage.escape(run.project) + "</b>: " + RunMessage.escape(RunMessage.taskStart(run.task))]
        let tail = entries.suffix(12).map { entry -> String in
            let icon = switch entry.kind {
            case .text: "💬"
            case .tool: "🔧"
            case .result: "✅"
            case .error: "❌"
            }
            let flat = entry.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return icon + " " + String(flat.prefix(160))
        }
        lines.append(tail.isEmpty ? RunMessage.escape(String(localized: "В журнале пока пусто.")) : "<pre>" + RunMessage.escape(tail.joined(separator: "\n")) + "</pre>")
        var row = [button("🔄", String(localized: "Обновить"), .runLog(run.id))]
        if run.state == .running { row.append(button("⏹", String(localized: "Остановить"), .runStopAsk(run.id))) }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: [row, [button("🚀", String(localized: "Задача"), .show(.task))]])
    }

    static func runStopConfirm(_ run: BotRunLine) -> BotMessage {
        BotMessage(html: "⏹ " + RunMessage.escape(String(localized: "Остановить «\(RunMessage.taskStart(run.task))» в «\(run.project)»?")),
                   buttons: [[button("⏹", String(localized: "Остановить"), .runStop(run.id)), button("✖️", String(localized: "Отмена"), .show(.task))]])
    }

    /// `▓▓▓▓░░░░░░` for 0…100 %.
    static func bar(_ percent: Double) -> String {
        let filled = min(10, max(0, Int((percent / 10).rounded())))
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: 10 - filled)
    }

    /// `job` — what is running now, if anything; `otherBot` — `report.py` sends through another bot.
    static func reports(job: String?, otherBot: Bool) -> BotMessage {
        var lines = ["📊 <b>" + RunMessage.escape(String(localized: "Отчёты")) + "</b>",
                     RunMessage.escape(String(localized: "С AI — 1–3 минуты, с HTML-файлом; быстрая сводка — за секунды, без AI."))]
        if otherBot { lines.append("ℹ️ " + RunMessage.escape(String(localized: "Отчёт пришлёт бот из _daily-report/config.json."))) }
        if let job { lines.append("⏳ " + RunMessage.escape(job)) }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: [
            [button("✨", String(localized: "С AI с утра"), .report(ai: true, hours: nil)),
             button("⚡", String(localized: "Быстрая сводка"), .report(ai: false, hours: nil))],
            BotRoute.reportHours.map { hours in
                button("✨", String(localized: "\(hours) ч"), .report(ai: true, hours: hours))
            },
            [back],
        ])
    }

    /// `keepAwake` — «Не спать» holds the Mac now; nil when that module isn't installed.
    static func mac(freeBytes: Int64?, job: String?, keepAwake: Bool? = nil) -> BotMessage {
        var lines = ["🧹 <b>" + RunMessage.escape(String(localized: "Мак")) + "</b>"]
        if let freeBytes { lines.append("💾 " + RunMessage.escape(String(localized: "Свободно \(CommandStore.diskText(freeBytes))"))) }
        if let keepAwake {
            lines.append("☕ " + RunMessage.escape(keepAwake ? String(localized: "«Не спать» включено") : String(localized: "«Не спать» выключено")))
        }
        if let job { lines.append("⏳ " + RunMessage.escape(job)) }
        var rows = [[button("🔍", String(localized: "Что удалит очистка"), .cleanupCheck), button("🧹", String(localized: "Очистить"), .cleanupAsk)]]
        if let keepAwake {
            rows.append([keepAwake ? button("☕", String(localized: "Выключить «Не спать»"), .keepAwake(false))
                                   : button("☕", String(localized: "Не спать 1 ч"), .keepAwake(true))])
        }
        rows.append([back])
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    // MARK: ⚙️ Settings (stage 4)

    /// ⚙️: which notifications come, the quiet hours, an hour of silence, the morning report time (read only:
    /// it belongs to `_daily-report`), and the way to the menu set-up.
    static func settings(events: [(BotEvent, Bool)], quiet: QuietHours?, mutedUntil: Date?, morningHour: Int?, now: Date) -> BotMessage {
        var lines = ["⚙️ <b>" + RunMessage.escape(String(localized: "Настройки")) + "</b>",
                     RunMessage.escape(String(localized: "Что приходит в Telegram — нажмите, чтобы включить или выключить."))]
        lines.append("🌙 " + RunMessage.escape(String(localized: "Тихие часы: \(quiet?.title ?? String(localized: "нет"))")))
        if let mutedUntil, mutedUntil > now {
            lines.append("🔕 " + RunMessage.escape(String(localized: "Тишина до \(mutedUntil.formatted(date: .omitted, time: .shortened))")))
        }
        if let morningHour { lines.append("🌅 " + RunMessage.escape(String(localized: "Утренний отчёт: \(String(format: "%02d:00", morningHour)) (меняется в _daily-report)"))) }
        var rows = events.map { event, on in
            [BotMessage.Button(title: (on ? "✅ " : "☐ ") + event.title, route: .event(event))]
        }
        rows.append([BotMessage.Button(title: (quiet == nil ? "● " : "○ ") + String(localized: "Без тихих часов"), route: .quiet(nil))]
                    + QuietHours.presets.map { BotMessage.Button(title: (quiet == $0 ? "● " : "○ ") + String(format: "%02d–%02d", $0.from, $0.to), route: .quiet($0)) })
        rows.append([(mutedUntil ?? .distantPast) > now
            ? button("🔔", String(localized: "Снять тишину"), .mute(false))
            : button("🔕", String(localized: "Тишина на 1 ч"), .mute(true))])
        rows.append([button("⚙️", String(localized: "Настроить меню"), .show(.menu)), back])
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    static var cleanupConfirm: BotMessage {
        BotMessage(html: "⚠️ " + RunMessage.escape(String(localized: "Удалить сборки, кэши и сбросить симуляторы? Не во время сборки.")), buttons: [
            [button("✅", String(localized: "Да, очистить"), .cleanupRun), button("✖️", String(localized: "Отмена"), .show(.mac))],
        ])
    }

    static func help(hasAllCommands: Bool) -> BotMessage {
        let lines = ["❓ <b>" + RunMessage.escape(String(localized: "Команды")) + "</b>"]
            + BotCommand.menuList.map { "/\($0.command) — " + RunMessage.escape($0.description) }
        var rows = [[button("⚙️", String(localized: "Настроить меню"), .show(.menu))], [back]]
        if hasAllCommands { rows.insert([button("📖", String(localized: "Все команды Мака"), .allCommands)], at: 0) }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    /// ⚙️ «Меню»: a switch per screen and quick command (🏠 always stays), the buttons in a row. `profile` — the
    /// current profile's name when it has a menu of its own.
    static func menuSetup(_ config: BotMenuConfig, commands: [QuickCommand], profile: String?) -> BotMessage {
        var lines = ["⚙️ <b>" + RunMessage.escape(String(localized: "Меню внизу чата")) + "</b>"]
        if let profile { lines.append(RunMessage.escape(String(localized: "Своё меню профиля «\(profile)»."))) }
        lines.append(RunMessage.escape(String(localized: "Нажмите, чтобы добавить или убрать кнопку; порядок — в Настройках на Маке.")))
        let candidates = BotScreen.menuScreens.filter { $0 != .home }.map(BotMenuItem.screen) + commands.map { BotMenuItem.command($0.id) }
        var rows = candidates.map { item in
            [BotMessage.Button(title: (config.contains(item) ? "✅ " : "☐ ") + BotMenu.title(item, commands: commands), route: .menuToggle(item))]
        }
        rows.append([2, 3].map { columns in
            BotMessage.Button(title: (config.columns == columns ? "● " : "○ ") + String(localized: "\(columns) в ряд"), route: .menuColumns(columns))
        })
        rows.append([button("✅", String(localized: "Готово"), .menuDone)])
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    /// «Запустить?» for a quick command marked to ask first, and for any over the shared bot.
    static func confirmCommand(_ command: QuickCommand) -> BotMessage {
        BotMessage(html: "▶️ " + RunMessage.escape(String(localized: "Запустить «\(command.title)» на Маке?")), buttons: [[
            button("✅", String(localized: "Запустить"), .runCommand(command.id)), button("✖️", String(localized: "Отмена"), .show(.home)),
        ]])
    }

    /// A quick command's result.
    static func commandResult(_ command: QuickCommand, ok: Bool, text: String) -> String {
        (ok ? "✅" : "❌") + " <b>" + RunMessage.escape(command.title) + "</b>" + (text.isEmpty ? "" : "\n<code>" + RunMessage.escape(String(text.prefix(3000))) + "</code>")
    }

    /// The cleanup output: its first line and up to 24 more, as `bot.py` sent it.
    static func cleanupOutput(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var body = lines.prefix(25).joined(separator: "\n")
        if lines.count > 25 { body += "\n" + String(localized: "… ещё \(lines.count - 25) строк в logs/cleanup.jsonl") }
        return "<pre>" + RunMessage.escape(body.isEmpty ? String(localized: "нет вывода") : body) + "</pre>"
    }

    /// A failed script: its last lines.
    static func failure(_ title: String, output: String) -> String {
        let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
        return "❌ " + RunMessage.escape(title) + (tail.isEmpty ? "" : "\n<code>" + RunMessage.escape(tail) + "</code>")
    }

    /// Hours since the morning report, as `bot.py` counted: from today's report hour, or yesterday's in the first
    /// 5 minutes after it and before it.
    static func hoursSinceMorning(now: Date, hour: Int = 10, calendar: Calendar = .current) -> Double {
        var anchor = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        if now < anchor.addingTimeInterval(5 * 60) {
            anchor = calendar.date(byAdding: .day, value: -1, to: anchor) ?? anchor
        }
        return max(0.25, now.timeIntervalSince(anchor) / 3600)
    }

    /// «45 мин», «3 ч», «1,5 ч».
    static func hoursText(_ hours: Double) -> String {
        if hours < 1 { return String(localized: "\(Int((hours * 60).rounded())) мин") }
        if abs(hours - hours.rounded()) < 0.05 { return String(localized: "\(Int(hours.rounded())) ч") }
        return String(localized: "\(hours.formatted(.number.precision(.fractionLength(1)))) ч")
    }

    private static var back: BotMessage.Button { button("⬅️", String(localized: "Главная"), .show(.home)) }

    private static func button(_ icon: String, _ title: String, _ route: BotRoute) -> BotMessage.Button {
        BotMessage.Button(title: icon + " " + title, route: route)
    }

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded())) %" }
}
