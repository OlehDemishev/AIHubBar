import AppKit
import Observation

/// UI state for launching Claude and removing worktrees, per project.
@MainActor
@Observable
final class LaunchController {
    struct Message: Equatable {
        var text: String
        var isError = false
    }

    enum WorktreeState: Equatable {
        case checking
        case confirm
        case removing
        case blocked(String)
    }

    /// What a launch needs from a project; Codable so a launch can wait for a limit reset across restarts.
    struct LaunchTarget: Codable, Equatable, Sendable {
        var path: String
        var name: String
        var nextItems: [String]
        var baseRef: String
    }

    /// A background run postponed until the session limit resets (spec §2.8).
    struct QueuedLaunch: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var command: ClaudeCommand
        var target: LaunchTarget
        var launchAt: Date
        /// Queued «на ночь»: part of the batch that gets a morning summary.
        var night = false
        /// Waits for the session limit to reset: if the limit is still full at `launchAt`, it waits for the next reset.
        var afterReset = false
        /// The run goes to Codex (`codex exec`) and waits for Codex's limits, not Claude's.
        var codexPath: String? = nil
        var projectName: String { target.name }

        init(id: String, command: ClaudeCommand, target: LaunchTarget, launchAt: Date, night: Bool = false, afterReset: Bool = false,
             codexPath: String? = nil) {
            self.codexPath = codexPath
            self.id = id
            self.command = command
            self.target = target
            self.launchAt = launchAt
            self.night = night
            self.afterReset = afterReset
        }

        enum CodingKeys: String, CodingKey { case id, command, target, launchAt, night, afterReset, codexPath }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            command = try c.decode(ClaudeCommand.self, forKey: .command)
            target = try c.decode(LaunchTarget.self, forKey: .target)
            launchAt = try c.decode(Date.self, forKey: .launchAt)
            night = (try? c.decodeIfPresent(Bool.self, forKey: .night)) ?? false
            afterReset = (try? c.decodeIfPresent(Bool.self, forKey: .afterReset)) ?? false
            codexPath = try? c.decodeIfPresent(String.self, forKey: .codexPath)
        }
    }

    /// Above this session usage a background run asks first.
    static let backgroundLimitGuard: Double = 90

    private(set) var working: Set<String> = []
    private(set) var messages: [String: Message] = [:]
    /// Commands waiting for «Запустить всё равно», keyed by project path.
    private(set) var pendingConfirmation: [String: (command: ClaudeCommand, mode: LaunchMode, codexPath: String?)] = [:]
    /// Background commands stopped by the limit guard, keyed by project path.
    private(set) var pendingLimit: [String: (command: ClaudeCommand, target: LaunchTarget, resetsAt: Date?, codexPath: String?)] = [:]
    /// Codex's limits as the panel shows them (the first is its 5 hours); set by the app, empty without Codex.
    var codexLimits: () -> [LimitWindow] = { [] }
    /// Where `codex` is, nil when it is not installed; set by the app.
    var codexPath: () -> String? = { nil }
    /// Commands waiting for the Terminal / Фон choice, keyed by project path.
    private(set) var pendingModeChoice: [String: ClaudeCommand] = [:]
    private(set) var worktreeStates: [String: WorktreeState] = [:]
    private(set) var queued: [QueuedLaunch] = []

    private let settings: AppSettings
    private let store: ProjectStore
    private let runs: RunStore
    private let usage: UsageStore
    private var queueTimer: Task<Void, Never>?

    private static var queueURL: URL { SessionFiles.supportDirectory.appending(path: "queue.json") }

    init(settings: AppSettings, store: ProjectStore, runs: RunStore, usage: UsageStore) {
        self.settings = settings
        self.store = store
        self.runs = runs
        self.usage = usage
        queued = Self.loadQueue()
    }

    /// Starts queued runs when their time comes.
    func start() {
        guard queueTimer == nil else { return }
        queueTimer = Task { [weak self] in
            while !Task.isCancelled {
                self?.guardRuns()
                self?.launchDueQueued()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Entry point from the panel: uses the default mode from Settings, or asks.
    func request(_ command: ClaudeCommand, in project: Project) {
        messages[project.id] = nil
        pendingConfirmation[project.id] = nil
        pendingLimit[project.id] = nil
        if let mode = settings.defaultLaunchMode {
            launch(command, in: project, mode: mode)
        } else {
            pendingModeChoice[project.id] = command
        }
    }

    func choose(_ mode: LaunchMode, remember: Bool, in project: Project) {
        guard let command = pendingModeChoice.removeValue(forKey: project.id) else { return }
        if remember { settings.defaultLaunchMode = mode }
        launch(command, in: project, mode: mode)
    }

    func cancelModeChoice(in project: Project) {
        pendingModeChoice[project.id] = nil
    }

    func launch(_ command: ClaudeCommand, in project: Project, mode: LaunchMode, allowBusyFolder: Bool = false, codexPath: String? = nil) {
        launch(command, target: project.launchTarget, mode: mode, allowBusyFolder: allowBusyFolder, codexPath: codexPath)
    }

    /// `codexPath` — the task goes to Codex in the background (`codex exec`) instead of Claude; Claude's session
    /// limit is then not this run's concern.
    func launch(
        _ command: ClaudeCommand, target: LaunchTarget, mode: LaunchMode,
        allowBusyFolder: Bool = false, skipLimitGuard: Bool = false, codexPath: String? = nil
    ) {
        let id = target.path
        guard !working.contains(id) else { return }
        messages[id] = nil
        pendingConfirmation[id] = nil
        pendingLimit[id] = nil

        if mode == .background, !skipLimitGuard, codexPath != nil,
           let window = codexLimits().first(where: { ($0.percent ?? 0) > Self.backgroundLimitGuard }) {
            pendingLimit[id] = (command, target, window.resetsAt, codexPath)
            let reset = window.resetsAt.map { String(localized: ", сброс в \($0.formatted(date: .omitted, time: .shortened))") } ?? ""
            messages[id] = Message(text: String(localized: "\(AgentKind.codex.title): \(window.title) использовано на \(UsageText.percent(window.percent ?? 0))\(reset). Фоновая задача может упереться в лимит."))
            return
        }
        if mode == .background, !skipLimitGuard, codexPath == nil, let session = usage.snapshot?.session,
           session.utilization > Self.backgroundLimitGuard {
            pendingLimit[id] = (command, target, session.resetsAt, nil)
            let reset = session.resetsAt.map { String(localized: ", сброс в \($0.formatted(date: .omitted, time: .shortened))") } ?? ""
            messages[id] = Message(text: String(localized: "Сессия использована на \(UsageText.percent(session.utilization))\(reset). Фоновая задача может упереться в лимит."))
            return
        }

        working.insert(id)
        let request = LaunchRequest(
            command: command,
            projectPath: target.path,
            nextItems: target.nextItems,
            baseRef: target.baseRef,
            claudePath: ClaudeLocator.resolve(configured: settings.claudePath),
            allowBusyFolder: allowBusyFolder,
            style: settings.promptStyle,
            rulesFile: PathText.tilde(settings.projectsDirectory + "/CLAUDE.md")
        )
        Task {
            defer { working.remove(id) }
            do {
                switch try await ClaudeLauncher.prepareFolder(request) {
                case let .needsConfirmation(question):
                    pendingConfirmation[id] = (command, mode, codexPath)
                    messages[id] = Message(text: question)
                case let .ready(folder, worktree):
                    switch mode {
                    case .terminal:
                        try await TerminalLauncher.run(
                            ShellQuote.claudeCommandLine(folder: folder, claude: request.claudePath, prompt: command.prompt(request.style, rulesFile: request.rulesFile))
                        )
                        AppLog.info("Launched «\(command.title)» in Terminal: \(folder)")
                    case .background:
                        _ = try runs.launch(
                            title: command.title, prompt: command.prompt(request.style, rulesFile: request.rulesFile), project: target.name,
                            projectPath: target.path, folder: folder, worktreeBranch: worktree?.branch,
                            profile: .code, resultFile: nil, claudePath: request.claudePath, codexPath: codexPath
                        )
                    }
                    messages[id] = Message(text: Self.launchedText(command, mode: mode, worktree: worktree, limit: settings.backgroundTimeLimitMinutes))
                    if worktree != nil { await store.refresh() }
                }
            } catch {
                messages[id] = Message(text: error.localizedDescription, isError: true)
                AppLog.error("Launch «\(command.title)» in \(target.name) failed: \(error.localizedDescription)")
            }
        }
    }

    static func launchedText(_ command: ClaudeCommand, mode: LaunchMode, worktree: WorktreePlan?, limit: Int) -> String {
        var text = mode == .terminal
            ? String(localized: "«\(command.title)» запущен в новом окне Терминала.")
            : String(localized: "«\(command.title)» запущен в фоне (лимит \(limit) мин). Итог придёт уведомлением.")
        if let worktree {
            text = String(localized: "В папке проекта уже работает Claude, поэтому запуск идёт в worktree cb-\(worktree.slug) (ветка \(worktree.branch)). ") + text
        }
        return text
    }

    func confirmPending(in project: Project) {
        guard let pending = pendingConfirmation[project.id] else { return }
        launch(pending.command, in: project, mode: pending.mode, allowBusyFolder: true, codexPath: pending.codexPath)
    }

    /// «Запустить всё равно» after the limit warning.
    func launchDespiteLimit(in project: Project) {
        guard let pending = pendingLimit.removeValue(forKey: project.id) else { return }
        launch(pending.command, target: pending.target, mode: .background, skipLimitGuard: true, codexPath: pending.codexPath)
    }

    /// «В Codex» after Claude's limit warning: the same task goes to Codex in the background.
    var canHandOverPending: Bool { codexPath() != nil }

    func handOverPending(in project: Project) {
        guard let pending = pendingLimit[project.id], pending.codexPath == nil, let path = codexPath() else { return }
        pendingLimit[project.id] = nil
        AppLog.info("Handing «\(pending.command.title)» for \(pending.target.name) to Codex: Claude is near its limit")
        launch(pending.command, target: pending.target, mode: .background, codexPath: path)
    }

    /// «Передать Codex» on a Claude run that is paused by the limit or ended badly: the run stops and Codex goes on
    /// in the same folder (the worktree included) with the same task and a word about the work already there.
    func handOver(_ run: BackgroundRun) {
        guard Handover.canHandOver(run), let task = run.prompt, let path = codexPath() else { return }
        if run.state == .running { runs.stop(run.id) }
        do {
            _ = try runs.launch(
                title: run.commandTitle, prompt: Handover.prompt(task: task, from: run.agentTitle), project: run.project,
                projectPath: run.projectPath, folder: run.folder, worktreeBranch: run.worktreeBranch,
                profile: .code, resultFile: run.resultFile, claudePath: path, taskTitle: run.task, codexPath: path
            )
            messages[run.projectPath] = Message(text: String(localized: "«\(run.task)» передана \(AgentKind.codex.title): продолжит в той же папке."))
            AppLog.info("Run \(run.id) handed to Codex in \(run.folder)")
        } catch {
            messages[run.projectPath] = Message(text: error.localizedDescription, isError: true)
        }
    }

    /// «Проверить в Codex / Claude» on a finished run: the other service reads the changes in the run's folder.
    func canReview(_ run: BackgroundRun) -> Bool {
        CrossReview.canReview(run, runs: runs.runs) && run.prompt?.isEmpty == false
            && (!CrossReview.reviewerIsCodex(run) || codexPath() != nil)
    }

    func review(_ run: BackgroundRun) {
        guard canReview(run), let task = run.prompt else { return }
        let codex = CrossReview.reviewerIsCodex(run) ? codexPath() : nil
        do {
            _ = try runs.launch(
                title: String(localized: "Проверка"), prompt: CrossReview.prompt(task: task, author: run.agentTitle),
                project: run.project, projectPath: run.projectPath, folder: run.folder, worktreeBranch: run.worktreeBranch,
                profile: .code, resultFile: nil, claudePath: ClaudeLocator.resolve(configured: settings.claudePath),
                taskTitle: String(localized: "Проверка: \(run.task)"), codexPath: codex, reviewOf: run.id
            )
            AppLog.info("Review of run \(run.id) started by \(codex == nil ? "claude" : "codex")")
        } catch {
            messages[run.projectPath] = Message(text: error.localizedDescription, isError: true)
        }
    }

    /// «Запустить после сброса»: queued for the reset time + 2 min (spec §2.8).
    func launchAfterReset(in project: Project) {
        guard let pending = pendingLimit.removeValue(forKey: project.id) else { return }
        queueAfterReset(pending.command, target: pending.target, resetsAt: pending.resetsAt, codexPath: pending.codexPath)
    }

    /// «После сброса лимита» from the commands: whatever the usage now, the run waits for the session reset.
    func queueAfterReset(_ command: ClaudeCommand, in project: Project) {
        messages[project.id] = nil
        queueAfterReset(command, target: project.launchTarget, resetsAt: usage.snapshot?.session?.resetsAt)
    }

    private func queueAfterReset(_ command: ClaudeCommand, target: LaunchTarget, resetsAt: Date?, codexPath: String? = nil) {
        let launchAt = (resetsAt ?? .now.addingTimeInterval(3600)).addingTimeInterval(120)
        queued.append(QueuedLaunch(id: UUID().uuidString, command: command, target: target, launchAt: launchAt, afterReset: true, codexPath: codexPath))
        saveQueue()
        messages[target.path] = Message(text: String(localized: "«\(command.title)» запустится в фоне в \(launchAt.formatted(date: .omitted, time: .shortened)), после сброса лимита."))
        AppLog.info("Queued «\(command.title)» for \(target.name) after the reset, at \(launchAt.ISO8601Format())")
    }

    // MARK: - Limit guard

    /// The window that holds background work right now (Settings → Модули → Лимиты), nil when nothing holds.
    var guardHold: RunGuard.Hold? { RunGuard.hold(usage.snapshot, threshold: settings.runGuardPercent) }
    /// Runs the person resumed by hand: the guard leaves them alone until they finish.
    private var guardExempt: Set<String> = []

    /// Pauses running background runs near the limit and resumes them after the reset; one notification each way.
    /// Each service's limits hold its own runs: Claude's hold `claude -p`, Codex's hold `codex exec`.
    private func guardRuns(now: Date = .now) {
        guardRuns(codex: false, hold: RunGuard.hold(usage.snapshot, threshold: settings.runGuardPercent, now: now))
        guardRuns(codex: true, hold: RunGuard.hold(codexLimits(), threshold: settings.runGuardPercent, now: now))
    }

    private func guardRuns(codex: Bool, hold: RunGuard.Hold?) {
        let mine: (BackgroundRun) -> Bool = { ($0.agent == CodexExec.agent) == codex }
        let name = codex ? "\(AgentKind.codex.title) · " : ""
        if let hold {
            let paused = runs.running.filter { $0.pausedAt == nil && mine($0) && !guardExempt.contains($0.id) }
            guard !paused.isEmpty else { return }
            paused.forEach { runs.pause($0.id) }
            let until = hold.resetsAt.map { String(localized: " Продолжу после сброса в \($0.formatted(date: .omitted, time: .shortened)).") } ?? ""
            let title = String(localized: "Фоновые задачи на паузе: \(name + hold.title) \(UsageText.percent(hold.utilization))")
            let body = paused.map { "\($0.project): \($0.commandTitle)" }.joined(separator: "\n") + until
            Notifier.post(id: codex ? "run-guard-codex" : "run-guard", title: title, body: body)
            sendToTelegram("⏸ <b>\(RunMessage.escape(title))</b>\n\(RunMessage.escape(body))")
        } else {
            let paused = runs.paused.filter(mine)
            guard !paused.isEmpty else { return }
            paused.forEach { runs.resume($0.id) }
            let title = String(localized: "Лимит сбросился: фоновые задачи продолжают работу")
            let body = paused.map { "\($0.project): \($0.commandTitle)" }.joined(separator: "\n")
            Notifier.post(id: codex ? "run-guard-codex" : "run-guard", title: title, body: body)
            sendToTelegram("▶️ <b>\(RunMessage.escape(title))</b>\n\(RunMessage.escape(body))")
        }
    }

    /// «Продолжить сейчас» on a paused run.
    func resumeNow(_ id: String) {
        guardExempt.insert(id)
        runs.resume(id)
    }

    private func sendToTelegram(_ html: String) {
        Telegram.notify(.backgroundResults, html: html, settings: settings)
    }

    /// «На ночь»: the run waits for the night start hour (Settings → «Сервисы AI» → Claude Code).
    func queueForNight(_ command: ClaudeCommand, in project: Project) {
        let launchAt = NightQueue.nextStart(hour: settings.nightStartHour)
        queued.append(QueuedLaunch(id: UUID().uuidString, command: command, target: project.launchTarget, launchAt: launchAt, night: true))
        saveQueue()
        messages[project.id] = Message(text: String(localized: "«\(command.title)» запустится ночью в \(launchAt.formatted(date: .omitted, time: .shortened)). Утром придёт сводка."))
        AppLog.info("Queued «\(command.title)» for \(project.name) for the night at \(launchAt.ISO8601Format())")
    }

    /// When the night's runs are all finished: one notification (and Telegram, like other background results).
    private func summarizeNight(now: Date = .now) {
        let key = "nightBatchStart"
        let stamp = UserDefaults.standard.double(forKey: key)
        guard stamp > 0, runs.running.isEmpty else { return }
        let start = Date(timeIntervalSince1970: stamp)
        guard now.timeIntervalSince(start) > 60 else { return }
        UserDefaults.standard.removeObject(forKey: key)
        let batch = runs.runs.filter { $0.startedAt >= start.addingTimeInterval(-5) && $0.state.isFinished }
        guard !batch.isEmpty else { return }
        let summary = NightQueue.summary(batch)
        Notifier.post(id: "night-summary", title: summary.title, body: summary.body)
        let html = "🌙 <b>\(RunMessage.escape(summary.title))</b>\n" + batch.map { RunMessage.telegramHTML($0) }.joined(separator: "\n")
        Telegram.notify(.backgroundResults, html: html, settings: settings)
        AppLog.info("Night summary: \(batch.count) runs")
    }

    func cancelQueued(_ id: String) {
        queued.removeAll { $0.id == id }
        saveQueue()
    }

    private func launchDueQueued(now: Date = .now) {
        summarizeNight(now: now)
        postponeHeld(now: now)
        // One run per project a tick: `launch` drops a second one for a project it is already starting, and that
        // run would be gone from the queue with no word. The others stay due and start on the next ticks.
        let due = Self.dueNow(queued, busy: working, now: now)
        guard !due.isEmpty else { return }
        if due.contains(where: \.night), UserDefaults.standard.double(forKey: "nightBatchStart") == 0 {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "nightBatchStart")
        }
        let started = Set(due.map(\.id))
        queued.removeAll { started.contains($0.id) }
        saveQueue()
        for item in due {
            AppLog.info("Starting queued «\(item.command.title)» for \(item.target.name)")
            launch(item.command, target: item.target, mode: .background, allowBusyFolder: false, skipLimitGuard: true, codexPath: item.codexPath)
        }
    }

    /// What starts on this tick: the due runs, one per project, none for a project that is being started.
    nonisolated static func dueNow(_ queued: [QueuedLaunch], busy: Set<String>, now: Date) -> [QueuedLaunch] {
        var taken = busy
        return queued.filter { $0.launchAt <= now && taken.insert($0.target.path).inserted }
    }

    func dismissMessage(for project: Project) {
        messages[project.id] = nil
        pendingConfirmation[project.id] = nil
        pendingLimit[project.id] = nil
    }

    /// Due runs that would only hit the limit wait for the next reset: everything while the guard holds, and
    /// «после сброса» runs while the session is still above the launch warning.
    private func postponeHeld(now: Date) {
        let claudeHold = RunGuard.hold(usage.snapshot, threshold: settings.runGuardPercent, now: now)
        let codexWindows = codexLimits()
        let codexHold = RunGuard.hold(codexWindows, threshold: settings.runGuardPercent, now: now)
        let session = usage.snapshot?.session
        var changed = false
        for index in queued.indices where queued[index].launchAt <= now {
            let codex = queued[index].codexPath != nil
            // The window a «после сброса» run waits for: Claude's session, or Codex's first limit.
            let first: (percent: Double, reset: Date?)? = codex
                ? codexWindows.first.flatMap { window in window.percent.map { ($0, window.resetsAt) } }
                : session.map { ($0.utilization, $0.resetsAt) }
            if let hold = codex ? codexHold : claudeHold {
                queued[index].launchAt = hold.retryAt(now: now)
            } else if queued[index].afterReset, let first, first.percent > Self.backgroundLimitGuard,
                      let reset = first.reset, reset > now {
                queued[index].launchAt = reset.addingTimeInterval(120)
            } else {
                continue
            }
            changed = true
            AppLog.info("Queued «\(queued[index].command.title)» waits for the limit: now \(queued[index].launchAt.ISO8601Format())")
        }
        if changed { saveQueue() }
    }

    private static func loadQueue() -> [QueuedLaunch] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: queueURL) else { return [] }
        return (try? decoder.decode([QueuedLaunch].self, from: data)) ?? []
    }

    private func saveQueue() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        AppLog.attempt("Night queue not saved") {
            try FileManager.default.createDirectory(at: SessionFiles.supportDirectory, withIntermediateDirectories: true)
            try encoder.encode(queued).write(to: Self.queueURL, options: .atomic)
        }
    }

    /// First click checks that the worktree is clean and pushed, the second removes it.
    func removeWorktree(_ worktree: Worktree, of project: Project) {
        switch worktreeStates[worktree.path] {
        case .checking, .removing:
            return
        case .confirm:
            worktreeStates[worktree.path] = .removing
            Task {
                do {
                    try await GitService.removeWorktree(worktree.path, projectPath: project.path)
                    worktreeStates[worktree.path] = nil
                    await store.refresh()
                } catch {
                    worktreeStates[worktree.path] = .blocked(error.localizedDescription)
                }
            }
        case nil, .blocked:
            worktreeStates[worktree.path] = .checking
            Task {
                switch await GitService.removalCheck(worktreePath: worktree.path, baseRef: project.defaultBranch ?? "origin/main") {
                case .allowed: worktreeStates[worktree.path] = .confirm
                case let .blocked(reason): worktreeStates[worktree.path] = .blocked(reason)
                }
            }
        }
    }

    func cancelWorktreeRemoval(_ worktree: Worktree) {
        worktreeStates[worktree.path] = nil
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension Project {
    var launchTarget: LaunchController.LaunchTarget {
        LaunchController.LaunchTarget(
            path: path, name: name,
            nextItems: status?.summary?.next ?? [],
            baseRef: defaultBranch ?? "origin/main"
        )
    }
}
