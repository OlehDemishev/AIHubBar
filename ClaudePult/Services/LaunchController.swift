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
        var projectName: String { target.name }

        init(id: String, command: ClaudeCommand, target: LaunchTarget, launchAt: Date, night: Bool = false) {
            self.id = id
            self.command = command
            self.target = target
            self.launchAt = launchAt
            self.night = night
        }

        enum CodingKeys: String, CodingKey { case id, command, target, launchAt, night }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            command = try c.decode(ClaudeCommand.self, forKey: .command)
            target = try c.decode(LaunchTarget.self, forKey: .target)
            launchAt = try c.decode(Date.self, forKey: .launchAt)
            night = (try? c.decodeIfPresent(Bool.self, forKey: .night)) ?? false
        }
    }

    /// Above this session usage a background run asks first.
    static let backgroundLimitGuard: Double = 90

    private(set) var working: Set<String> = []
    private(set) var messages: [String: Message] = [:]
    /// Commands waiting for «Запустить всё равно», keyed by project path.
    private(set) var pendingConfirmation: [String: (command: ClaudeCommand, mode: LaunchMode)] = [:]
    /// Background commands stopped by the limit guard, keyed by project path.
    private(set) var pendingLimit: [String: (command: ClaudeCommand, target: LaunchTarget, resetsAt: Date?)] = [:]
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

    func launch(_ command: ClaudeCommand, in project: Project, mode: LaunchMode, allowBusyFolder: Bool = false) {
        launch(command, target: project.launchTarget, mode: mode, allowBusyFolder: allowBusyFolder)
    }

    func launch(
        _ command: ClaudeCommand, target: LaunchTarget, mode: LaunchMode,
        allowBusyFolder: Bool = false, skipLimitGuard: Bool = false
    ) {
        let id = target.path
        guard !working.contains(id) else { return }
        messages[id] = nil
        pendingConfirmation[id] = nil
        pendingLimit[id] = nil

        if mode == .background, !skipLimitGuard, let session = usage.snapshot?.session,
           session.utilization > Self.backgroundLimitGuard {
            pendingLimit[id] = (command, target, session.resetsAt)
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
            style: settings.promptStyle
        )
        Task {
            defer { working.remove(id) }
            do {
                switch try await ClaudeLauncher.prepareFolder(request) {
                case let .needsConfirmation(question):
                    pendingConfirmation[id] = (command, mode)
                    messages[id] = Message(text: question)
                case let .ready(folder, worktree):
                    switch mode {
                    case .terminal:
                        try await TerminalLauncher.run(
                            ShellQuote.claudeCommandLine(folder: folder, claude: request.claudePath, prompt: command.prompt(request.style))
                        )
                        AppLog.info("Launched «\(command.title)» in Terminal: \(folder)")
                    case .background:
                        _ = try runs.launch(
                            title: command.title, prompt: command.prompt(request.style), project: target.name,
                            projectPath: target.path, folder: folder, worktreeBranch: worktree?.branch,
                            profile: .code, resultFile: nil, claudePath: request.claudePath
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
        launch(pending.command, in: project, mode: pending.mode, allowBusyFolder: true)
    }

    /// «Запустить всё равно» after the limit warning.
    func launchDespiteLimit(in project: Project) {
        guard let pending = pendingLimit.removeValue(forKey: project.id) else { return }
        launch(pending.command, target: pending.target, mode: .background, skipLimitGuard: true)
    }

    /// «Запустить после сброса»: queued for the reset time + 2 min (spec §2.8).
    func launchAfterReset(in project: Project) {
        guard let pending = pendingLimit.removeValue(forKey: project.id) else { return }
        let launchAt = (pending.resetsAt ?? .now.addingTimeInterval(3600)).addingTimeInterval(120)
        queued.append(QueuedLaunch(id: UUID().uuidString, command: pending.command, target: pending.target, launchAt: launchAt))
        saveQueue()
        messages[project.id] = Message(text: String(localized: "«\(pending.command.title)» запустится в фоне в \(launchAt.formatted(date: .omitted, time: .shortened)), после сброса лимита."))
        AppLog.info("Queued «\(pending.command.title)» for \(pending.target.name) at \(launchAt.ISO8601Format())")
    }

    /// «На ночь»: the run waits for the night start hour (Settings → Claude Code).
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
        if settings.telegramForBackground, let credentials = Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) {
            let html = "🌙 <b>\(RunMessage.escape(summary.title))</b>\n" + batch.map { RunMessage.telegramHTML($0) }.joined(separator: "\n")
            Task { _ = await Telegram.send(html: html, with: credentials) }
        }
        AppLog.info("Night summary: \(batch.count) runs")
    }

    func cancelQueued(_ id: String) {
        queued.removeAll { $0.id == id }
        saveQueue()
    }

    private func launchDueQueued(now: Date = .now) {
        summarizeNight(now: now)
        let due = queued.filter { $0.launchAt <= now }
        guard !due.isEmpty else { return }
        if due.contains(where: \.night), UserDefaults.standard.double(forKey: "nightBatchStart") == 0 {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "nightBatchStart")
        }
        queued.removeAll { $0.launchAt <= now }
        saveQueue()
        for item in due {
            AppLog.info("Starting queued «\(item.command.title)» for \(item.target.name)")
            launch(item.command, target: item.target, mode: .background, allowBusyFolder: false, skipLimitGuard: true)
        }
    }

    func dismissMessage(for project: Project) {
        messages[project.id] = nil
        pendingConfirmation[project.id] = nil
        pendingLimit[project.id] = nil
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
        try? FileManager.default.createDirectory(at: SessionFiles.supportDirectory, withIntermediateDirectories: true)
        try? encoder.encode(queued).write(to: Self.queueURL, options: .atomic)
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
