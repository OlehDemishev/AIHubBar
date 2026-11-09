import Foundation

/// Permission requests, sessions, limits and the ⚙️ settings screen.
extension TelegramBotController {
    // MARK: - Sessions, requests, limits (stage 2)

    /// This Mac sends its permission requests to the chat itself: «Присылать запросы разрешений в Telegram» is on and
    /// the bot is set up — then the separate approvals bot (`TelegramApprovals`) steps aside.
    var handlesRequests: Bool {
        isActive() && settings.telegramApprovals && !chatID.isEmpty && (usesSharedBot ? relay.connected : token != nil)
    }

    /// Own bot: a press reaches the Mac that reads the bot, so only that one offers ✅ / ❌. Shared bot: the relay
    /// brings a press back to the Mac that sent the message, but answering needs its own switch (§7).
    var canAnswer: Bool {
        usesSharedBot ? settings.telegramBot.answersOverShared == true : answersHere
    }

    func projectName(_ request: ApprovalRequest) -> String {
        sessions.items.first { $0.id == request.sessionID }?.session.displayProject ?? request.project ?? "Claude"
    }

    /// New requests get a message; answered ones (here, on the Mac or by Claude) lose their buttons.
    func syncRequests() async {
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

    func answer(_ requestID: String, allow: Bool, messageID: Int?) async {
        guard canAnswer, sessions.approvals.values.contains(where: { $0.id == requestID }) else { return }
        answeredHere[requestID] = allow
        sessions.decide(requestID: requestID, allow: allow)
        AppLog.info("Permission \(allow ? "allowed" : "denied") from Telegram")
        // A press on 🤖 or «Подробнее»: that message shows the rest; the request's own message changes in `syncRequests`.
        if let messageID, !sentRequests.values.contains(where: { $0.message == messageID }) {
            await edit(messageID, sessionsScreen)
        }
    }

    func sendRequestDetails(_ id: String) async {
        guard let request = sessions.approvals.values.first(where: { $0.id == id }) else {
            _ = await send(BotMessage(html: "☑️ " + RunMessage.escape(String(localized: "Ответ уже дан"))))
            return
        }
        let item = sessions.items.first { $0.id == request.sessionID }
        _ = await send(BotScreens.requestDetails(request, project: projectName(request), task: item?.session.task,
                                                 folder: item?.session.cwd, canAnswer: canAnswer && answeredHere[id] == nil))
    }

    var sessionsScreen: BotMessage {
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

    var limitsScreen: BotMessage {
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

    func isOn(_ event: BotEvent) -> Bool {
        switch event {
        case .backgroundResults: settings.telegramForBackground
        case .limitAlerts: settings.limitAlertsToTelegram
        case .calendarReminders: settings.calendarRemindersToTelegram
        case .pullRequests: settings.pullRequestAlertsToTelegram
        case .requests: settings.telegramApprovals
        case .weeklySummary: settings.weeklySummary
        }
    }

    func setEvent(_ event: BotEvent, _ on: Bool) {
        switch event {
        case .backgroundResults: settings.telegramForBackground = on
        case .limitAlerts: settings.limitAlertsToTelegram = on
        case .calendarReminders: settings.calendarRemindersToTelegram = on
        case .pullRequests: settings.pullRequestAlertsToTelegram = on
        case .requests: settings.telegramApprovals = on
        case .weeklySummary: settings.weeklySummary = on
        }
    }

    var settingsScreen: BotMessage {
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
}
