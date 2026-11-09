import Foundation

/// The Mini App's calls, through the relay (SPEC-telegram §10).
extension TelegramBotController {
    // MARK: - Mini App (§10)

    /// A call from the Mini App, through the relay; the reply is JSON (`MiniAppReply`).
    func handleApp(_ name: String, _ parameters: Data) async -> Data {
        guard let call = MiniAppCall(action: name, parameters: parameters) else { return MiniAppReply.failure("bad call").json }
        if call.action != .state { AppLog.info("Telegram Mini App: \(name)") }
        return await reply(to: call.action).json
    }

    func project(_ key: String) -> Project? {
        projectList().first { BotRoute.projectKey($0.path) == key }
    }

    func reply(to action: MiniAppCall.Action) async -> MiniAppReply {
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
}
