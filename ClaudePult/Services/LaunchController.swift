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

    private(set) var working: Set<String> = []
    private(set) var messages: [String: Message] = [:]
    /// Commands waiting for «Запустить всё равно», keyed by project path.
    private(set) var pendingConfirmation: [String: (command: ClaudeCommand, mode: LaunchMode)] = [:]
    /// Commands waiting for the Terminal / Фон choice, keyed by project path.
    private(set) var pendingModeChoice: [String: ClaudeCommand] = [:]
    private(set) var worktreeStates: [String: WorktreeState] = [:]

    private let settings: AppSettings
    private let store: ProjectStore
    private let runs: RunStore

    init(settings: AppSettings, store: ProjectStore, runs: RunStore) {
        self.settings = settings
        self.store = store
        self.runs = runs
    }

    /// Entry point from the panel: uses the default mode from Settings, or asks.
    func request(_ command: ClaudeCommand, in project: Project) {
        messages[project.id] = nil
        pendingConfirmation[project.id] = nil
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
        guard !working.contains(project.id) else { return }
        working.insert(project.id)
        messages[project.id] = nil
        pendingConfirmation[project.id] = nil

        let request = LaunchRequest(
            command: command,
            projectPath: project.path,
            nextItems: project.status?.summary?.next ?? [],
            baseRef: project.defaultBranch ?? "origin/main",
            claudePath: ClaudeLocator.resolve(configured: settings.claudePath),
            allowBusyFolder: allowBusyFolder
        )
        Task {
            defer { working.remove(project.id) }
            do {
                switch try await ClaudeLauncher.prepareFolder(request) {
                case let .needsConfirmation(question):
                    pendingConfirmation[project.id] = (command, mode)
                    messages[project.id] = Message(text: question)
                case let .ready(folder, worktree):
                    switch mode {
                    case .terminal:
                        try await TerminalLauncher.run(
                            ShellQuote.claudeCommandLine(folder: folder, claude: request.claudePath, prompt: command.prompt)
                        )
                        AppLog.info("Launched «\(command.title)» in Terminal: \(folder)")
                    case .background:
                        _ = try runs.launch(
                            command: command, project: project.name, projectPath: project.path, folder: folder,
                            worktreeBranch: worktree?.branch, claudePath: request.claudePath
                        )
                    }
                    messages[project.id] = Message(text: Self.launchedText(command, mode: mode, worktree: worktree, limit: settings.backgroundTimeLimitMinutes))
                    if worktree != nil { await store.refresh() }
                }
            } catch {
                messages[project.id] = Message(text: error.localizedDescription, isError: true)
                AppLog.error("Launch «\(command.title)» in \(project.name) failed: \(error.localizedDescription)")
            }
        }
    }

    static func launchedText(_ command: ClaudeCommand, mode: LaunchMode, worktree: WorktreePlan?, limit: Int) -> String {
        var text = mode == .terminal
            ? "«\(command.title)» запущен в новом окне Терминала."
            : "«\(command.title)» запущен в фоне (лимит \(limit) мин). Итог придёт уведомлением."
        if let worktree {
            text = "В папке проекта уже работает Claude, поэтому запуск идёт в worktree cb-\(worktree.slug) (ветка \(worktree.branch)). " + text
        }
        return text
    }

    func confirmPending(in project: Project) {
        guard let pending = pendingConfirmation[project.id] else { return }
        launch(pending.command, in: project, mode: pending.mode, allowBusyFolder: true)
    }

    func dismissMessage(for project: Project) {
        messages[project.id] = nil
        pendingConfirmation[project.id] = nil
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
