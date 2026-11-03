import Foundation

// The «Telegram» bot's decisions (docs/specs/SPEC-telegram.md): what came in, what a button means, what each screen
// says. Pure, so the tests can read them without a bot; `TelegramBotController` does the talking.

/// The module's settings of this Mac (SPEC-telegram §6); not in the settings export, so each Mac keeps its own.
struct TelegramBotSettings: Codable, Equatable, Sendable {
    /// «Этот Мак отвечает боту»; nil = the default (a desktop answers, a laptop doesn't).
    var answersHere: Bool?
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

    static let reportHours = [1, 3, 24]

    var data: String {
        switch self {
        case let .show(screen): "nav:\(screen.rawValue)"
        case let .report(ai, hours): ai ? (hours.map { "rep:ai:\($0)" } ?? "rep:ai") : "rep:quick"
        case .cleanupCheck: "cln:check"
        case .cleanupAsk: "cln:ask"
        case .cleanupRun: "cln:run"
        case .allCommands: "help:all"
        case let .answer(id, allow): "\(allow ? "allow" : "deny"):\(id)"
        }
    }

    init?(data: String) {
        guard data.utf8.count <= 64 else { return nil }
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
        default: return nil
        }
    }

    /// Does something rather than only showing a screen: skipped right after the Mac slept (§4).
    var isAction: Bool {
        switch self {
        case .show, .cleanupAsk, .allCommands: false
        case .report, .cleanupCheck, .cleanupRun, .answer: true
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
    /// Carries the menu at the bottom (`BotMenu`) instead of inline buttons: a message has one or the other.
    var installsMenu = false

    var replyMarkup: [String: Any] {
        if installsMenu { return BotMenu.replyMarkup }
        return ["inline_keyboard": buttons.map { row in row.map { ["text": $0.title, "callback_data": $0.route.data] } }]
    }
}

/// The menu that stays at the bottom of the chat instead of the keyboard (SPEC-telegram §2): a press sends its title as
/// a message, which the bot reads back as a screen.
enum BotMenu {
    static let rows: [[BotScreen]] = [[.home, .reports], [.mac, .help]]

    static func title(_ screen: BotScreen) -> String {
        switch screen {
        case .home: "🏠 " + String(localized: "Главная")
        case .reports: "📊 " + String(localized: "Отчёты")
        case .mac: "🧹 " + String(localized: "Мак")
        case .help: "❓ " + String(localized: "Команды")
        }
    }

    /// The screen a menu press asks for; nil for any other text.
    static func screen(forText text: String) -> BotScreen? {
        let text = text.trimmingCharacters(in: .whitespaces)
        return BotScreen.allCases.first { title($0) == text }
    }

    static var replyMarkup: [String: Any] {
        ["keyboard": rows.map { row in row.map { ["text": title($0)] } }, "is_persistent": true, "resize_keyboard": true]
    }
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
            [button("📊", String(localized: "Отчёты"), .show(.reports)), button("🧹", String(localized: "Мак"), .show(.mac))],
            [button("🔄", String(localized: "Обновить"), .show(.home)), button("❓", String(localized: "Команды"), .show(.help))],
        ])
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

    static func mac(freeBytes: Int64?, job: String?) -> BotMessage {
        var lines = ["🧹 <b>" + RunMessage.escape(String(localized: "Мак")) + "</b>"]
        if let freeBytes { lines.append("💾 " + RunMessage.escape(String(localized: "Свободно \(CommandStore.diskText(freeBytes))"))) }
        if let job { lines.append("⏳ " + RunMessage.escape(job)) }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: [
            [button("🔍", String(localized: "Что удалит очистка"), .cleanupCheck), button("🧹", String(localized: "Очистить"), .cleanupAsk)],
            [back],
        ])
    }

    static var cleanupConfirm: BotMessage {
        BotMessage(html: "⚠️ " + RunMessage.escape(String(localized: "Удалить сборки, кэши и сбросить симуляторы? Не во время сборки.")), buttons: [
            [button("✅", String(localized: "Да, очистить"), .cleanupRun), button("✖️", String(localized: "Отмена"), .show(.mac))],
        ])
    }

    static func help(hasAllCommands: Bool) -> BotMessage {
        let lines = ["❓ <b>" + RunMessage.escape(String(localized: "Команды")) + "</b>"]
            + BotCommand.menuList.map { "/\($0.command) — " + RunMessage.escape($0.description) }
        var rows = [[back]]
        if hasAllCommands { rows.insert([button("📖", String(localized: "Все команды Мака"), .allCommands)], at: 0) }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
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
