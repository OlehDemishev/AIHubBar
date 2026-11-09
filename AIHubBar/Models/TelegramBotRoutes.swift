import Foundation

// What comes in from Telegram and what a button or command means (docs/specs/SPEC-telegram.md §3, §4).

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
