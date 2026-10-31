import Foundation
import Testing
@testable import ClaudePult

struct StreamJSONTests {
    /// Shapes taken from a real `claude -p --output-format stream-json --verbose` run (2.1.312).
    private static let log = """
    {"type":"system","subtype":"hook_started","hook_event":"SessionStart","session_id":"s"}
    {"type":"system","subtype":"init","cwd":"/tmp/p","permissionMode":"dontAsk","session_id":"s"}
    {"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"Создаю ветку."},{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b feat/x"}}]}}
    {"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/p/a.swift"}}]}}
    not json at all
    {"type":"result","subtype":"success","is_error":false,"result":"Готово: добавил экспорт.\\n\\nPR: https://github.com/OlehDemishev/Ambo/pull/23\\nПроверки зелёные.\\nЕщё строка.","session_id":"s","permission_denials":[{"tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git push origin main"}}]}
    """

    @Test func outcome() throws {
        let outcome = try #require(StreamJSON.outcome(fromLog: Self.log))
        #expect(!outcome.isError)
        #expect(outcome.subtype == "success")
        #expect(outcome.deniedTools == ["Bash"])
        #expect(StreamJSON.pullRequestURL(in: outcome.result) == "https://github.com/OlehDemishev/Ambo/pull/23")
        #expect(StreamJSON.summary(outcome.result) == "Готово: добавил экспорт.\nPR: https://github.com/OlehDemishev/Ambo/pull/23\nПроверки зелёные.")
    }

    @Test func noResultWhenKilled() {
        #expect(StreamJSON.outcome(fromLog: "{\"type\":\"system\",\"subtype\":\"init\"}\n") == nil)
        #expect(StreamJSON.outcome(fromLog: "") == nil)
    }

    @Test func errorResult() throws {
        let log = #"{"type":"result","subtype":"error_max_turns","is_error":true,"errors":["max turns"]}"#
        let outcome = try #require(StreamJSON.outcome(fromLog: log))
        #expect(outcome.isError)
        #expect(outcome.result == nil)
    }

    @Test func entries() {
        let entries = StreamJSON.entries(fromLog: Self.log)
        #expect(entries.map(\.kind) == [.text, .tool, .tool, .result])
        #expect(entries[1].text == "Bash: git checkout -b feat/x")
        #expect(entries[2].text == "Edit: /tmp/p/a.swift")
    }

    @Test func summaryLimits() {
        #expect(StreamJSON.summary(nil) == nil)
        #expect(StreamJSON.summary("\n\n---\n") == nil)
        #expect(StreamJSON.summary(String(repeating: "я", count: 500))?.count == 300)
    }
}

struct RunMessageTests {
    private func run(_ state: BackgroundRun.State, task: String = "Добавь <экспорт> & импорт", summary: String? = "Готово", pr: String? = nil) -> BackgroundRun {
        BackgroundRun(
            id: "r1", project: "Ambo", projectPath: "/P/Ambo", folder: "/P/Ambo", worktreeBranch: nil,
            commandTitle: "Своя задача", task: task, startedAt: .now, timeLimitMinutes: 90, pid: 1,
            state: state, finishedAt: .now, summary: summary, pullRequestURL: pr, notified: false
        )
    }

    @Test func telegramSuccessWithPR() {
        #expect(RunMessage.telegramHTML(run(.succeeded, pr: "https://github.com/O/Ambo/pull/23"))
            == "✅ <b>Ambo</b>: Добавь &lt;экспорт&gt; &amp; импорт — Готово\n<a href=\"https://github.com/O/Ambo/pull/23\">PR #23</a>")
    }

    @Test func failureAndLimits() {
        #expect(RunMessage.telegramHTML(run(.failed, summary: nil)).hasPrefix("❌ <b>Ambo</b>:"))
        #expect(RunMessage.telegramHTML(run(.failed, summary: nil)).hasSuffix("завершилось с ошибкой"))
        #expect(RunMessage.outcomeText(run(.timedOut)) == "остановлено по лимиту времени (90 мин)")
        #expect(RunMessage.icon(.stopped) == "❌")
        let long = RunMessage.taskStart(String(repeating: "слово ", count: 30))
        #expect(long.count == RunMessage.taskPrefixLength)
        #expect(long.hasSuffix("…"))
    }

    @Test func telegramCredentials() {
        #expect(Telegram.credentials(fromConfig: Data(#"{"telegram":{"bot_token":"123:abc","chat_id":"42"}}"#.utf8))?.chatID == "42")
        #expect(Telegram.credentials(fromConfig: Data(#"{"telegram":{"bot_token":"123:abc","chat_id":42}}"#.utf8))?.chatID == "42")
        #expect(Telegram.credentials(fromConfig: Data(#"{"telegram":{"bot_token":"","chat_id":"42"}}"#.utf8)) == nil)
        #expect(Telegram.credentials(fromConfig: Data(#"{"other":1}"#.utf8)) == nil)
        #expect(Telegram.credentials(fromConfig: Data("garbage".utf8)) == nil)
    }
}

struct BackgroundPermissionsTests {
    @Test func arguments() {
        let args = BackgroundPermissions.arguments(prompt: "do it", sessionID: "abc")
        #expect(Array(args.prefix(2)) == ["-p", "do it"])
        for (flag, value) in [("--session-id", "abc"), ("--output-format", "stream-json"),
                              ("--permission-mode", "dontAsk"), ("--permission-prompts", "none")] {
            let index = args.firstIndex(of: flag)
            #expect(index.map { args[$0 + 1] } == value, "\(flag)")
        }
        #expect(args.contains("--verbose"))
    }

    @Test func settingsJSONIsValidAndDenyCoversSpec() throws {
        let object = try JSONSerialization.jsonObject(with: Data(BackgroundPermissions.settingsJSON().utf8)) as? [String: Any]
        let permissions = try #require(object?["permissions"] as? [String: Any])
        let deny = try #require(permissions["deny"] as? [String])
        let allow = try #require(permissions["allow"] as? [String])
        for rule in ["Bash(git push * main)", "Bash(git push *--force*)", "Bash(git reset --hard*)",
                     "Bash(gh pr merge*)", "Bash(sudo *)", "Read(**/.env)", "Bash(*.env*)"] {
            #expect(deny.contains(rule), "\(rule)")
        }
        for rule in ["Edit(./**)", "Bash(git push -u origin *)", "Bash(gh pr create *)", "Bash(npm *)", "Bash(xcodebuild *)"] {
            #expect(allow.contains(rule), "\(rule)")
        }
        #expect(!allow.contains("Edit"), "edits must stay inside the working folder")
        #expect(permissions["blockReadsOutsideWorkingDirectories"] as? Bool == true)
    }
}

struct RunProcessTests {
    @Test func liveness() {
        #expect(!RunStore.isRunProcessAlive(999_999, startedAt: .now))
        // This test process is alive, but it did not start "now" in a year's time: treated as a reused PID.
        #expect(!RunStore.isRunProcessAlive(getpid(), startedAt: .now.addingTimeInterval(365 * 86_400)))
    }
}

struct SessionRowTests {
    private func item(_ id: String, _ state: Session.State) throws -> SessionStore.Item {
        let json: [String: Any] = ["session_id": id, "cwd": "/P/Ambo", "project": "Ambo", "state": state.rawValue,
                                   "updated_at": Date.now.ISO8601Format(), "first_prompt": "hook prompt"]
        let session = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        return SessionStore.Item(session: session, state: state)
    }

    private func run(_ id: String, _ state: BackgroundRun.State, finished: Date? = nil) -> BackgroundRun {
        BackgroundRun(
            id: id, project: "Ambo", projectPath: "/P/Ambo", folder: "/P/Ambo/.claude/worktrees/cb-x", worktreeBranch: "claude/x",
            commandTitle: "Своя задача", task: "run task", startedAt: .now, timeLimitMinutes: 90, pid: 1,
            state: state, finishedAt: finished, summary: "итог", pullRequestURL: nil, notified: false
        )
    }

    @Test func joinsRunsWithSessions() throws {
        let rows = SessionRow.rows(
            sessions: [try item("a", .done), try item("b", .running)],
            runs: [run("a", .failed, finished: .now), run("c", .running), run("old", .succeeded, finished: .now.addingTimeInterval(-3600))]
        )
        #expect(rows.map(\.id) == ["b", "c", "a"])
        let a = try #require(rows.first { $0.id == "a" })
        #expect(a.state == .error)
        #expect(a.task == "run task")
        #expect(a.message == "итог")
        let c = try #require(rows.first { $0.id == "c" })
        #expect(c.session == nil)
        #expect(c.worktree == "cb-x")
    }
}

/// The app's own Telegram bot: the chat found from the bot's updates, and it wins over `_daily-report`.
struct TelegramOwnBotTests {
    @Test func latestChatFromUpdates() {
        let updates = #"{"ok":true,"result":[{"update_id":1,"message":{"chat":{"id":111,"type":"private"},"text":"hi"}},{"update_id":2,"message":{"chat":{"id":-222,"type":"group"},"text":"yo"}}]}"#
        #expect(Telegram.latestChat(in: Data(updates.utf8)) == "-222")
        #expect(Telegram.latestChat(in: Data(#"{"ok":true,"result":[]}"#.utf8)) == nil)
    }

    @MainActor @Test func ownBotComesFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"telegram":{"bot_token":"file:token","chat_id":"1"}}"#.utf8).write(to: folder.appending(path: "config.json"))
        let saved = Telegram.ownBot
        defer { Telegram.ownBot = saved }
        Telegram.ownBot = nil
        #expect(Telegram.credentials(dailyReportDirectory: folder.path)?.chatID == "1")
        Telegram.ownBot = .init(token: "own:token", chatID: "2")
        #expect(Telegram.credentials(dailyReportDirectory: folder.path)?.chatID == "2")
    }
}
