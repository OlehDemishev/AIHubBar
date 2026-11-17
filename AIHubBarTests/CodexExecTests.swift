import Foundation
import Testing
@testable import AIHubBar

/// A background Codex run reads `codex exec --json` (`CodexExec`). The log is a real run's (0.166.0-alpha.5.1,
/// 2026-11-17), shortened.
struct CodexExecTests {
    static let log = """
    Reading additional input from stdin...
    {"type":"thread.started","thread_id":"01a1ea15-64a5-7260-98c9-06b0aaf50f09"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I’ll create `b.txt`, then run `ls`."}}
    {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \\"printf 'ok' > b.txt && ls\\"","aggregated_output":"","exit_code":null,"status":"in_progress"}}
    {"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \\"printf 'ok' > b.txt && ls\\"","aggregated_output":"a.txt\\nb.txt\\n","exit_code":0,"status":"completed"}}
    {"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/tmp/p/Notes.md","kind":"update"}],"status":"completed"}}
    {"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Created `b.txt` with `ok`."}}
    {"type":"turn.completed","usage":{"input_tokens":32511,"cached_input_tokens":27904,"output_tokens":90}}
    """

    @Test func theLastMessageIsTheResult() throws {
        let outcome = try #require(StreamJSON.outcome(fromLog: Self.log))
        #expect(!outcome.isError)
        #expect(outcome.result == "Created `b.txt` with `ok`.")
        #expect(CodexExec.threadID(fromLog: Self.log) == "01a1ea15-64a5-7260-98c9-06b0aaf50f09")
    }

    @Test func theLogReadsLikeClaudes() {
        let entries = StreamJSON.entries(fromLog: Self.log)
        #expect(entries.map(\.kind) == [.text, .tool, .tool, .text])
        #expect(entries[1].text == "Bash: printf 'ok' > b.txt && ls", "without Codex's login shell around it")
        #expect(entries[2].text == "Edit: Notes.md")
    }

    @Test func aFailedTurnIsAnError() throws {
        let failed = #"{"type":"thread.started","thread_id":"t"}"# + "\n" + #"{"type":"turn.failed","error":{"message":"usage limit reached"}}"#
        let outcome = try #require(StreamJSON.outcome(fromLog: failed))
        #expect(outcome.isError && outcome.result == "usage limit reached")
        #expect(StreamJSON.entries(fromLog: failed).last?.kind == .error)
        // An error before a retry that then succeeds is not the outcome.
        let retried = #"{"type":"error","message":"stream disconnected"}"# + "\n" + Self.log
        #expect(StreamJSON.outcome(fromLog: retried)?.isError == false)
        // A killed run has no end; Claude's log is still Claude's.
        #expect(CodexExec.outcome(fromLog: #"{"type":"thread.started","thread_id":"t"}"#) == nil)
        #expect(CodexExec.outcome(fromLog: #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#) == nil)
    }

    @Test func theRunWritesOnlyInItsFolderAndNeverAsks() {
        let arguments = CodexExec.arguments(prompt: "do it")
        #expect(arguments.first == "exec" && arguments.last == "do it")
        #expect(arguments.contains("workspace-write") && arguments.contains("--json"))
        #expect(!arguments.contains { $0.contains("dangerously") } && !arguments.contains("--add-dir"))
    }

    /// Codex's sandbox keeps `.git` read-only; a commit needs the repository's git folder writable.
    @Test func commitsNeedTheGitFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "codex-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "repo"), tree = root.appending(path: "tree"), plain = root.appending(path: "plain")
        for folder in [repo.appending(path: ".git/worktrees/tree"), tree, plain] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "gitdir: \(repo.path)/.git/worktrees/tree\n".write(to: tree.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(CodexExec.gitDirectory(folder: repo.path) == repo.path + "/.git")
        #expect(CodexExec.gitDirectory(folder: tree.path) == repo.path + "/.git", "a worktree commits into the repository's folder")
        #expect(CodexExec.gitDirectory(folder: plain.path) == nil)
        let arguments = CodexExec.arguments(prompt: "p", gitDirectory: "/r/.git")
        #expect(arguments.firstIndex(of: "--add-dir").map { arguments[$0 + 1] } == "/r/.git")
    }

    @Test func aCodexRunSharesTheRowOfItsHookSession() throws {
        var run = BackgroundRun(
            id: "run-1", project: "Ambo", projectPath: "/P/Ambo", folder: "/P/Ambo", worktreeBranch: nil,
            commandTitle: "Своя задача", task: "Task", startedAt: .now, timeLimitMinutes: 90, pid: 1,
            state: .running, notified: false, agent: CodexExec.agent, threadID: "thread-1"
        )
        #expect(run.agentTitle == AgentKind.codex.title)
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"session_id":"thread-1","state":"running","agent":"codex","cwd":"/P/Ambo","started_at":"2026-11-17T10:00:00Z","updated_at":"2026-11-17T10:00:00Z"}"#.utf8))
        let rows = SessionRow.rows(sessions: [.init(session: session, state: .running, context: nil)], runs: [run])
        #expect(rows.count == 1 && rows.first?.run?.id == "run-1")
        run.threadID = nil
        #expect(SessionRow.rows(sessions: [], runs: [run]).count == 1)
    }

    @Test func fileLinksInTheSummaryBecomePlainNames() {
        #expect(CodexExec.plainFileLinks("Создал [NOTES.md](/tmp/Demo/NOTES.md) и [a b.txt](~/x/a b.txt:12).") == "Создал NOTES.md и a b.txt.")
        #expect(CodexExec.plainFileLinks("See [the docs](https://example.com/a) and list[0](x)") == "See [the docs](https://example.com/a) and list[0](x)")
        let log = #"{"type":"item.completed","item":{"type":"agent_message","text":"Done: [b.txt](/tmp/p/b.txt)"}}"# + "\n" + #"{"type":"turn.completed","usage":{}}"#
        #expect(CodexExec.outcome(fromLog: log)?.result == "Done: b.txt")
    }
}
