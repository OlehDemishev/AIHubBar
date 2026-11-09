import Foundation

/// 🚀 Tasks: a project, the task as a message, the launcher's questions.
extension TelegramBotController {
    // MARK: - 🚀 Tasks and runs (stage 3)

    /// Over the shared bot only with «Задачи через общий бот» (§7).
    var tasksAllowed: Bool {
        !usesSharedBot || settings.telegramBot.tasksOverShared == true
    }

    var taskScreen: BotMessage {
        let projects = projectList()
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .map { BotTaskProject(key: BotRoute.projectKey($0.path), name: $0.name) }
        let recent = runs.runs.filter { $0.state == .running || ($0.finishedAt ?? .distantPast) > .now.addingTimeInterval(-86_400) }
            .sorted { $0.startedAt > $1.startedAt }
            .map(runLine)
        return BotScreens.task(projects: projects, runs: recent, locked: !tasksAllowed, now: .now)
    }

    func runLine(_ run: BackgroundRun) -> BotRunLine {
        BotRunLine(id: run.id, project: run.project, task: run.task, state: run.state, paused: run.isPaused,
                   startedAt: run.startedAt, pullRequestURL: run.pullRequestURL)
    }

    /// A message while 🚀 waits for the task: it becomes the task (shown back with «Запустить»). Commands and menu
    /// presses go their usual way.
    func takeTaskText(_ text: String) async -> Bool {
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
    func launchTask(_ route: BotRoute, messageID: Int?) async {
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
    func startTask(_ route: BotRoute, project: Project, text: String) async -> TaskOutcome? {
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
}
