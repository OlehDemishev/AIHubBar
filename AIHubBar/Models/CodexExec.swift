import Foundation

/// A background Codex run: `codex exec --json` (checked live on 0.166.0-alpha.5.1, 2026-11-17). Events are JSON lines:
/// `thread.started {thread_id}`, `item.started` / `item.completed {item: {type: agent_message | command_execution |
/// file_change, …}}`, then `turn.completed {usage}`, or `turn.failed {error: {message}}` / `error {message}`.
/// `exec` never asks: what the sandbox does not allow fails and Codex goes on. `workspace-write` lets it write in the
/// working folder only and keeps the network off — the nearest thing to Claude's background rules. Its sandbox keeps
/// `.git` read-only, so `git commit` fails («Unable to create …/.git/index.lock»); with the repository's git folder
/// passed as `--add-dir` the commit works (both seen live, 2026-11-17). Without the network there is no push or PR.
enum CodexExec {
    static let agent = "codex"

    /// `readOnly` — a review: the `read-only` sandbox, nothing in the folder can change.
    static func arguments(prompt: String, gitDirectory: String? = nil, readOnly: Bool = false) -> [String] {
        ["exec", "--sandbox", readOnly ? "read-only" : "workspace-write"]
            + (readOnly ? [] : gitDirectory.map { ["--add-dir", $0] } ?? [])
            + ["--json", "--skip-git-repo-check", prompt]
    }

    /// The git folder a commit in `folder` writes to: its own `.git`, or for a worktree (`.git` is a file with
    /// `gitdir: <repo>/.git/worktrees/<name>`) the repository's. Nil outside a repository.
    static func gitDirectory(folder: String) -> String? {
        let dotGit = (folder as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !path.hasPrefix("/") { path = ((folder as NSString).appendingPathComponent(path) as NSString).standardizingPath }
        guard let range = path.range(of: "/worktrees/", options: .backwards) else { return path }
        return String(path[..<range.lowerBound])
    }

    /// A worktree: its `.git` is a file that points into the repository's git folder.
    static func isWorktree(folder: String) -> Bool {
        var isDirectory: ObjCBool = false
        let dotGit = (folder as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Added to a task that runs in a worktree. Codex's sandbox denies writes to the git folder its working folder
    /// points at, even when the repository's `.git` is passed as `--add-dir`: `git commit` fails with «Unable to
    /// create …/.git/worktrees/<name>/index.lock: Operation not permitted» (seen live 2026-11-19, 0.166). So there
    /// AI Hub Bar commits what Codex leaves (`RunStore`), and Codex is told not to try.
    static let worktreeNote = """


        Do not run `git add` or `git commit` here: this folder is a git worktree and your sandbox cannot write its git \
        folder. Leave your changes uncommitted; they are committed for you when you finish.
        """

    static func threadID(fromLog text: String) -> String? {
        for line in text.split(separator: "\n").prefix(20) {
            guard let event = StreamJSON.object(line), event["type"] as? String == "thread.started" else { continue }
            return event["thread_id"] as? String
        }
        return nil
    }

    /// The turn's end: its last message as the result, or the error. Nil for a log that is not Codex's or has no end.
    static func outcome(fromLog text: String) -> StreamJSON.Outcome? {
        var message: String?
        var outcome: StreamJSON.Outcome?
        for line in text.split(separator: "\n") where line.contains("\"type\"") {
            guard let event = StreamJSON.object(line), let type = event["type"] as? String else { continue }
            switch type {
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message", let text = item["text"] as? String {
                    message = plainFileLinks(text)
                }
            case "turn.completed":
                outcome = StreamJSON.Outcome(isError: false, subtype: type, result: message, deniedTools: [])
            case "turn.failed", "error":
                // `error` also comes before a retry: a later `turn.completed` replaces it.
                outcome = StreamJSON.Outcome(isError: true, subtype: type, result: errorText(event), deniedTools: [])
            default: break
            }
        }
        return outcome
    }

    /// A readable line of the run's log, or nil for events that say nothing to a person.
    static func entry(_ event: [String: Any]) -> (StreamJSON.Entry.Kind, String)? {
        switch event["type"] as? String {
        case "item.completed":
            guard let item = event["item"] as? [String: Any] else { return nil }
            switch item["type"] as? String {
            case "agent_message":
                return (item["text"] as? String).flatMap { $0.isEmpty ? nil : (.text, plainFileLinks($0)) }
            case "command_execution":
                return (.tool, "Bash: " + shellCommand(item["command"] as? String ?? ""))
            case "file_change":
                let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }
                return (.tool, "Edit: " + paths.joined(separator: ", "))
            default:
                return nil
            }
        case "turn.failed", "error":
            return (.error, errorText(event))
        default:
            return nil
        }
    }

    /// `[NOTES.md](/Users/me/project/NOTES.md)` → `NOTES.md`: Codex links the files it names by their full path (seen
    /// live 2026-11-17), which a notification or a Telegram message would show raw; a path with spaces comes as `(</path>)`. Links to the web stay as they are.
    static func plainFileLinks(_ text: String) -> String {
        guard text.contains("](") else { return text }
        return text.replacing(/\[([^\]\n]+)\]\(<?(?:\/|~\/|file:)[^)\n]*\)/) { String($0.1) }
    }

    /// `/bin/zsh -lc "npm test"` → `npm test`: Codex wraps every command in a login shell.
    static func shellCommand(_ command: String) -> String {
        guard let range = command.range(of: " -lc ") else { return command }
        var inner = String(command[range.upperBound...])
        if inner.count >= 2, let first = inner.first, first == "\"" || first == "'", inner.last == first {
            inner = String(inner.dropFirst().dropLast())
        }
        return inner
    }

    private static func errorText(_ event: [String: Any]) -> String {
        ((event["error"] as? [String: Any])?["message"] as? String) ?? (event["message"] as? String) ?? "error"
    }
}
