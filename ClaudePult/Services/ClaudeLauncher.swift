import Foundation

enum LaunchError: LocalizedError {
    case automationDenied
    case terminalFailed(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            String(localized: "AI Hub Bar не может управлять Терминалом. Разрешите: Системные настройки → Конфиденциальность и безопасность → Автоматизация → AI Hub Bar → Терминал.")
        case let .terminalFailed(detail):
            String(localized: "Не удалось открыть Терминал: \(detail)")
        }
    }
}

enum LaunchOutcome: Equatable, Sendable {
    case launched(folder: String, worktree: WorktreePlan?)
    /// The folder is busy and the command cannot move to a worktree; ask before starting a second session there.
    case needsConfirmation(String)
}

struct LaunchRequest: Sendable {
    var command: ClaudeCommand
    var projectPath: String
    var nextItems: [String] = []
    var baseRef = "origin/main"
    var claudePath: String
    var allowBusyFolder = false
    var style: PromptStyle = .workspace
    /// The workspace style's shared rules file (`~/…/CLAUDE.md` in the projects folder).
    var rulesFile: String?
}

/// Picks the folder for a Claude command and starts it in a new Terminal window (docs/SPEC.md §2.4).
enum ClaudeLauncher {
    enum Folder: Equatable, Sendable {
        case ready(path: String, worktree: WorktreePlan?)
        /// The folder is busy and the command cannot move to a worktree; ask before starting a second session there.
        case needsConfirmation(String)
    }

    /// The project folder, or a new worktree when a Claude Code session already works in the project.
    static func prepareFolder(_ request: LaunchRequest) async throws -> Folder {
        let busy = RunningSessions.isBusy(
            projectPath: request.projectPath,
            workingDirectories: await RunningSessions.workingDirectories()
        )
        guard busy else { return .ready(path: request.projectPath, worktree: nil) }
        if request.command.canUseWorktree {
            let plan = try await GitService.createWorktree(
                projectPath: request.projectPath,
                nameSource: request.command.nameSource(nextItems: request.nextItems),
                baseRef: request.baseRef
            )
            return .ready(path: plan.path, worktree: plan)
        }
        return request.allowBusyFolder
            ? .ready(path: request.projectPath, worktree: nil)
            : .needsConfirmation(String(localized: "В этой папке уже работает сессия Claude. Запустить ещё одну там же?"))
    }

    static func launch(_ request: LaunchRequest) async throws -> LaunchOutcome {
        switch try await prepareFolder(request) {
        case let .needsConfirmation(question):
            return .needsConfirmation(question)
        case let .ready(folder, worktree):
            try await TerminalLauncher.run(
                ShellQuote.claudeCommandLine(folder: folder, claude: request.claudePath, prompt: request.command.prompt(request.style, rulesFile: request.rulesFile))
            )
            AppLog.info("Launched «\(request.command.title)» in Terminal: \(folder)")
            return .launched(folder: folder, worktree: worktree)
        }
    }
}

enum TerminalLauncher {
    /// AppleScript that types `item 1 of argv` into a new Terminal window. The command line is passed as an
    /// argument, not spliced into the script, so it needs shell quoting only (see `ShellQuote`).
    /// A Terminal that is not running opens its own empty window on launch; the command goes there
    /// instead of into a second window.
    static let script = [
        "on run argv",
        "set commandLine to item 1 of argv",
        "if application \"Terminal\" is running then",
        "tell application \"Terminal\" to do script commandLine",
        "else",
        "tell application \"Terminal\"",
        "activate",
        "repeat 30 times",
        "if (count of windows) > 0 then exit repeat",
        "delay 0.1",
        "end repeat",
        "if (count of windows) > 0 then",
        "do script commandLine in window 1",
        "else",
        "do script commandLine",
        "end if",
        "end tell",
        "end if",
        "tell application \"Terminal\" to activate",
        "end run",
    ]

    static func arguments(commandLine: String) -> [String] {
        script.flatMap { ["-e", $0] } + [commandLine]
    }

    static func run(_ commandLine: String) async throws {
        // Long timeout: the first run waits for the user to answer the Automation permission prompt.
        let result = try await ProcessRunner.run("/usr/bin/osascript", arguments(commandLine: commandLine), timeout: .seconds(180))
        guard result.exitCode == 0 else {
            let stderr = result.stderrText
            AppLog.error("osascript failed (\(result.exitCode)): \(stderr.prefix(300))")
            // -1743: not authorized to send Apple events; -1744: the user has not answered yet.
            if stderr.contains("-1743") || stderr.contains("-1744") { throw LaunchError.automationDenied }
            throw LaunchError.terminalFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

enum ClaudeLocator {
    static var candidates: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
    }

    /// The configured path if set, else the first installed candidate, else plain `claude` (the shell's PATH).
    static func resolve(configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return (trimmed as NSString).expandingTildeInPath }
        return detect() ?? "claude"
    }

    static func detect() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
