import Foundation
import IOKit.ps
import Observation

/// The «Telegram» module's bot (docs/specs/SPEC-telegram.md): reads its updates while this Mac answers it, answers only
/// the bound chat, keeps each screen in one message and runs `report.py` / `cleanup.py` like the panel's commands.
/// The token is the send-only bot's (`Telegram.keychainAccount`); it is only in request URLs, never in the log.
@MainActor
@Observable
final class TelegramBotController {
    private(set) var hasToken = false
    private(set) var botName: String?
    private(set) var status: String?
    /// Another reader of this bot answered first (HTTP 409): another Mac or `bot.py`.
    private(set) var conflict = false
    private(set) var isReading = false
    /// «Привязать чат»: the code the `/start` link carries, while it is waited for.
    private(set) var bindingCode: String?
    private(set) var job: String?

    var isActive: () -> Bool = { true }

    private let settings: AppSettings
    private let sessions: SessionStore
    private let runs: RunStore
    private let usage: UsageStore
    private let approvals: TelegramApprovals
    private var token: String?
    private var loop: Task<Void, Never>?
    private var offset: Int?
    private var lastRead: Date?
    private var bindingExpires: Date?
    private var commandsSetFor: String?
    /// Screens opened from the bottom menu, oldest first; a new one replaces them so the chat keeps one or two.
    private var menuScreens: [Int] = []
    /// The latest message that carries the bottom menu: kept while other screens come and go.
    private var menuCarrier: Int?
    private let macName = Host.current().localizedName ?? "Mac"

    init(settings: AppSettings, sessions: SessionStore, runs: RunStore, usage: UsageStore, approvals: TelegramApprovals) {
        self.settings = settings
        self.sessions = sessions
        self.runs = runs
        self.usage = usage
        self.approvals = approvals
    }

    /// The bound chat: the module's own, else the `_daily-report` one (a private chat's id is the person's id, the same
    /// for every bot).
    var chatID: String {
        let own = settings.telegramChatID.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return own }
        return Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory)?.chatID ?? ""
    }

    /// «Этот Мак отвечает боту»: by default a desktop Mac answers and a laptop doesn't (SPEC-telegram §8).
    var answersHere: Bool {
        get { settings.telegramBot.answersHere ?? !Self.hasInternalBattery }
        set { settings.telegramBot.answersHere = newValue }
    }

    /// A bot in `_daily-report/config.json` that isn't this one yet: «Взять бота из _daily-report».
    var dailyReportBotAvailable: Bool {
        !hasToken && Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory) != nil
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.loadToken()
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await tick()
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    /// The approvals bot is this same bot and it is read here (`TelegramApprovals.botReads`).
    func reads(_ token: String) -> Bool { isReading && self.token == token }

    // MARK: - Settings page

    func loadToken() async {
        token = await APIKeyStore.read(account: Telegram.keychainAccount)
        hasToken = token != nil
        await Telegram.loadOwnBot(chatID: settings.telegramChatID)
        await loadName()
    }

    func saveToken(_ value: String) async {
        do {
            try await APIKeyStore.save(value, account: Telegram.keychainAccount, label: "Telegram bot")
            await loadToken()
            status = botName == nil ? String(localized: "Telegram не принял токен") : nil
        } catch {
            status = error.localizedDescription
        }
    }

    func removeToken() async {
        await APIKeyStore.delete(account: Telegram.keychainAccount)
        token = nil
        hasToken = false
        botName = nil
        bindingCode = nil
        status = nil
        conflict = false
        commandsSetFor = nil
        await Telegram.loadOwnBot(chatID: settings.telegramChatID)
    }

    /// Copies the `_daily-report` bot's token and chat here (SPEC-telegram §1, migration).
    func adoptDailyReportBot() async {
        guard let file = Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory) else { return }
        settings.telegramChatID = file.chatID
        await saveToken(file.token)
    }

    /// The `t.me` link whose «Start» sends `/start <code>`; the code lives 10 minutes.
    func startBinding() -> URL? {
        guard let botName else { return nil }
        let code = String(Int.random(in: 100_000...999_999))
        bindingCode = code
        bindingExpires = .now.addingTimeInterval(10 * 60)
        return URL(string: "https://t.me/\(botName.dropFirst())?start=\(code)")
    }

    func cancelBinding() {
        bindingCode = nil
        bindingExpires = nil
    }

    func unbind() {
        settings.telegramChatID = ""
        Task { await Telegram.loadOwnBot(chatID: "") }
    }

    /// «Проверить»: the home screen as a new message.
    func test() async {
        guard let token else { status = String(localized: "Сначала сохраните токен бота"); return }
        guard !chatID.isEmpty else { status = String(localized: "Сначала привяжите чат"); return }
        let ok = await show(.home, tapID: nil, token: token)
        status = ok ? String(localized: "Отправлено") : String(localized: "Бот не может написать в этот чат — откройте его в Telegram и нажмите «Start»")
    }

    // MARK: - The loop

    /// One read of the updates; returns how long to wait before the next one.
    private func tick() async -> Double {
        if let expires = bindingExpires, expires < .now { cancelBinding() }
        guard isActive(), answersHere, let token, !chatID.isEmpty || bindingCode != nil else {
            isReading = false
            return 5
        }
        if commandsSetFor != token {
            commandsSetFor = token
            await setCommands(token: token)
        }
        var parameters: [String: Any] = ["timeout": 25, "allowed_updates": ["message", "callback_query"]]
        if let offset { parameters["offset"] = offset }
        let (code, data) = await Self.call(token, "getUpdates", parameters, timeout: 35)
        switch code {
        case 200:
            break
        case 409:
            conflict = true
            isReading = false
            status = String(localized: "Этого бота уже читает другой Мак или программа")
            return 60
        case 401, 404:
            isReading = false
            status = String(localized: "Telegram не принял токен")
            return 60
        default:
            isReading = false
            return 10
        }
        guard let data else { return 1 }
        if conflict { conflict = false; status = nil }
        isReading = true
        // Presses carry no time: right after a gap (the Mac slept, the app started) they only navigate (§4).
        let afterGap = lastRead.map { Date.now.timeIntervalSince($0) > BotUpdate.maxAge } ?? true
        lastRead = .now
        let (updates, next) = BotUpdate.parse(data)
        if let next { offset = next }
        for update in updates {
            await handle(update, token: token, afterGap: afterGap)
        }
        return 0.2
    }

    private func handle(_ update: BotUpdate, token: String, afterGap: Bool) async {
        if case let .message(text, _) = update.kind, update.isPrivate, let code = bindingCode,
           BotCommand(text: text) == .start(code: code), !update.isStale(now: .now) {
            settings.telegramChatID = update.chatID
            cancelBinding()
            await Telegram.loadOwnBot(chatID: update.chatID)
            AppLog.info("Telegram chat bound")
            _ = await send(BotMessage(html: "✅ " + RunMessage.escape(String(localized: "Чат привязан к AI Hub Bar."))), token: token)
            await show(.home, tapID: nil, token: token)
            return
        }
        // Anyone else who found the bot gets nothing back.
        guard update.isFrom(chat: chatID) else { return }
        switch update.kind {
        case let .message(text, messageID):
            guard !update.isStale(now: .now) else {
                AppLog.info("Telegram: an old command skipped")
                return
            }
            if let screen = BotMenu.screen(forText: text) {
                await show(screen, tapID: messageID, token: token)
                return
            }
            guard let command = BotCommand(text: text) else { return }
            await run(command, token: token)
        case let .press(callbackID, data, messageID):
            guard let route = BotRoute(data: data) else {
                await answerPress(callbackID, String(localized: "Кнопка устарела"), token: token)
                if let messageID { await edit(messageID, homeScreen, token: token) }
                return
            }
            if route.isAction, afterGap {
                await answerPress(callbackID, String(localized: "Устарело — откройте меню заново"), token: token)
                return
            }
            await answerPress(callbackID, nil, token: token)
            await press(route, messageID: messageID, token: token)
        }
    }

    private func run(_ command: BotCommand, token: String) async {
        switch command {
        case .menu, .start:
            await show(.home, tapID: nil, token: token)
        case .help:
            _ = await send(helpScreen, token: token)
        case let .report(ai, hours):
            let id = await send(reportsScreen(job: nil), token: token)
            startReport(ai: ai, hours: hours ?? BotScreens.hoursSinceMorning(now: .now), messageID: id, token: token)
        case let .clean(check):
            if check {
                startCleanup(dryRun: true, messageID: nil, token: token)
            } else {
                _ = await send(BotScreens.cleanupConfirm, token: token)
            }
        case .badHours:
            _ = await send(BotMessage(html: RunMessage.escape(String(localized: "Число часов не понял. Пример: /report 3"))), token: token)
        case .unknown:
            _ = await send(BotMessage(html: RunMessage.escape(String(localized: "Не знаю такой команды. Все команды: /help"))), token: token)
        }
    }

    /// A screen from the bottom menu (or /menu) as a new message at the bottom of the chat. 🏠 carries the menu itself,
    /// so it is set again whenever it is shown; the menu press and the screens before it are deleted (not while a report
    /// or cleanup still edits one). Returns whether it was sent.
    @discardableResult
    private func show(_ screen: BotScreen, tapID: Int?, token: String) async -> Bool {
        var message: BotMessage
        switch screen {
        case .home:
            message = homeScreen
            message.buttons = []
            message.installsMenu = true
        case .reports: message = reportsScreen(job: job)
        case .mac: message = macScreen
        case .help: message = helpScreen
        }
        guard let id = await send(message, token: token) else { return false }
        if let tapID { await delete(tapID, token: token) }
        if job == nil {
            let keep = message.installsMenu ? [] : [menuCarrier].compactMap { $0 }
            for old in menuScreens where !keep.contains(old) { await delete(old, token: token) }
            menuScreens = keep
        }
        if message.installsMenu { menuCarrier = id }
        menuScreens.append(id)
        return true
    }

    private func press(_ route: BotRoute, messageID: Int?, token: String) async {
        let screen: BotMessage
        switch route {
        case .show(.home): screen = homeScreen
        case .show(.reports): screen = reportsScreen(job: job)
        case .show(.mac): screen = macScreen
        case .show(.help): screen = helpScreen
        case .cleanupAsk: screen = BotScreens.cleanupConfirm
        case .allCommands:
            await sendAllCommands(token: token)
            return
        case let .report(ai, hours):
            startReport(ai: ai, hours: hours.map(Double.init) ?? BotScreens.hoursSinceMorning(now: .now), messageID: messageID, token: token)
            return
        case .cleanupCheck, .cleanupRun:
            startCleanup(dryRun: route == .cleanupCheck, messageID: messageID, token: token)
            return
        case let .answer(requestID, allow):
            approvals.answerFromBot(requestID: requestID, allow: allow, messageID: messageID)
            return
        }
        if let messageID { await edit(messageID, screen, token: token) } else { _ = await send(screen, token: token) }
    }

    // MARK: - Reports and cleanup

    private func startReport(ai: Bool, hours: Double, messageID: Int?, token: String) {
        let period = BotScreens.hoursText(hours)
        guard job == nil else {
            Task { _ = await send(BotMessage(html: "⏳ " + RunMessage.escape(String(localized: "Сейчас идёт другая задача, подождите."))), token: token) }
            return
        }
        let title = ai ? String(localized: "Готовлю отчёт за \(period), 1–3 минуты…") : String(localized: "Готовлю быструю сводку за \(period)…")
        job = title
        let directory = settings.dailyReportDirectory
        var arguments = ["--since-hours", String(format: "%.2f", hours), "--no-open"]
        if !ai { arguments += ["--no-ai", "--no-document"] }
        Task {
            if let messageID { await edit(messageID, reportsScreen(job: title), token: token) }
            let result = await Self.runScript("report.py", arguments, in: directory, timeout: .seconds(ai ? 900 : 180))
            job = nil
            let command: CommonCommand = ai ? .reportNow : .quickSummary
            let line = result.map { command.summary(of: $0.output) ?? "" } ?? ""
            let failed = result.map { command.isFailure(exitCode: $0.exitCode, summary: line) } ?? true
            AppLog.info("Telegram report finished\(failed ? " with error" : "")")
            let text = failed
                ? BotScreens.failure(String(localized: "Отчёт не получился"), output: result?.output ?? String(localized: "Не найден report.py в \(directory)"))
                : "✅ " + RunMessage.escape(String(localized: "Отчёт за \(period) отправлен"))
            var screen = reportsScreen(job: nil)
            screen.html = text + "\n\n" + screen.html
            if let messageID { await edit(messageID, screen, token: token) } else { _ = await send(screen, token: token) }
        }
    }

    private func startCleanup(dryRun: Bool, messageID: Int?, token: String) {
        guard job == nil else {
            Task { _ = await send(BotMessage(html: "⏳ " + RunMessage.escape(String(localized: "Сейчас идёт другая задача, подождите."))), token: token) }
            return
        }
        let title = dryRun ? String(localized: "Считаю, что можно удалить…") : String(localized: "Чищу сборки…")
        job = title
        let directory = settings.dailyReportDirectory
        Task {
            if let messageID { await edit(messageID, macScreen, token: token) }
            let result = await Self.runScript("cleanup.py", [dryRun ? "--dry-run" : "--now"], in: directory, timeout: .seconds(dryRun ? 300 : 1800))
            job = nil
            AppLog.info("Telegram cleanup \(dryRun ? "check" : "run") finished")
            let text = result.map { $0.exitCode == 0 ? BotScreens.cleanupOutput($0.output) : BotScreens.failure(String(localized: "Очистка не получилась"), output: $0.output) }
                ?? BotScreens.failure(String(localized: "Очистка не получилась"), output: String(localized: "Не найден cleanup.py в \(directory)"))
            _ = await send(BotMessage(html: text), token: token)
            if let messageID { await edit(messageID, macScreen, token: token) }
        }
    }

    private func sendAllCommands(token: String) async {
        let url = URL(fileURLWithPath: settings.dailyReportDirectory).appending(path: "help.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return }
        // help.txt is Telegram HTML already (≤ 4000 characters, ~/Projects/CLAUDE.md).
        _ = await send(BotMessage(html: String(text.prefix(4000))), token: token)
    }

    /// `python3 <script>` in the `_daily-report` folder; the output without bot tokens. Nil when the script is missing.
    nonisolated private static func runScript(_ name: String, _ arguments: [String], in directory: String, timeout: Duration) async -> (exitCode: Int32, output: String)? {
        let path = (directory as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let result = try? await ProcessRunner.run("/usr/bin/env", ["python3", path] + arguments,
                                                         currentDirectory: URL(fileURLWithPath: directory), timeout: timeout) else {
            return (1, "")
        }
        return (result.exitCode, CommonCommand.redactingTokens(result.stdoutText + result.stderrText))
    }

    // MARK: - Screens

    private var homeScreen: BotMessage {
        let activity = ClaudeActivity(sessions: sessions, runs: runs)
        return BotScreens.home(BotHomeState(
            macName: macName, session: usage.snapshot?.session, week: usage.snapshot?.week,
            working: activity.runningSessions, waiting: sessions.waitingCount, runs: runs.running.count
        ), now: .now)
    }

    private func reportsScreen(job: String?) -> BotMessage {
        let file = Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory)
        return BotScreens.reports(job: job, otherBot: file != nil && file?.token != token)
    }

    private var macScreen: BotMessage {
        let free = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return BotScreens.mac(freeBytes: free, job: job)
    }

    private var helpScreen: BotMessage {
        let file = URL(fileURLWithPath: settings.dailyReportDirectory).appending(path: "help.txt")
        return BotScreens.help(hasAllCommands: FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Telegram

    private func loadName() async {
        guard let token else { return }
        let (code, data) = await Self.call(token, "getMe", [:], timeout: 20)
        let result = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["result"] as? [String: Any]
        botName = code == 200 ? (result?["username"] as? String).map { "@" + $0 } : nil
    }

    private func setCommands(token: String) async {
        let commands = BotCommand.menuList.map { ["command": $0.command, "description": $0.description] }
        _ = await Self.call(token, "setMyCommands", ["commands": commands], timeout: 20)
        _ = await Self.call(token, "setChatMenuButton", ["menu_button": ["type": "commands"]], timeout: 20)
    }

    /// The new message's id.
    private func send(_ message: BotMessage, token: String) async -> Int? {
        var parameters: [String: Any] = ["chat_id": chatID, "text": message.html, "parse_mode": "HTML", "disable_web_page_preview": true]
        if !message.buttons.isEmpty { parameters["reply_markup"] = message.replyMarkup }
        let (_, data) = await Self.call(token, "sendMessage", parameters, timeout: 20)
        let object = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        return (object?["result"] as? [String: Any])?["message_id"] as? Int
    }

    private func edit(_ messageID: Int, _ message: BotMessage, token: String) async {
        _ = await Self.call(token, "editMessageText", [
            "chat_id": chatID, "message_id": messageID, "text": message.html, "parse_mode": "HTML",
            "disable_web_page_preview": true, "reply_markup": message.replyMarkup,
        ], timeout: 20)
    }

    /// Bots may delete messages in a private chat for 48 hours; older ones simply stay.
    private func delete(_ messageID: Int, token: String) async {
        _ = await Self.call(token, "deleteMessage", ["chat_id": chatID, "message_id": messageID], timeout: 20)
    }

    private func answerPress(_ id: String, _ text: String?, token: String) async {
        var parameters: [String: Any] = ["callback_query_id": id]
        if let text { parameters["text"] = text }
        _ = await Self.call(token, "answerCallbackQuery", parameters, timeout: 20)
    }

    /// HTTP status and body. The URL holds the token: errors are logged with the method only; «message is not
    /// modified» (400 on 🔄 with nothing new) is not an error worth a line.
    nonisolated private static func call(_ token: String, _ method: String, _ parameters: [String: Any], timeout: TimeInterval) async -> (Int, Data?) {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { return (0, nil) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200, !(code == 400 && ["editMessageText", "deleteMessage"].contains(method)) { AppLog.error("Telegram \(method) returned HTTP \(code)") }
            return (code, code == 200 ? data : nil)
        } catch {
            if (error as? URLError)?.code != .timedOut { AppLog.error("Telegram \(method) failed") }
            return (0, nil)
        }
    }

    /// A laptop: has an internal battery.
    nonisolated static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
