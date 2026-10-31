import Foundation
import os

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

/// Finds the `claude` CLI. It may sit wherever an installer or a Node version manager put it, or only inside the
/// Claude desktop app; an app started from Finder does not get the PATH the user's shell sets up.
enum ClaudeLocator {
    /// Fixed places: the native installer, Homebrew, npm prefixes, bun, volta, asdf and mise shims.
    static func candidates(home: String = NSHomeDirectory()) -> [String] {
        AgentKind.candidates("claude", home: home) + [
            "\(home)/.volta/bin/claude",
            "\(home)/.asdf/shims/claude",
            "\(home)/.local/share/mise/shims/claude",
            "\(home)/.yarn/bin/claude",
        ]
    }

    /// npm installs under nvm and fnm, newest Node version first.
    static func versionManagerCandidates(home: String = NSHomeDirectory()) -> [String] {
        versioned("\(home)/.nvm/versions/node", tail: "bin/claude")
            + versioned("\(home)/Library/Application Support/fnm/node-versions", tail: "installation/bin/claude")
            + versioned("\(home)/.local/share/fnm/node-versions", tail: "installation/bin/claude")
    }

    /// The copy the Claude desktop app keeps for itself (`claude-code/<version>/<hash>/claude.app`), newest first.
    /// Its folder changes with every update, so it is found again each time, never saved.
    static func desktopAppCandidates(home: String = NSHomeDirectory()) -> [String] {
        versioned("\(home)/Library/Application Support/Claude/claude-code", tail: "").flatMap { versionFolder in
            subfolders(versionFolder).map { "\(versionFolder)/\($0)/claude.app/Contents/MacOS/claude" }
        }
    }

    /// The configured path if set, else the first installed candidate, else plain `claude` (the shell's PATH).
    static func resolve(configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return (trimmed as NSString).expandingTildeInPath }
        return detect() ?? "claude"
    }

    /// Fixed places, then what the user's shell finds, then version managers, then the desktop app's copy.
    static func detect(
        home: String = NSHomeDirectory(), shellPath: String? = shellPath,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        let ordered = candidates(home: home) + [shellPath].compactMap { $0 }
            + versionManagerCandidates(home: home) + desktopAppCandidates(home: home)
        return ordered.first(where: isExecutable)
    }

    // MARK: - The user's shell

    private static let shellLookup = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// `command -v claude` from the user's interactive login shell, once `refreshShellPath()` has run.
    static var shellPath: String? { shellLookup.withLock { $0 } }

    /// Asks the user's shell where `claude` is: it loads `.zprofile` and `.zshrc`, where nvm and the like set PATH.
    static func refreshShellPath() async {
        let shell = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let result = try? await ProcessRunner.run(shell, ["-ilc", "command -v claude"], timeout: .seconds(10))
        let path = result.flatMap { $0.exitCode == 0 ? shellPath(fromOutput: $0.stdoutText) : nil }
        shellLookup.withLock { $0 = path }
        if let path { AppLog.info("claude in the login shell: \(path)") }
    }

    /// The last line that is an absolute path: an interactive shell may print a greeting first, and an alias
    /// (`alias claude=/…/claude`) is not a path to run.
    static func shellPath(fromOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last(where: { $0.hasPrefix("/") })
    }

    // MARK: - Folders

    /// `<root>/<version>/<tail>` for every version folder, newest version first.
    private static func versioned(_ root: String, tail: String) -> [String] {
        subfolders(root)
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { tail.isEmpty ? "\(root)/\($0)" : "\(root)/\($0)/\(tail)" }
    }

    private static func subfolders(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }
    }
}
