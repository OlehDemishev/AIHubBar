import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessError: LocalizedError {
    case launchFailed(String, underlying: String)
    case timedOut(String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(command, underlying): String(localized: "Не удалось запустить \(command): \(underlying)")
        case let .timedOut(command, seconds): String(localized: "\(command) не ответил за \(seconds) с")
        }
    }
}

/// Runs external processes without blocking the caller: the blocking work happens on a GCD thread.
enum ProcessRunner {
    /// Extra directories prepended to PATH: apps started from Finder/launchd get only the system PATH,
    /// while tools such as `gh` and `claude` live in Homebrew or ~/.local/bin.
    static let extraPathDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
    ]

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        // When ClaudePult runs from inside a Claude Code session (command-line mode, development), Claude's own
        // variables would leak into Terminal and make a new `claude` think it is a child session.
        var env = base.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE" }
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extraPathDirectories.filter { !current.contains($0) } + current).joined(separator: ":")
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        input: Data? = nil,
        environment overrides: [String: String] = [:],
        timeout: Duration
    ) async throws -> ProcessResult {
        let command = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(1)).joined(separator: " ")
        let seconds = Double(timeout.components.seconds)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment().merging(overrides) { $1 }
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let stdin = input.map { _ in Pipe() }
                process.standardInput = stdin ?? FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessError.launchFailed(command, underlying: error.localizedDescription))
                    return
                }

                if let stdin, let input {
                    DispatchQueue.global(qos: .utility).async {
                        try? stdin.fileHandleForWriting.write(contentsOf: input)
                        try? stdin.fileHandleForWriting.close()
                    }
                }

                let timedOut = Flag()
                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)

                // Drain stderr concurrently so a chatty process cannot block on a full pipe.
                let errorData = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errorData.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                watchdog.cancel()

                if timedOut.isSet {
                    continuation.resume(throwing: ProcessError.timedOut(command, seconds: Int(seconds)))
                } else {
                    continuation.resume(returning: ProcessResult(
                        exitCode: process.terminationStatus, stdout: outputData, stderr: errorData.data
                    ))
                }
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Written once by the stderr reader before `group.leave()`, read after `group.wait()`.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
