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
    private(set) var pendingConfirmation: [String: ClaudeCommand] = [:]
    private(set) var worktreeStates: [String: WorktreeState] = [:]

    private let settings: AppSettings
    private let store: ProjectStore

    init(settings: AppSettings, store: ProjectStore) {
        self.settings = settings
        self.store = store
    }

    func launch(_ command: ClaudeCommand, in project: Project, allowBusyFolder: Bool = false) {
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
                switch try await ClaudeLauncher.launch(request) {
                case let .launched(_, worktree?):
                    messages[project.id] = Message(text: "В папке проекта уже работает Claude, поэтому «\(command.title)» запущен в worktree cb-\(worktree.slug) (ветка \(worktree.branch)).")
                    await store.refresh()
                case .launched:
                    messages[project.id] = Message(text: "«\(command.title)» запущен в новом окне Терминала.")
                case let .needsConfirmation(question):
                    pendingConfirmation[project.id] = command
                    messages[project.id] = Message(text: question)
                }
            } catch {
                messages[project.id] = Message(text: error.localizedDescription, isError: true)
                AppLog.error("Launch «\(command.title)» in \(project.name) failed: \(error.localizedDescription)")
            }
        }
    }

    func confirmPending(in project: Project) {
        guard let command = pendingConfirmation[project.id] else { return }
        launch(command, in: project, allowBusyFolder: true)
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
