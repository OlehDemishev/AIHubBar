import Foundation

/// Headless commands for scripts and checks, run instead of the UI:
/// - `ClaudePult --login-item [status|on|off]`
/// - `ClaudePult --claude next|finish|task <project-path> [task text] [--claude-path <path>] [--print] [--background]`
/// - `ClaudePult --hooks [status|install|uninstall]`
/// - `ClaudePult --sessions`, `ClaudePult --show-session <id>`, `ClaudePult --background-settings`
/// - `ClaudePult --command report|summary|cleanup-check|cleanup` (in this process)
/// - `ClaudePult --app-command <command>|help|cleanup-output` (asks the running app)
@MainActor
enum CommandLineTool {
    /// Returns an exit code if the arguments contain a command, `nil` to start the app normally.
    static func run(_ arguments: [String]) -> Int32? {
        if let index = arguments.firstIndex(of: "--login-item") {
            return loginItem(arguments.dropFirst(index + 1).first ?? "status")
        }
        if let index = arguments.firstIndex(of: "--claude") {
            return claude(Array(arguments.dropFirst(index + 1)))
        }
        if let index = arguments.firstIndex(of: "--hooks") {
            return hooks(arguments.dropFirst(index + 1).first ?? "status")
        }
        if let index = arguments.firstIndex(of: "--app-command"), index + 1 < arguments.count {
            let name = arguments[index + 1]
            let known = Array(AppRequests.windows.keys) + CommonCommand.allCases.map(\.cliName)
            guard known.contains(name) else {
                printError("Usage: ClaudePult --app-command " + known.sorted().joined(separator: "|"))
                return 2
            }
            AppRequests.post(name)
            print("sent \(name) to the running app")
            return 0
        }
        if let index = arguments.firstIndex(of: "--command"), index + 1 < arguments.count {
            guard let command = CommonCommand.allCases.first(where: { $0.cliName == arguments[index + 1] }),
                  command.script != nil else {
                printError("Usage: ClaudePult --command " + CommonCommand.allCases.filter { $0.script != nil }.map(\.cliName).joined(separator: "|"))
                return 2
            }
            let directory = AppSettings().dailyReportDirectory
            return waitFor {
                let (result, _) = await CommandStore.execute(command, dailyReportDirectory: directory)
                print("\(result.isError ? "error" : "ok"): \(result.text)")
                return result.isError ? 1 : 0
            }
        }
        if arguments.contains("--background-settings") {
            print(BackgroundPermissions.settingsJSON)
            return 0
        }
        if arguments.contains("--sessions") {
            for item in SessionStore.loadItems(from: SessionFiles.sessionsDirectory, now: .now) {
                let s = item.session
                print([s.id, item.state.rawValue, s.displayProject, s.worktreeName ?? "-", s.tty ?? "-", s.task ?? "-"].joined(separator: "\t"))
            }
            return 0
        }
        if let index = arguments.firstIndex(of: "--show-session"), index + 1 < arguments.count {
            let id = arguments[index + 1]
            guard let session = SessionStore.loadItems(from: SessionFiles.sessionsDirectory, now: .now)
                .first(where: { $0.id == id })?.session, let tty = session.tty, session.isInTerminalApp else {
                printError("no Terminal.app session with id \(id)")
                return 1
            }
            return waitFor {
                let found = await SessionActions.focusTerminalTab(tty: tty)
                print(found ? "focused \(tty)" : "tab not found")
                return found ? 0 : 1
            }
        }
        return nil
    }

    private static func hooks(_ action: String) -> Int32 {
        let installer = HookInstaller.live(projectsDirectory: AppSettings().projectsDirectory)
        do {
            switch action {
            case "status": break
            case "install":
                if let backup = try installer.install() { print("backup: \(backup.path)") }
            case "uninstall":
                if let backup = try installer.uninstall() { print("backup: \(backup.path)") }
            default:
                printError("Usage: ClaudePult --hooks [status|install|uninstall]")
                return 2
            }
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }
        print("hooks: \(installer.status())")
        return 0
    }

    private static func loginItem(_ action: String) -> Int32 {
        let controller = LoginItemController()
        switch action {
        case "status": break
        case "on": controller.setEnabled(true)
        case "off": controller.setEnabled(false)
        default:
            printError("Usage: ClaudePult --login-item [status|on|off]")
            return 2
        }

        print("login-item: \(controller.state)")
        if let error = controller.lastError {
            printError("error: \(error)")
            return 1
        }
        return 0
    }

    private static func claude(_ arguments: [String]) -> Int32 {
        var args = arguments
        let printOnly = args.contains("--print")
        let background = args.contains("--background")
        args.removeAll { $0 == "--print" || $0 == "--background" }
        var configuredPath = AppSettings().claudePath
        if let index = args.firstIndex(of: "--claude-path"), index + 1 < args.count {
            configuredPath = args[index + 1]
            args.removeSubrange(index...index + 1)
        }

        let usage = "Usage: ClaudePult --claude next|finish|task <project-path> [task text] [--claude-path <path>] [--print] [--background]"
        guard args.count >= 2 else { printError(usage); return 2 }
        let command: ClaudeCommand
        switch args[0] {
        case "next": command = .nextStep
        case "finish": command = .finishSession
        case "task" where args.count >= 3: command = .customTask(args[2...].joined(separator: " "))
        default: printError(usage); return 2
        }

        let request = LaunchRequest(
            command: command,
            projectPath: (args[1] as NSString).standardizingPath,
            claudePath: ClaudeLocator.resolve(configured: configuredPath)
        )
        if printOnly {
            if background {
                print(([request.claudePath] + BackgroundPermissions.arguments(prompt: command.prompt, sessionID: "<id>"))
                    .map(ShellQuote.quote).joined(separator: " "))
            } else {
                print(ShellQuote.claudeCommandLine(folder: request.projectPath, claude: request.claudePath, prompt: command.prompt))
            }
            return 0
        }
        if background {
            return launchInBackground(request)
        }
        return waitFor {
            switch try await ClaudeLauncher.launch(request) {
            case let .launched(folder, worktree):
                print("launched in \(folder)" + (worktree.map { " (worktree, branch \($0.branch))" } ?? ""))
                return 0
            case let .needsConfirmation(question):
                printError(question)
                return 3
            }
        }
    }

    /// Starts a background run; the running ClaudePult app picks it up and reports the result.
    private static func launchInBackground(_ request: LaunchRequest) -> Int32 {
        let folder = FolderBox()
        let prepared = waitFor {
            switch try await ClaudeLauncher.prepareFolder(request) {
            case let .ready(path, worktree):
                folder.value = (path, worktree)
                return 0
            case let .needsConfirmation(question):
                printError(question)
                return 3
            }
        }
        guard prepared == 0, let (path, worktree) = folder.value else { return prepared }
        do {
            let settings = AppSettings()
            let run = try RunStore(settings: settings).launch(
                command: request.command, project: (request.projectPath as NSString).lastPathComponent,
                projectPath: request.projectPath, folder: path, worktreeBranch: worktree?.branch,
                claudePath: request.claudePath
            )
            print("background run \(run.id) in \(path), log \(run.logURL.path)")
            return 0
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }
    }

    /// Runs async work to completion from the synchronous app entry point.
    private static func waitFor(_ work: @escaping @Sendable () async throws -> Int32) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ExitCode()
        Task.detached {
            do {
                result.value = try await work()
            } catch {
                printError("error: \(error.localizedDescription)")
                result.value = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result.value
    }

    private nonisolated static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Written by the detached task before `signal()`, read after `wait()`.
private final class ExitCode: @unchecked Sendable {
    var value: Int32 = 0
}

private final class FolderBox: @unchecked Sendable {
    var value: (String, WorktreePlan?)?
}
