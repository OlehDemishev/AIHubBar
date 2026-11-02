import Foundation
import SQLite3
import Testing
@testable import ClaudePult

/// Codex beyond its limits (SPEC-ai-services stage 3): plan and credits, tokens per project, context.
struct CodexThreadsTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    /// The ChatGPT app's `codex` on a free plan (2026-10-31): plan only, no credits to show.
    @Test func freePlanAnswer() {
        let answer = """
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":43200,"resetsAt":1796067080},\
        "secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":null},"planType":"free"}}}
        """
        let notes = CodexThreads.accountNotes(Data(answer.utf8))
        #expect(notes.map(\.text) == [String(localized: "План: \("Free")")])
    }

    @Test func creditsBalanceAndUnlimited() {
        let balance = #"{"result":{"rateLimits":{"planType":"plus","credits":{"hasCredits":true,"unlimited":false,"balance":"12.5"}}}}"#
        #expect(CodexThreads.accountNotes(Data(balance.utf8)).count == 2)
        #expect(CodexThreads.accountNotes(Data(balance.utf8)).last?.text.contains("12") == true)
        let unlimited = #"{"result":{"rateLimits":{"credits":{"unlimited":true}}}}"#
        #expect(CodexThreads.accountNotes(Data(unlimited.utf8)).map(\.text) == [String(localized: "Кредиты: без ограничений")])
        #expect(CodexThreads.accountNotes(Data("{}".utf8)).isEmpty)
    }

    @Test func contextFromTokenCount() {
        let line = """
        {"timestamp":"2026-11-02T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{\
        "total_token_usage":{"input_tokens":90000,"total_tokens":95000},\
        "last_token_usage":{"input_tokens":60000,"cached_input_tokens":40000,"output_tokens":5000,"reasoning_output_tokens":1000,"total_tokens":65000},\
        "model_context_window":256000},"rate_limits":null}}
        """
        let fill = CodexThreads.contextFill(Data(line.utf8))
        #expect(fill.map { abs($0 - 64000.0 / 256000.0) < 0.0001 } == true)
        #expect(CodexThreads.contextFill(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#.utf8)) == nil)
        #expect(CodexThreads.contextFill(Data(#"{"type":"session_meta","payload":{"cwd":"/tmp"}}"#.utf8)) == nil)
    }

    @Test func threadsProjectsAndContextFromCodexFiles() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "codex-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appending(path: ".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let rollout = codex.appending(path: "rollout-1.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"cwd":"/Users/me/Projects/Alpha"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":51200,"reasoning_output_tokens":0},"model_context_window":256000}}}

        """.utf8).write(to: rollout)
        try makeDatabase(codex.appending(path: "state_3.sqlite"), rows: [])
        try makeDatabase(codex.appending(path: "state_5.sqlite"), rows: [
            ("/Users/me/Projects/Alpha", 30_000, now.addingTimeInterval(-3600), rollout.path, 0),
            ("/Users/me/Projects/Alpha", 20_000, now.addingTimeInterval(-2 * 86_400), "", 0),
            ("/Users/me/Projects/Beta", 70_000, now.addingTimeInterval(-86_400 * 3), "", 0),
            ("/Users/me/Projects/Old", 99_000, now.addingTimeInterval(-86_400 * 10), "", 0),
            ("/Users/me/Projects/Gone", 99_000, now.addingTimeInterval(-60), "", 1),
        ])

        #expect(CodexThreads.database(home: home)?.lastPathComponent == "state_5.sqlite", "the newest schema")
        let extras = CodexThreads.extras(home: home, now: now)
        #expect(extras.projects.map(\.name) == ["Beta", "Alpha"], "a week, not archived, most first")
        #expect(extras.projects.map(\.tokens) == [70_000, 50_000])
        #expect(extras.notes.count == 1 && extras.notes[0].text.contains("Alpha") && extras.notes[0].text.contains("20"))
        #expect(CodexThreads.extras(home: home.appending(path: "nobody"), now: now).projects.isEmpty)
    }

    private func makeDatabase(_ url: URL, rows: [(String, Int, Date, String, Int)]) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            cwd TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', tokens_used INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0)
            """, nil, nil, nil) == SQLITE_OK)
        for (index, row) in rows.enumerated() {
            let sql = "INSERT INTO threads (id, rollout_path, created_at, updated_at, cwd, tokens_used, archived) VALUES ('t\(index)', '\(row.3)', 0, \(Int(row.2.timeIntervalSince1970)), '\(row.0)', \(row.1), \(row.4))"
            try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
    }
}
