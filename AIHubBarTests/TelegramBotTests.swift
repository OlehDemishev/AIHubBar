import Foundation
import Testing
@testable import AIHubBar

/// The «Telegram» bot (docs/specs/SPEC-telegram.md): updates, button data, commands and screens. No real tokens here.
struct TelegramBotTests {
    private func data(_ results: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["ok": true, "result": results])
    }

    // MARK: Updates

    @Test func readsMessagesAndPresses() throws {
        let (updates, next) = BotUpdate.parse(try data([
            ["update_id": 5, "message": ["message_id": 1, "date": 1_700_000_000, "text": "/menu",
                                         "chat": ["id": 42, "type": "private"], "from": ["id": 42]]],
            ["update_id": 6, "callback_query": ["id": "c1", "data": "nav:mac", "from": ["id": 42],
                                                "message": ["message_id": 9, "chat": ["id": 42, "type": "private"]]]],
            // Kinds the bot doesn't read still move the offset.
            ["update_id": 8, "edited_message": ["text": "x"]],
            ["update_id": 7, "message": ["message_id": 2, "chat": ["id": 42, "type": "private"]]],
        ]))
        #expect(next == 9)
        #expect(updates == [
            BotUpdate(updateID: 5, chatID: "42", fromID: "42", isPrivate: true, date: Date(timeIntervalSince1970: 1_700_000_000), kind: .message(text: "/menu", messageID: 1)),
            BotUpdate(updateID: 6, chatID: "42", fromID: "42", isPrivate: true, date: nil, kind: .press(callbackID: "c1", data: "nav:mac", messageID: 9)),
        ])
        #expect(BotUpdate.parse(Data("garbage".utf8)).updates.isEmpty)
        #expect(BotUpdate.parse(Data(#"{"ok":false,"error_code":409}"#.utf8)).nextOffset == nil)
    }

    @Test func onlyTheBoundPrivateChat() throws {
        let (updates, _) = BotUpdate.parse(try data([
            ["update_id": 1, "message": ["text": "/clean", "chat": ["id": 42, "type": "private"], "from": ["id": 42]]],
            // A stranger who found the bot.
            ["update_id": 2, "message": ["text": "/clean", "chat": ["id": 99, "type": "private"], "from": ["id": 99]]],
            // The owner, but in a group the bot was added to.
            ["update_id": 3, "message": ["text": "/clean", "chat": ["id": -100, "type": "group"], "from": ["id": 42]]],
            // A press on an old message that came without it.
            ["update_id": 4, "callback_query": ["id": "c", "data": "nav:home", "from": ["id": 42]]],
        ]))
        #expect(updates.map { $0.isFrom(chat: "42") } == [true, false, false, true])
        #expect(!updates[0].isFrom(chat: ""))
    }

    @Test func oldMessagesAreStale() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func message(minutesAgo: Double?) -> BotUpdate {
            BotUpdate(updateID: 1, chatID: "1", fromID: "1", isPrivate: true,
                      date: minutesAgo.map { now.addingTimeInterval(-$0 * 60) }, kind: .message(text: "/report", messageID: nil))
        }
        #expect(!message(minutesAgo: 29).isStale(now: now))
        #expect(message(minutesAgo: 31).isStale(now: now))
        #expect(!message(minutesAgo: nil).isStale(now: now))
    }

    // MARK: Button data

    @Test func routesRoundTrip() {
        let routes: [BotRoute] = BotScreen.allCases.map(BotRoute.show) + [
            .report(ai: true, hours: nil), .report(ai: false, hours: nil), .report(ai: true, hours: 3),
            .cleanupCheck, .cleanupAsk, .cleanupRun, .allCommands, .answer(requestID: "0f3a9c", allow: true),
            .answer(requestID: "0f3a9c", allow: false),
        ]
        for route in routes {
            #expect(BotRoute(data: route.data) == route)
            #expect(route.data.utf8.count <= 64 && route.data.allSatisfy(\.isASCII))
        }
        // The approvals bot's buttons keep working.
        #expect(BotRoute(data: "allow:0f3a9c") == .answer(requestID: "0f3a9c", allow: true))
    }

    @Test func rejectsTamperedData() {
        for data in ["", "nav", "nav:nowhere", "nav:home:x", "rep:ai:0", "rep:ai:169", "rep:ai:three", "cln:rm", "cln",
                     "allow:../../x", "allow:", "drop:0f3a9c", String(repeating: "a", count: 65)] {
            #expect(BotRoute(data: data) == nil, "\(data)")
        }
    }

    /// Only a confirmed cleanup cleans; screens and the confirmation itself do nothing.
    @Test func whatCountsAsAnAction() {
        #expect(!BotRoute.show(.home).isAction && !BotRoute.cleanupAsk.isAction && !BotRoute.allCommands.isAction)
        #expect(BotRoute.cleanupRun.isAction && BotRoute.cleanupCheck.isAction && BotRoute.report(ai: false, hours: nil).isAction)
        #expect(BotRoute.answer(requestID: "a", allow: true).isAction)
    }

    // MARK: The bottom menu

    @Test func bottomMenuStaysAndReadsBack() throws {
        let markup = BotMenu.replyMarkup
        #expect(markup["is_persistent"] as? Bool == true && markup["resize_keyboard"] as? Bool == true)
        let rows = try #require(markup["keyboard"] as? [[[String: String]]])
        #expect(rows.flatMap { $0 }.map { $0["text"] } == ["🏠 Главная", "📊 Отчёты", "🧹 Мак", "❓ Команды"])
        for screen in BotScreen.allCases {
            #expect(BotMenu.screen(forText: BotMenu.title(screen)) == screen)
        }
        #expect(BotMenu.screen(forText: " 🧹 Мак ") == .mac)
        #expect(BotMenu.screen(forText: "Мак") == nil && BotMenu.screen(forText: "/menu") == nil)
    }

    /// A message has inline buttons or the bottom menu, never both.
    @Test func menuCarrierHasNoInlineButtons() {
        var message = BotScreens.home(BotHomeState(macName: "Mac", working: 0, waiting: 0, runs: 0), now: .now)
        #expect(message.replyMarkup["inline_keyboard"] != nil)
        message.installsMenu = true
        #expect(message.replyMarkup["inline_keyboard"] == nil && message.replyMarkup["keyboard"] != nil)
    }

    // MARK: Commands

    @Test func commandsAsInBotPy() {
        #expect(BotCommand(text: "hello") == nil)
        #expect(BotCommand(text: "/menu") == .menu)
        #expect(BotCommand(text: "/start") == .start(code: nil))
        #expect(BotCommand(text: "/start 123456") == .start(code: "123456"))
        #expect(BotCommand(text: "/report") == .report(ai: true, hours: nil))
        #expect(BotCommand(text: "/report@my_bot 3") == .report(ai: true, hours: 3))
        #expect(BotCommand(text: "/status 1,5") == .report(ai: false, hours: 1.5))
        #expect(BotCommand(text: "/report 1000") == .report(ai: true, hours: 168))
        #expect(BotCommand(text: "/report 0") == .report(ai: true, hours: 0.25))
        #expect(BotCommand(text: "/report three") == .badHours)
        #expect(BotCommand(text: "/report nan") == .badHours)
        #expect(BotCommand(text: "/clean") == .clean(check: false))
        #expect(BotCommand(text: "/clean check") == .clean(check: true))
        #expect(BotCommand(text: "/HELP") == .help)
        #expect(BotCommand(text: "/rm") == .unknown)
        #expect(BotCommand.menuList.map(\.command) == ["menu", "report", "status", "clean", "help"])
    }

    // MARK: Screens

    @Test func homeShowsTheMacAndEscapes() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let screen = BotScreens.home(BotHomeState(
            macName: "Mac <mini>",
            session: UsageWindow(key: "five_hour", title: "", utilization: 41.6, resetsAt: now.addingTimeInterval(130 * 60)),
            week: UsageWindow(key: "seven_day", title: "", utilization: 12, resetsAt: nil),
            working: 2, waiting: 1, runs: 3
        ), now: now)
        #expect(screen.html.contains("Mac &lt;mini&gt;"))
        #expect(screen.html.contains("42 %") && screen.html.contains("12 %") && screen.html.contains("2 ч 10 мин"))
        #expect(screen.html.contains("2 работают, 1 ждут") && screen.html.contains("Фоновые задачи: 3"))
        #expect(screen.buttons.flatMap { $0 }.map(\.route) == [.show(.reports), .show(.mac), .show(.home), .show(.help)])
        let rows = try #require(screen.replyMarkup["inline_keyboard"] as? [[[String: String]]])
        #expect(rows.first?.map { $0["callback_data"] } == ["nav:reports", "nav:mac"])
    }

    @Test func homeWithoutLimits() {
        let screen = BotScreens.home(BotHomeState(macName: "Mac", working: 0, waiting: 0, runs: 0), now: .now)
        #expect(screen.html.contains("лимиты ещё не загружены"))
    }

    @Test func reportsScreen() {
        let screen = BotScreens.reports(job: "Готовлю <отчёт>", otherBot: true)
        #expect(screen.html.contains("_daily-report/config.json") && screen.html.contains("Готовлю &lt;отчёт&gt;"))
        #expect(screen.buttons[1].map(\.route) == [.report(ai: true, hours: 1), .report(ai: true, hours: 3), .report(ai: true, hours: 24)])
        #expect(!BotScreens.reports(job: nil, otherBot: false).html.contains("config.json"))
    }

    @Test func cleanupAsksFirst() {
        #expect(BotScreens.mac(freeBytes: nil, job: nil).buttons[0].map(\.route) == [.cleanupCheck, .cleanupAsk])
        #expect(BotScreens.cleanupConfirm.buttons[0].map(\.route) == [.cleanupRun, .show(.mac)])
    }

    @Test func helpOffersAllCommandsWhenThereAreSome() {
        #expect(BotScreens.help(hasAllCommands: true).buttons.first?.first?.route == .allCommands)
        #expect(BotScreens.help(hasAllCommands: false).buttons.flatMap { $0 }.map(\.route) == [.show(.home)])
        #expect(BotScreens.help(hasAllCommands: false).html.contains("/clean"))
    }

    @Test func cleanupOutputIsCutAndEscaped() {
        let output = (1...30).map { "  line <\($0)>" }.joined(separator: "\n")
        let html = BotScreens.cleanupOutput(output)
        #expect(html.hasPrefix("<pre>line &lt;1&gt;\n") && html.contains("line &lt;25&gt;") && !html.contains("line &lt;26&gt;"))
        #expect(html.contains("ещё 5 строк"))
        #expect(BotScreens.cleanupOutput("").contains("нет вывода"))
        #expect(BotScreens.failure("Отчёт не получился", output: "a\nb <c>").contains("<code>a\nb &lt;c&gt;</code>"))
    }

    @Test func hoursSinceTheMorningReport() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        func at(_ hour: Int, _ minute: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: hour, minute: minute)))
        }
        #expect(BotScreens.hoursSinceMorning(now: try at(13, 0), calendar: calendar) == 3)
        // Right after the report and before it: since yesterday's.
        #expect(abs(BotScreens.hoursSinceMorning(now: try at(10, 3), calendar: calendar) - 24.05) < 0.001)
        #expect(BotScreens.hoursSinceMorning(now: try at(8, 0), calendar: calendar) == 22)
        #expect(BotScreens.hoursText(0.5) == "30 мин")
        #expect(BotScreens.hoursText(3) == "3 ч")
        #expect(BotScreens.hoursText(1.5).hasPrefix("1") && BotScreens.hoursText(1.5).hasSuffix("5 ч"))
    }
}
