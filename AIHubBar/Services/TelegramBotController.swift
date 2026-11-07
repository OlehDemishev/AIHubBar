import AppKit
import Foundation
import IOKit.ps
import Observation

/// The «Telegram» module's bot (docs/specs/SPEC-telegram.md): reads its updates while this Mac answers it, answers only
/// the bound chat, keeps each screen in one message and runs `report.py` / `cleanup.py` like the panel's commands.
/// Two ways to the bot (§7): the shared bot through the relay (`TelegramRelay`), or the person's own bot, whose token is
/// the send-only bot's (`Telegram.keychainAccount`) and only in request URLs, never in the log.
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
    /// The current profile (id, name), for its own menu.
    var currentProfile: () -> (id: String, name: String)? = { nil }
    /// 🚀: the profile's git projects, and the launcher that starts a task in one (like «Своя задача…»).
    var projectList: () -> [Project] = { [] }
    weak var launcher: LaunchController?
    /// «Не спать»: whether it holds the Mac now (nil — the module isn't installed), and for an hour or off.
    var keepAwakeState: () -> Bool? = { nil }
    var setKeepAwake: (Bool) -> Void = { _ in }
    /// Every AI service's limits, as the panel's «Лимиты AI» shows them.
    var limitServices: () -> [ServiceUsage] = { [] }
    /// Runs a quick command and returns how it went (`QuickToolsController.runForBot`).
    var runCommand: (QuickCommand) async -> (ok: Bool, text: String) = { _ in (false, "") }

    /// The shared bot's connection; used while `usesSharedBot`.
    let relay = TelegramRelay()

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
    /// The menu last sent to the chat, to send it again when the profile changes it.
    private var sentMenu: [BotMenuItem]?
    /// Permission requests sent to the chat: request id → its message.
    private var sentRequests: [String: (message: Int, request: ApprovalRequest, project: String)] = [:]
    /// Answered from the chat, until the request is gone: request id → allowed.
    private var answeredHere: [String: Bool] = [:]
    /// A request whose message didn't go out, and when to try again.
    private var retryRequests: [String: Date] = [:]
    private var requestLoop: Task<Void, Never>?
    /// 🚀 being set up: the project, then the task text once typed; it lapses after 10 minutes.
    private var taskDraft: (path: String, name: String, text: String?, until: Date)?
    /// «Подключить Telegram» was pressed here: greet the chat once it is paired.
    private var greetWhenPaired = false
    private let macName = Host.current().localizedName ?? "Mac"

    init(settings: AppSettings, sessions: SessionStore, runs: RunStore, usage: UsageStore, approvals: TelegramApprovals) {
        self.settings = settings
        self.sessions = sessions
        self.runs = runs
        self.usage = usage
        self.approvals = approvals
    }

    /// «Общий бот»: the setting, else the shared bot unless an own bot is already set up.
    var usesSharedBot: Bool {
        get { (settings.telegramBot.shared ?? !hasToken) && relay.baseURL != nil }
        set { settings.telegramBot.shared = newValue }
    }

    /// The bound chat: the shared bot's paired one; the own bot's, else the `_daily-report` one (a private chat's id is
    /// the person's id, the same for every bot).
    var chatID: String {
        if usesSharedBot { return relay.chat ?? "" }
        let own = settings.telegramChatID.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return own }
        return Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory)?.chatID ?? ""
    }

    /// «Этот Мак отвечает боту». Own bot: by default a desktop Mac answers and a laptop doesn't (SPEC-telegram §9).
    /// Shared bot: the Worker decides — the last paired Mac, or the one that took over here or with /macs.
    var answersHere: Bool {
        get { usesSharedBot ? relay.answering : settings.telegramBot.answersHere ?? !Self.hasInternalBattery }
        set {
            if usesSharedBot { relay.setAnswering(newValue) } else { settings.telegramBot.answersHere = newValue }
        }
    }

    /// A bot in `_daily-report/config.json` that isn't this one yet: «Взять бота из _daily-report».
    var dailyReportBotAvailable: Bool {
        !hasToken && Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory) != nil
    }

    func start() {
        guard loop == nil else { return }
        relay.onApp = { [weak self] name, parameters in
            await self?.handleApp(name, parameters) ?? MiniAppReply.failure("gone").json
        }
        requestLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncRequests()
                try? await Task.sleep(for: .seconds(1))
            }
        }
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

    /// «Подключить Telegram» (shared bot): opens the bot with a one-time code.
    func connectShared() async {
        guard let link = await relay.pairLink() else {
            status = String(localized: "Нет связи с общим ботом")
            return
        }
        status = nil
        greetWhenPaired = true
        NSWorkspace.shared.open(link)
    }

    /// «Отключить» (shared bot): this Mac leaves the chat.
    func disconnectShared() {
        relay.unpair()
        Telegram.shared = nil
    }

    /// «Проверить»: the home screen as a new message.
    func test() async {
        guard usesSharedBot || token != nil else { status = String(localized: "Сначала сохраните токен бота"); return }
        guard !chatID.isEmpty else { status = String(localized: "Сначала привяжите чат"); return }
        let ok = await show(.home, tapID: nil)
        status = ok ? String(localized: "Отправлено") : String(localized: "Бот не может написать в этот чат — откройте его в Telegram и нажмите «Start»")
    }

    // MARK: - The loop

    /// One read of the updates; returns how long to wait before the next one.
    private func tick() async -> Double {
        if usesSharedBot { return await sharedTick() }
        if relay.isRunning {
            relay.stop()
            Telegram.shared = nil
        }
        if let expires = bindingExpires, expires < .now { cancelBinding() }
        guard isActive(), answersHere, let token, !chatID.isEmpty || bindingCode != nil else {
            isReading = false
            return 5
        }
        if commandsSetFor != token {
            commandsSetFor = token
            await setCommands()
        }
        var parameters: [String: Any] = ["timeout": 25, "allowed_updates": ["message", "callback_query"]]
        if let offset { parameters["offset"] = offset }
        let (code, data) = await api("getUpdates", parameters, timeout: 35)
        switch code {
        case 200:
            break
        case 409:
            conflict = true
            isReading = false
            status = String(localized: "Этого бота уже читает другой Mac или программа")
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
            await handle(update, afterGap: afterGap)
        }
        return 0.2
    }

    /// The shared bot: the relay pushes the updates; this waits for them like `getUpdates` would.
    private func sharedTick() async -> Double {
        guard isActive() else {
            if relay.isRunning { relay.stop() }
            isReading = false
            Telegram.shared = nil
            return 5
        }
        relay.start(name: macName)
        botName = relay.bot.map { "@" + $0 }
        // Notifications of every module go through the shared bot while this Mac is paired.
        if relay.chat == nil {
            Telegram.shared = nil
        } else if Telegram.shared == nil {
            Telegram.shared = { @MainActor [weak self] (html: String) async -> Bool in
                guard let self else { return false }
                return await self.send(BotMessage(html: html)) != nil
            }
        }
        guard relay.connected, relay.chat != nil else {
            isReading = false
            if !relay.connected, let error = relay.lastError { status = error }
            return 2
        }
        if status == relay.lastError ?? String(localized: "Нет связи с общим ботом") { status = nil }
        if greetWhenPaired {
            greetWhenPaired = false
            AppLog.info("Telegram: paired with the shared bot")
            _ = await send(BotMessage(html: "✅ " + RunMessage.escape(String(localized: "Чат привязан к AI Hub Bar."))))
            await show(.home, tapID: nil)
        }
        isReading = relay.answering
        let data = await relay.nextUpdates(timeout: 25)
        let afterGap = lastRead.map { Date.now.timeIntervalSince($0) > BotUpdate.maxAge } ?? true
        lastRead = .now
        for update in BotUpdate.parse(data).updates {
            await handle(update, afterGap: afterGap)
        }
        return 0
    }

    private func handle(_ update: BotUpdate, afterGap: Bool) async {
        if case let .message(text, _) = update.kind, update.isPrivate, let code = bindingCode,
           BotCommand(text: text) == .start(code: code), !update.isStale(now: .now) {
            settings.telegramChatID = update.chatID
            cancelBinding()
            await Telegram.loadOwnBot(chatID: update.chatID)
            AppLog.info("Telegram chat bound")
            _ = await send(BotMessage(html: "✅ " + RunMessage.escape(String(localized: "Чат привязан к AI Hub Bar."))))
            await show(.home, tapID: nil)
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
            if await takeTaskText(text) { return }
            switch currentMenu.item(forText: text) {
            case let .screen(screen)?:
                await show(screen, tapID: messageID)
                return
            case let .command(id)?:
                if let messageID { await delete(messageID) }
                await askOrRun(id)
                return
            case nil:
                break
            }
            guard let command = BotCommand(text: text) else { return }
            await run(command)
        case let .press(callbackID, data, messageID):
            guard let route = BotRoute(data: data) else {
                await answerPress(callbackID, String(localized: "Кнопка устарела"))
                if let messageID { await edit(messageID, homeScreen) }
                return
            }
            if route.isAction, afterGap {
                await answerPress(callbackID, String(localized: "Устарело — откройте меню заново"))
                return
            }
            await answerPress(callbackID, nil)
            await press(route, messageID: messageID)
        }
    }

    private func run(_ command: BotCommand) async {
        switch command {
        case .menu, .start:
            await show(.home, tapID: nil)
        case .cancel:
            taskDraft = nil
            _ = await send(BotMessage(html: "✖️ " + RunMessage.escape(String(localized: "Отменено"))))
        case .help:
            _ = await send(helpScreen)
        case let .report(ai, hours):
            let id = await send(reportsScreen(job: nil))
            startReport(ai: ai, hours: hours ?? BotScreens.hoursSinceMorning(now: .now, hour: morningHour ?? 10), messageID: id)
        case let .clean(check):
            if check {
                startCleanup(dryRun: true, messageID: nil)
            } else {
                _ = await send(BotScreens.cleanupConfirm)
            }
        case .badHours:
            _ = await send(BotMessage(html: RunMessage.escape(String(localized: "Число часов не понял. Пример: /report 3"))))
        case .unknown:
            _ = await send(BotMessage(html: RunMessage.escape(String(localized: "Не знаю такой команды. Все команды: /help"))))
        }
    }

    /// A screen from the bottom menu (or /menu) as a new message at the bottom of the chat. 🏠 carries the menu itself,
    /// so it is set again whenever it is shown; the menu press and the screens before it are deleted (not while a report
    /// or cleanup still edits one). Returns whether it was sent.
    @discardableResult
    private func show(_ screen: BotScreen, tapID: Int?) async -> Bool {
        var message: BotMessage
        switch screen {
        case .home:
            message = homeScreen
            // «Где меню» → only the Menu button: 🏠 keeps its own buttons, no keyboard at the bottom.
            if settings.telegramBot.bottomMenu != false {
                message.buttons = []
                message.menu = currentMenu
                sentMenu = currentMenu.entries.map(\.item)
            }
        case .reports: message = reportsScreen(job: job)
        case .mac: message = macScreen
        case .help: message = helpScreen
        case .menu: message = menuScreen
        case .sessions: message = sessionsScreen
        case .limits: message = limitsScreen
        case .task: message = taskScreen
        case .settings: message = settingsScreen
        }
        guard let id = await send(message) else { return false }
        if let tapID { await delete(tapID) }
        if job == nil {
            let keep = message.installsMenu ? [] : [menuCarrier].compactMap { $0 }
            for old in menuScreens where !keep.contains(old) { await delete(old) }
            menuScreens = keep
        }
        if message.installsMenu { menuCarrier = id }
        menuScreens.append(id)
        return true
    }

    private func press(_ route: BotRoute, messageID: Int?) async {
        let screen: BotMessage
        switch route {
        case .show(.home): screen = homeScreen
        case .show(.reports): screen = reportsScreen(job: job)
        case .show(.mac): screen = macScreen
        case .show(.help): screen = helpScreen
        case .show(.menu): screen = menuScreen
        case .show(.sessions): screen = sessionsScreen
        case .show(.limits): screen = limitsScreen
        case .show(.task):
            taskDraft = nil
            screen = taskScreen
        case .show(.settings): screen = settingsScreen
        case let .event(event):
            setEvent(event, !isOn(event))
            screen = settingsScreen
        case let .quiet(hours):
            settings.telegramBot.quietHours = hours
            screen = settingsScreen
        case let .mute(on):
            settings.telegramBot.mutedUntil = on ? .now.addingTimeInterval(3600) : nil
            screen = settingsScreen
        case let .keepAwake(on):
            setKeepAwake(on)
            AppLog.info("Telegram: keep awake \(on ? "on for an hour" : "off")")
            screen = macScreen
        case let .taskProject(key):
            guard tasksAllowed, let project = projectList().first(where: { BotRoute.projectKey($0.path) == key }) else {
                screen = taskScreen
                break
            }
            taskDraft = (project.path, project.name, nil, .now.addingTimeInterval(10 * 60))
            screen = BotScreens.taskAskText(project: project.name)
        case .taskCancel:
            taskDraft = nil
            screen = taskScreen
        case .taskGo, .taskForce, .taskAfterReset, .taskWorktree:
            await launchTask(route, messageID: messageID)
            return
        case let .runLog(id):
            guard let run = runs.run(id: id) else { screen = taskScreen; break }
            let text = (try? String(contentsOf: run.logURL, encoding: .utf8)) ?? ""
            screen = BotScreens.runLog(runLine(run), entries: StreamJSON.entries(fromLog: text))
        case let .runStopAsk(id):
            guard tasksAllowed, let run = runs.run(id: id), run.state == .running else { screen = taskScreen; break }
            screen = BotScreens.runStopConfirm(runLine(run))
        case let .runStop(id):
            if tasksAllowed, runs.run(id: id)?.state == .running {
                runs.stop(id)
                AppLog.info("Telegram: background run stopped")
            }
            screen = taskScreen
        case let .limitAlerts(on):
            settings.limitAlertsToTelegram = on
            screen = limitsScreen
        case let .requestDetails(id):
            await sendRequestDetails(id)
            return
        case let .menuToggle(item):
            editMenu { $0.toggle(item) }
            screen = menuScreen
        case let .menuColumns(columns):
            editMenu { $0.columns = columns }
            screen = menuScreen
        case .menuDone:
            if let messageID { await delete(messageID) }
            await show(.home, tapID: nil)
            return
        case let .runCommand(id):
            if let messageID { await delete(messageID) }
            await run(commandID: id)
            return
        case .cleanupAsk: screen = BotScreens.cleanupConfirm
        case .allCommands:
            await sendAllCommands()
            return
        case let .report(ai, hours):
            startReport(ai: ai, hours: hours.map(Double.init) ?? BotScreens.hoursSinceMorning(now: .now, hour: morningHour ?? 10), messageID: messageID)
            return
        case .cleanupCheck, .cleanupRun:
            startCleanup(dryRun: route == .cleanupCheck, messageID: messageID)
            return
        case let .answer(requestID, allow):
            guard handlesRequests else {
                approvals.answerFromBot(requestID: requestID, allow: allow, messageID: messageID)
                return
            }
            await answer(requestID, allow: allow, messageID: messageID)
            return
        }
        if let messageID { await edit(messageID, screen) } else { _ = await send(screen) }
    }

    // MARK: - Sessions, requests, limits (stage 2)

    /// This Mac sends its permission requests to the chat itself: «Присылать запросы разрешений в Telegram» is on and
    /// the bot is set up — then the separate approvals bot (`TelegramApprovals`) steps aside.
    var handlesRequests: Bool {
        isActive() && settings.telegramApprovals && !chatID.isEmpty && (usesSharedBot ? relay.connected : token != nil)
    }

    /// Own bot: a press reaches the Mac that reads the bot, so only that one offers ✅ / ❌. Shared bot: the relay
    /// brings a press back to the Mac that sent the message, but answering needs its own switch (§7).
    private var canAnswer: Bool {
        usesSharedBot ? settings.telegramBot.answersOverShared == true : answersHere
    }

    private func projectName(_ request: ApprovalRequest) -> String {
        sessions.items.first { $0.id == request.sessionID }?.session.displayProject ?? request.project ?? "Claude"
    }

    /// New requests get a message; answered ones (here, on the Mac or by Claude) lose their buttons.
    private func syncRequests() async {
        guard handlesRequests else { return }
        let open = Array(sessions.approvals.values).sorted { $0.created < $1.created }
        for request in open where sentRequests[request.id] == nil && (retryRequests[request.id] ?? .distantPast) < .now {
            let project = projectName(request)
            if let message = await send(BotScreens.request(request, project: project, canAnswer: canAnswer)) {
                sentRequests[request.id] = (message, request, project)
                retryRequests[request.id] = nil
            } else {
                retryRequests[request.id] = .now.addingTimeInterval(30)
            }
        }
        for (id, entry) in sentRequests where !open.contains(where: { $0.id == id }) {
            sentRequests[id] = nil
            await edit(entry.message, BotScreens.requestClosed(entry.request, project: entry.project, outcome: answeredHere.removeValue(forKey: id)))
        }
        retryRequests = retryRequests.filter { id, _ in open.contains { $0.id == id } }
    }

    private func answer(_ requestID: String, allow: Bool, messageID: Int?) async {
        guard canAnswer, sessions.approvals.values.contains(where: { $0.id == requestID }) else { return }
        answeredHere[requestID] = allow
        sessions.decide(requestID: requestID, allow: allow)
        AppLog.info("Permission \(allow ? "allowed" : "denied") from Telegram")
        // A press on 🤖 or «Подробнее»: that message shows the rest; the request's own message changes in `syncRequests`.
        if let messageID, !sentRequests.values.contains(where: { $0.message == messageID }) {
            await edit(messageID, sessionsScreen)
        }
    }

    private func sendRequestDetails(_ id: String) async {
        guard let request = sessions.approvals.values.first(where: { $0.id == id }) else {
            _ = await send(BotMessage(html: "☑️ " + RunMessage.escape(String(localized: "Ответ уже дан"))))
            return
        }
        let item = sessions.items.first { $0.id == request.sessionID }
        _ = await send(BotScreens.requestDetails(request, project: projectName(request), task: item?.session.task,
                                                 folder: item?.session.cwd, canAnswer: canAnswer && answeredHere[id] == nil))
    }

    private var sessionsScreen: BotMessage {
        let lines = sessions.items.filter { $0.state == .waiting || $0.state == .running }.map { item in
            BotSessionLine(
                project: item.session.displayProject, agent: item.session.agentName, waiting: item.state == .waiting,
                detail: item.state == .waiting ? (item.session.message ?? item.session.task) : (item.session.actionText ?? item.session.task),
                since: item.session.updatedAt
            )
        }
        let requests = sessions.approvals.values.filter { answeredHere[$0.id] == nil }.sorted { $0.created < $1.created }
            .map { BotRequestLine(id: $0.id, project: projectName($0), tool: $0.tool, summary: $0.summary) }
        return BotScreens.sessions(lines, requests: requests, canAnswer: canAnswer && handlesRequests, now: .now)
    }

    private var limitsScreen: BotMessage {
        let services = limitServices().map { usage in
            BotLimitService(
                title: usage.title,
                windows: (usage.rings + usage.bars).map {
                    BotLimitService.Window(title: $0.title, percent: $0.percent, detail: $0.detail,
                                           resetsAt: $0.showsReset ? $0.resetsAt : nil, runsOutAt: $0.runsOutAt)
                },
                error: usage.error, isStale: usage.isStale
            )
        }
        return BotScreens.limits(services, alertsOn: settings.limitAlertsToTelegram, thresholds: settings.limitThresholds, now: .now)
    }

    // MARK: - ⚙️ Settings (stage 4)

    private func isOn(_ event: BotEvent) -> Bool {
        switch event {
        case .backgroundResults: settings.telegramForBackground
        case .limitAlerts: settings.limitAlertsToTelegram
        case .calendarReminders: settings.calendarRemindersToTelegram
        case .pullRequests: settings.pullRequestAlertsToTelegram
        case .requests: settings.telegramApprovals
        case .weeklySummary: settings.weeklySummary
        }
    }

    private func setEvent(_ event: BotEvent, _ on: Bool) {
        switch event {
        case .backgroundResults: settings.telegramForBackground = on
        case .limitAlerts: settings.limitAlertsToTelegram = on
        case .calendarReminders: settings.calendarRemindersToTelegram = on
        case .pullRequests: settings.pullRequestAlertsToTelegram = on
        case .requests: settings.telegramApprovals = on
        case .weeklySummary: settings.weeklySummary = on
        }
    }

    private var settingsScreen: BotMessage {
        BotScreens.settings(events: BotEvent.allCases.map { ($0, isOn($0)) }, quiet: settings.telegramBot.quietHours,
                            mutedUntil: settings.telegramBot.mutedUntil, morningHour: morningHour, now: .now)
    }

    /// The hour `_daily-report`'s morning report runs at: its launchd agent's `StartCalendarInterval`, found by its
    /// `report.py` in the profile's folder. Nil without one.
    var morningHour: Int? {
        let agents = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
        let script = (settings.dailyReportDirectory as NSString).appendingPathComponent("report.py")
        for file in (try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "plist" {
            guard let plist = NSDictionary(contentsOf: file),
                  (plist["ProgramArguments"] as? [String])?.contains(where: { $0 == script || $0.hasSuffix("/_daily-report/report.py") && $0 == script }) == true
            else { continue }
            let interval = plist["StartCalendarInterval"]
            let first = (interval as? [String: Any]) ?? (interval as? [[String: Any]])?.first
            if let hour = first?["Hour"] as? Int { return hour }
        }
        return nil
    }

    // MARK: - 🚀 Tasks and runs (stage 3)

    /// Over the shared bot only with «Задачи через общий бот» (§7).
    private var tasksAllowed: Bool {
        !usesSharedBot || settings.telegramBot.tasksOverShared == true
    }

    private var taskScreen: BotMessage {
        let projects = projectList()
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .map { BotTaskProject(key: BotRoute.projectKey($0.path), name: $0.name) }
        let recent = runs.runs.filter { $0.state == .running || ($0.finishedAt ?? .distantPast) > .now.addingTimeInterval(-86_400) }
            .sorted { $0.startedAt > $1.startedAt }
            .map(runLine)
        return BotScreens.task(projects: projects, runs: recent, locked: !tasksAllowed, now: .now)
    }

    private func runLine(_ run: BackgroundRun) -> BotRunLine {
        BotRunLine(id: run.id, project: run.project, task: run.task, state: run.state, paused: run.isPaused,
                   startedAt: run.startedAt, pullRequestURL: run.pullRequestURL)
    }

    /// A message while 🚀 waits for the task: it becomes the task (shown back with «Запустить»). Commands and menu
    /// presses go their usual way.
    private func takeTaskText(_ text: String) async -> Bool {
        guard let draft = taskDraft, draft.text == nil else { return false }
        guard draft.until > .now else {
            taskDraft = nil
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), currentMenu.item(forText: trimmed) == nil else { return false }
        taskDraft?.text = trimmed
        _ = await send(BotScreens.taskConfirm(project: draft.name, text: trimmed))
        return true
    }

    /// «Запустить», and the answers to the launcher's questions; then how it went, in the same message.
    private func launchTask(_ route: BotRoute, messageID: Int?) async {
        guard tasksAllowed, let draft = taskDraft, let text = draft.text,
              let project = projectList().first(where: { $0.path == draft.path }),
              let outcome = await startTask(route, project: project, text: text) else {
            if let messageID { await edit(messageID, taskScreen) }
            return
        }
        let reply: BotMessage = switch outcome {
        case let .question(text, limit): BotScreens.taskQuestion(text, limit: limit)
        case let .done(text, isError):
            BotMessage(html: (isError ? "❌ " : "✅ ") + RunMessage.escape(text),
                       buttons: [[BotMessage.Button(title: "🚀 " + String(localized: "Задача"), route: .show(.task))]])
        }
        if let messageID { await edit(messageID, reply) } else { _ = await send(reply) }
    }

    enum TaskOutcome {
        case question(String, limit: Bool)
        case done(String, isError: Bool)
    }

    /// Starts the task (or answers the launcher's question) and waits for how it went; the bot and the Mini App show it.
    private func startTask(_ route: BotRoute, project: Project, text: String) async -> TaskOutcome? {
        guard let launcher else { return nil }
        switch route {
        case .taskForce: launcher.launchDespiteLimit(in: project)
        case .taskAfterReset: launcher.launchAfterReset(in: project)
        case .taskWorktree: launcher.confirmPending(in: project)
        default: launcher.launch(.customTask(text), in: project, mode: .background)
        }
        AppLog.info("Telegram: task sent to \(project.name)")
        // The launcher works in the background: wait for its answer for the project (a minute at most).
        for _ in 0..<120 where launcher.working.contains(project.path) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let message = launcher.messages[project.path], launcher.pendingLimit[project.path] != nil {
            return .question(message.text, limit: true)
        }
        if let message = launcher.messages[project.path], launcher.pendingConfirmation[project.path] != nil {
            return .question(message.text, limit: false)
        }
        taskDraft = nil
        let message = launcher.messages[project.path]
        let text = route == .taskAfterReset
            ? String(localized: "Запустится после сброса лимита.")
            : message?.text ?? String(localized: "Задача отправлена.")
        return .done(text, isError: message?.isError == true)
    }

    // MARK: - Mini App (§10)

    /// A call from the Mini App, through the relay; the reply is JSON (`MiniAppReply`).
    func handleApp(_ name: String, _ parameters: Data) async -> Data {
        guard let call = MiniAppCall(action: name, parameters: parameters) else { return MiniAppReply.failure("bad call").json }
        if call.action != .state { AppLog.info("Telegram Mini App: \(name)") }
        return await reply(to: call.action).json
    }

    private func project(_ key: String) -> Project? {
        projectList().first { BotRoute.projectKey($0.path) == key }
    }

    private func reply(to action: MiniAppCall.Action) async -> MiniAppReply {
        var note: String?
        switch action {
        case .state:
            break
        case let .answer(id, allow):
            guard canAnswer else { return .failure(String(localized: "Отвечать отсюда нельзя — включите на Mac «Ответы на запросы через общий бот».")) }
            await answer(id, allow: allow, messageID: nil)
            note = allow ? String(localized: "Разрешено") : String(localized: "Отклонено")
        case let .report(ai, hours):
            guard job == nil else { return .failure(String(localized: "Сейчас идёт другая задача, подождите.")) }
            startReport(ai: ai, hours: hours ?? BotScreens.hoursSinceMorning(now: .now, hour: morningHour ?? 10), messageID: nil)
            note = String(localized: "Итог придёт в чат")
        case let .cleanup(run):
            guard job == nil else { return .failure(String(localized: "Сейчас идёт другая задача, подождите.")) }
            startCleanup(dryRun: !run, messageID: nil)
            note = String(localized: "Итог придёт в чат")
        case let .task(key, text):
            guard tasksAllowed else { return .failure(String(localized: "Задачи через общий бот выключены. На Mac: Настройки → Модули → Telegram → «Задачи через общий бот».")) }
            guard let project = project(key) else { return .failure(String(localized: "Проект не найден")) }
            taskDraft = (project.path, project.name, text, .now.addingTimeInterval(10 * 60))
            return outcomeReply(await startTask(.taskGo, project: project, text: text), project: key)
        case let .taskForce(key), let .taskAfterReset(key), let .taskWorktree(key):
            guard tasksAllowed, let project = project(key), let draft = taskDraft, draft.path == project.path, let text = draft.text else {
                return .failure(String(localized: "Проект не найден"))
            }
            let route: BotRoute = switch action {
            case .taskForce: .taskForce
            case .taskAfterReset: .taskAfterReset
            default: .taskWorktree
            }
            return outcomeReply(await startTask(route, project: project, text: text), project: key)
        case let .stopRun(id):
            guard tasksAllowed else { return .failure(String(localized: "Задачи через общий бот выключены. На Mac: Настройки → Модули → Telegram → «Задачи через общий бот».")) }
            if runs.run(id: id)?.state == .running {
                runs.stop(id)
                note = String(localized: "Остановлено")
            }
        case let .log(id):
            guard let run = runs.run(id: id) else { return .failure(String(localized: "Задача не найдена")) }
            let text = (try? String(contentsOf: run.logURL, encoding: .utf8)) ?? ""
            return MiniAppReply(ok: true, log: MiniAppReply.logLines(StreamJSON.entries(fromLog: text)))
        case let .command(id):
            guard !usesSharedBot || settings.telegramBot.commandsOverShared == true else {
                return .failure(String(localized: "Быстрые команды через общий бот выключены. На Mac: Настройки → Модули → Telegram → «Быстрые команды через общий бот»."))
            }
            guard let command = settings.quickCommands.first(where: { $0.id == id }) else { return .failure(String(localized: "Команда не найдена")) }
            AppLog.info("Telegram Mini App: quick command started")
            let result = await runCommand(command)
            return MiniAppReply(ok: result.ok, error: result.ok ? nil : result.text, note: result.ok ? result.text : nil, state: miniAppState)
        case let .event(event, on):
            setEvent(event, on)
        case let .quiet(hours):
            settings.telegramBot.quietHours = hours
        case let .mute(on):
            settings.telegramBot.mutedUntil = on ? .now.addingTimeInterval(3600) : nil
        case let .keepAwake(on):
            setKeepAwake(on)
        }
        return MiniAppReply(ok: true, note: note, state: miniAppState)
    }

    private func outcomeReply(_ outcome: TaskOutcome?, project: String) -> MiniAppReply {
        switch outcome {
        case let .question(text, limit)?:
            MiniAppReply(ok: true, state: miniAppState, question: .init(text: text, limit: limit, project: project))
        case let .done(text, isError)?:
            MiniAppReply(ok: !isError, error: isError ? text : nil, note: isError ? nil : text, state: miniAppState)
        case nil:
            .failure(String(localized: "Проект не найден"))
        }
    }

    var miniAppState: MiniAppState {
        let free = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let report = URL(fileURLWithPath: settings.dailyReportDirectory).appending(path: "report.py")
        return MiniAppState(
            mac: macName, freeBytes: free, keepAwake: keepAwakeState(), job: job,
            sessions: sessions.items.filter { $0.state == .waiting || $0.state == .running }.map { item in
                MiniAppState.Session(
                    project: item.session.displayProject, agent: item.session.agentName, waiting: item.state == .waiting,
                    detail: item.state == .waiting ? (item.session.message ?? item.session.task) : (item.session.actionText ?? item.session.task),
                    since: item.session.updatedAt
                )
            },
            requests: sessions.approvals.values.filter { answeredHere[$0.id] == nil }.sorted { $0.created < $1.created }.map { request in
                MiniAppState.Request(id: request.id, project: projectName(request), tool: request.tool, summary: request.summary,
                                     task: sessions.items.first { $0.id == request.sessionID }?.session.task)
            },
            canAnswer: canAnswer,
            services: limitServices().map { usage in
                MiniAppState.Service(
                    title: usage.title,
                    windows: (usage.rings + usage.bars).map {
                        MiniAppState.Window(title: $0.title, percent: $0.percent, detail: $0.detail,
                                            resetsAt: $0.showsReset ? $0.resetsAt : nil, runsOutAt: $0.runsOutAt)
                    },
                    error: usage.error, stale: usage.isStale
                )
            },
            projects: projectList().sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
                .map { MiniAppState.Project(key: BotRoute.projectKey($0.path), name: $0.name) },
            runs: runs.runs.filter { $0.state == .running || ($0.finishedAt ?? .distantPast) > .now.addingTimeInterval(-86_400) }
                .sorted { $0.startedAt > $1.startedAt }
                .map { MiniAppState.Run(id: $0.id, project: $0.project, task: $0.task, state: $0.state.rawValue, paused: $0.isPaused,
                                        startedAt: $0.startedAt, pr: $0.pullRequestURL) },
            tasksAllowed: tasksAllowed,
            commands: settings.quickCommands.map { MiniAppState.Command(id: $0.id, title: $0.title, confirm: $0.confirm) },
            commandsAllowed: !usesSharedBot || settings.telegramBot.commandsOverShared == true,
            events: BotEvent.allCases.map { MiniAppState.Event(id: $0.rawValue, title: $0.title, on: isOn($0)) },
            quiet: settings.telegramBot.quietHours, quietPresets: QuietHours.presets,
            mutedUntil: settings.telegramBot.mutedUntil.flatMap { $0 > .now ? $0 : nil },
            hasDailyReport: FileManager.default.fileExists(atPath: report.path)
        )
    }

    // MARK: - The menu and quick commands

    /// The menu at the bottom for the current profile.
    var currentMenu: BotMenu {
        BotMenu(settings.telegramBot.menu(for: currentProfile()?.id), commands: settings.quickCommands)
    }

    /// The menu the bot's ⚙️ edits: the current profile's own, if it has one, else the common one.
    private var editedProfile: String? {
        currentProfile().flatMap { settings.telegramBot.hasOwnMenu($0.id) ? $0.id : nil }
    }

    private func editMenu(_ change: (inout BotMenuConfig) -> Void) {
        var config = settings.telegramBot.menu(for: editedProfile)
        change(&config)
        settings.telegramBot.setMenu(config, for: editedProfile)
    }

    private var menuScreen: BotMessage {
        let profile = editedProfile.flatMap { _ in currentProfile()?.name }
        return BotScreens.menuSetup(settings.telegramBot.menu(for: editedProfile), commands: settings.quickCommands, profile: profile)
    }

    /// The profile changed: if its menu differs from the one in the chat, 🏠 brings the new one.
    func profileChanged() {
        guard isActive(), answersHere, !chatID.isEmpty, let sentMenu, sentMenu != currentMenu.entries.map(\.item) else { return }
        Task { await show(.home, tapID: nil) }
    }

    /// «Где меню» changed: the keyboard at the bottom comes back with 🏠, or goes away with a note where the menu is.
    func applyMenuPlacement() async {
        guard !chatID.isEmpty else { return }
        if settings.telegramBot.bottomMenu == false {
            var note = BotMessage(html: "☰ " + RunMessage.escape(usesSharedBot
                ? String(localized: "Меню — в кнопке «Меню» слева от поля ввода: там всё приложение.")
                : String(localized: "Меню — в кнопке «Меню» слева от поля ввода.")))
            note.removesMenu = true
            _ = await send(note)
            sentMenu = nil
        } else {
            await show(.home, tapID: nil)
        }
    }

    /// «Обновить меню в Telegram» in Settings.
    func refreshMenu() async {
        guard !chatID.isEmpty else { status = String(localized: "Сначала привяжите чат"); return }
        status = await show(.home, tapID: nil) ? String(localized: "Отправлено") : String(localized: "Не отправилось: проверьте токен и ID чата")
    }

    /// A quick command from the menu: over the shared bot only with its switch on, and then always asked first (§7);
    /// otherwise asked first when the command says so.
    private func askOrRun(_ id: String) async {
        guard let command = settings.quickCommands.first(where: { $0.id == id }) else { return }
        if usesSharedBot, settings.telegramBot.commandsOverShared != true {
            _ = await send(BotMessage(html: "🔒 " + RunMessage.escape(String(localized: "Быстрые команды через общий бот выключены. На Mac: Настройки → Модули → Telegram → «Быстрые команды через общий бот»."))))
            return
        }
        if command.confirm || usesSharedBot {
            _ = await send(BotScreens.confirmCommand(command))
        } else {
            await run(commandID: id)
        }
    }

    private func run(commandID id: String) async {
        guard let command = settings.quickCommands.first(where: { $0.id == id }) else { return }
        if usesSharedBot, settings.telegramBot.commandsOverShared != true { return }
        AppLog.info("Telegram: quick command started")
        Task {
            let result = await runCommand(command)
            _ = await send(BotMessage(html: BotScreens.commandResult(command, ok: result.ok, text: result.text)))
        }
    }

    // MARK: - Reports and cleanup

    private func startReport(ai: Bool, hours: Double, messageID: Int?) {
        let period = BotScreens.hoursText(hours)
        guard job == nil else {
            Task { _ = await send(BotMessage(html: "⏳ " + RunMessage.escape(String(localized: "Сейчас идёт другая задача, подождите.")))) }
            return
        }
        let title = ai ? String(localized: "Готовлю отчёт за \(period), 1–3 минуты…") : String(localized: "Готовлю быструю сводку за \(period)…")
        job = title
        let directory = settings.dailyReportDirectory
        var arguments = ["--since-hours", String(format: "%.2f", hours), "--no-open"]
        if !ai { arguments += ["--no-ai", "--no-document"] }
        Task {
            if let messageID { await edit(messageID, reportsScreen(job: title)) }
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
            if let messageID { await edit(messageID, screen) } else { _ = await send(screen) }
        }
    }

    private func startCleanup(dryRun: Bool, messageID: Int?) {
        guard job == nil else {
            Task { _ = await send(BotMessage(html: "⏳ " + RunMessage.escape(String(localized: "Сейчас идёт другая задача, подождите.")))) }
            return
        }
        let title = dryRun ? String(localized: "Считаю, что можно удалить…") : String(localized: "Чищу сборки…")
        job = title
        let directory = settings.dailyReportDirectory
        Task {
            if let messageID { await edit(messageID, macScreen) }
            let result = await Self.runScript("cleanup.py", [dryRun ? "--dry-run" : "--now"], in: directory, timeout: .seconds(dryRun ? 300 : 1800))
            job = nil
            AppLog.info("Telegram cleanup \(dryRun ? "check" : "run") finished")
            let text = result.map { $0.exitCode == 0 ? BotScreens.cleanupOutput($0.output) : BotScreens.failure(String(localized: "Очистка не получилась"), output: $0.output) }
                ?? BotScreens.failure(String(localized: "Очистка не получилась"), output: String(localized: "Не найден cleanup.py в \(directory)"))
            _ = await send(BotMessage(html: text))
            if let messageID { await edit(messageID, macScreen) }
        }
    }

    private func sendAllCommands() async {
        let url = URL(fileURLWithPath: settings.dailyReportDirectory).appending(path: "help.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return }
        // help.txt is Telegram HTML already (≤ 4000 characters, ~/Projects/CLAUDE.md).
        _ = await send(BotMessage(html: String(text.prefix(4000))))
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
        return BotScreens.reports(job: job, otherBot: file != nil && (usesSharedBot || file?.token != token))
    }

    private var macScreen: BotMessage {
        let free = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return BotScreens.mac(freeBytes: free, job: job, keepAwake: keepAwakeState())
    }

    private var helpScreen: BotMessage {
        let file = URL(fileURLWithPath: settings.dailyReportDirectory).appending(path: "help.txt")
        return BotScreens.help(hasAllCommands: FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Telegram

    private func loadName() async {
        guard token != nil else { return }
        let (code, data) = await api("getMe", [:], timeout: 20)
        let result = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["result"] as? [String: Any]
        botName = code == 200 ? (result?["username"] as? String).map { "@" + $0 } : nil
    }

    private func setCommands() async {
        let commands = BotCommand.menuList.map { ["command": $0.command, "description": $0.description] }
        _ = await api("setMyCommands", ["commands": commands], timeout: 20)
        _ = await api("setChatMenuButton", ["menu_button": ["type": "commands"]], timeout: 20)
    }

    /// The new message's id.
    private func send(_ message: BotMessage) async -> Int? {
        var parameters: [String: Any] = ["chat_id": chatID, "text": message.html, "parse_mode": "HTML", "disable_web_page_preview": true]
        if message.installsMenu || message.removesMenu || !message.buttons.isEmpty { parameters["reply_markup"] = message.replyMarkup }
        let (_, data) = await api("sendMessage", parameters, timeout: 20)
        let object = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        return (object?["result"] as? [String: Any])?["message_id"] as? Int
    }

    private func edit(_ messageID: Int, _ message: BotMessage) async {
        _ = await api("editMessageText", [
            "chat_id": chatID, "message_id": messageID, "text": message.html, "parse_mode": "HTML",
            "disable_web_page_preview": true, "reply_markup": message.replyMarkup,
        ], timeout: 20)
    }

    /// Bots may delete messages in a private chat for 48 hours; older ones simply stay.
    private func delete(_ messageID: Int) async {
        _ = await api("deleteMessage", ["chat_id": chatID, "message_id": messageID], timeout: 20)
    }

    private func answerPress(_ id: String, _ text: String?) async {
        var parameters: [String: Any] = ["callback_query_id": id]
        if let text { parameters["text"] = text }
        _ = await api("answerCallbackQuery", parameters, timeout: 20)
    }

    /// A Telegram method through the shared bot or straight to the own one.
    private func api(_ method: String, _ parameters: [String: Any], timeout: TimeInterval) async -> (Int, Data?) {
        if usesSharedBot { return await relay.call(method, parameters) }
        guard let token else { return (0, nil) }
        return await Self.call(token, method, body: try? JSONSerialization.data(withJSONObject: parameters), timeout: timeout)
    }

    /// HTTP status and body. The URL holds the token: errors are logged with the method only; «message is not
    /// modified» (400 on 🔄 with nothing new) is not an error worth a line.
    nonisolated private static func call(_ token: String, _ method: String, body: Data?, timeout: TimeInterval) async -> (Int, Data?) {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { return (0, nil) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
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
