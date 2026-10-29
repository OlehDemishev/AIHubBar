import Foundation

/// Live Claude Code processes and their working folders (from `ps` and `lsof`).
/// Used to tell whether a project folder is busy until hook data arrives in stage 4.
enum RunningSessions {
    /// Executable names of the Claude Code CLI: Homebrew/npm (`claude.exe`) and the native/desktop build (`claude`).
    static let executableNames: Set<String> = ["claude", "claude.exe"]

    static func workingDirectories() async -> [String] {
        guard let ps = try? await ProcessRunner.run("/bin/ps", ["-axo", "pid=,comm="], timeout: .seconds(10)),
              ps.exitCode == 0 else { return [] }
        let pids = claudePIDs(psOutput: String(decoding: ps.stdout, as: UTF8.self))
        guard !pids.isEmpty else { return [] }

        guard let lsof = try? await ProcessRunner.run(
            "/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pids.map(String.init).joined(separator: ","), "-Fn"],
            timeout: .seconds(10)
        ) else { return [] }
        // lsof exits 1 when some PIDs have gone away; whatever it printed is still valid.
        return lsofDirectories(String(decoding: lsof.stdout, as: UTF8.self))
    }

    /// PIDs from `ps -axo pid=,comm=` lines whose executable is Claude Code.
    static func claudePIDs(psOutput: String) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { return nil }
            let command = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            let name = (command as NSString).lastPathComponent
            return executableNames.contains(name) ? pid : nil
        }
    }

    /// Paths from `lsof -Fn` output (`n<path>` lines).
    static func lsofDirectories(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            line.hasPrefix("n/") ? String(line.dropFirst()) : nil
        }
    }

    /// A project folder is busy when a session runs in it or below it, except inside its `.claude/worktrees`.
    static func isBusy(projectPath: String, workingDirectories: [String]) -> Bool {
        let root = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        let worktrees = root + "/.claude/worktrees/"
        return workingDirectories.contains { cwd in
            (cwd == root || cwd.hasPrefix(root + "/")) && !cwd.hasPrefix(worktrees)
        }
    }
}
