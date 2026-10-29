import Foundation

/// Headless commands for scripts and checks, run instead of the UI:
/// - `ClaudePult --login-item [status|on|off]`
/// - `ClaudePult --claude next|finish|task <project-path> [task text] [--claude-path <path>] [--print]`
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
        return nil
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
        args.removeAll { $0 == "--print" }
        var configuredPath = AppSettings().claudePath
        if let index = args.firstIndex(of: "--claude-path"), index + 1 < args.count {
            configuredPath = args[index + 1]
            args.removeSubrange(index...index + 1)
        }

        let usage = "Usage: ClaudePult --claude next|finish|task <project-path> [task text] [--claude-path <path>] [--print]"
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
            print(ShellQuote.claudeCommandLine(folder: request.projectPath, claude: request.claudePath, prompt: command.prompt))
            return 0
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
