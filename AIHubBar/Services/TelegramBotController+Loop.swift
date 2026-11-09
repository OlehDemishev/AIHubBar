import Foundation

/// The loop: reading the bot and what each message, command and press does.
extension TelegramBotController {
    // MARK: - The loop

    /// One read of the updates; returns how long to wait before the next one.
    func tick() async -> Double {
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

    func handle(_ update: BotUpdate, afterGap: Bool) async {
        if case let .message(text, _) = update.kind, update.isPrivate, let code = bindingCode,
           BotCommand(text: text) == .start(code: code), !update.isStale(now: .now) {
            settings.telegramChatID = update.chatID
            cancelBinding()
            await reloadOwnBot(update.chatID)
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

    func run(_ command: BotCommand) async {
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
    func show(_ screen: BotScreen, tapID: Int?) async -> Bool {
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

    func press(_ route: BotRoute, messageID: Int?) async {
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
}
