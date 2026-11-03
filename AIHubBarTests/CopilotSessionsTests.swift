import Foundation
import SQLite3
import Testing
@testable import AIHubBar

/// GitHub Copilot CLI's own records (SPEC-ai-services stage 6), on a temporary `~/.copilot` with the schema of
/// Copilot CLI 1.0.105.
struct CopilotSessionsTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func contextFromUsageRecord() {
        let line = #"{"type":"session.usage_record","data":{"usage":{"model":"mai-code-1.1-flash","inputTokens":14264,"outputTokens":5,"maxPromptTokens":128000}}}"#
        #expect(CopilotSessions.contextFill(Data(line.utf8)).map { abs($0 - 14264.0 / 128000.0) < 0.0001 } == true)
        #expect(CopilotSessions.contextFill(Data(#"{"type":"session.start","data":{}}"#.utf8)) == nil)
    }

    @Test func sessionsProjectsCreditsAndContext() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "copilot-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: ".copilot")
        try FileManager.default.createDirectory(at: folder.appending(path: "session-state/s1"), withIntermediateDirectories: true)
        try Data("""
        {"type":"session.start","data":{}}
        {"type":"session.usage_record","data":{"usage":{"inputTokens":32000,"maxPromptTokens":128000}}}

        """.utf8).write(to: folder.appending(path: "session-state/s1/events.jsonl"))

        var db: OpaquePointer?
        try #require(sqlite3_open(CopilotSessions.database(home: home).path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let iso = CopilotSessions.iso
        let sql = """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT, branch TEXT, summary TEXT, created_at TEXT, updated_at TEXT);
            CREATE TABLE assistant_usage_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, model TEXT NOT NULL,
                input_tokens INTEGER, output_tokens INTEGER, total_nano_aiu INTEGER, created_at TEXT);
            INSERT INTO sessions VALUES ('s1', '/p/Alpha', NULL, NULL, NULL, 'Fix the build', '\(iso(now.addingTimeInterval(-3600)))', '\(iso(now.addingTimeInterval(-600)))');
            INSERT INTO sessions VALUES ('s2', '/p/Beta', NULL, NULL, NULL, 'Old', '\(iso(now.addingTimeInterval(-9 * 86_400)))', '\(iso(now.addingTimeInterval(-9 * 86_400)))');
            INSERT INTO assistant_usage_events (session_id, model, input_tokens, output_tokens, total_nano_aiu, created_at)
                VALUES ('s1', 'm', 14000, 500, 120000000, '\(iso(now.addingTimeInterval(-600)))');
            INSERT INTO assistant_usage_events (session_id, model, input_tokens, output_tokens, total_nano_aiu, created_at)
                VALUES ('s1', 'm', 20000, 1500, 380000000, '\(iso(now.addingTimeInterval(-300)))');
            INSERT INTO assistant_usage_events (session_id, model, input_tokens, output_tokens, total_nano_aiu, created_at)
                VALUES ('s2', 'm', 99000, 1000, 900000000, '\(iso(now.addingTimeInterval(-9 * 86_400)))');
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

        let recent = CopilotSessions.recent(home: home, now: now)
        #expect(recent.map(\.id) == ["s1"], "the last 3 hours only")
        #expect(recent.first?.title == "Fix the build" && recent.first?.agent == .copilot)
        #expect(recent.first?.context == 0.25)

        let week = CopilotSessions.projects(home: home, since: now.addingTimeInterval(-7 * 86_400))
        #expect(week.projects.map(\.name) == ["Alpha"] && week.projects.first?.tokens == 36_000)
        #expect(abs(week.credits - 0.5) < 0.0001, "nano-AIU / 10⁹")

        let extras = CopilotSessions.extras(home: home, now: now)
        try #require(extras.notes.count == 2)
        #expect(extras.notes[1].text.contains("25"))
        #expect(CopilotSessions.iso(now).hasSuffix("Z"))
        #expect(CopilotSessions.extras(home: home.appending(path: "nobody"), now: now).projects.isEmpty)
        #expect(AgentThread.recent(home: home, now: now).map(\.agent) == [.copilot])
    }
}

/// A WAL database whose owner has quit: no `-shm`, which a read-only open can't create.
struct SQLiteReaderTests {
    @Test func readsAClosedWALDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wal-\(UUID().uuidString) with space")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "state.sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (7);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: folder.appending(path: "state.sqlite-shm"))
        try? FileManager.default.removeItem(at: folder.appending(path: "state.sqlite-wal"))
        let rows = SQLiteReader.rows(url, "SELECT n FROM t")
        #expect(rows.count == 1 && rows.first?.first?.int == 7)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "state.sqlite-shm").path), "nothing written next to it")
        #expect(SQLiteReader.rows(folder.appending(path: "missing.sqlite"), "SELECT 1").isEmpty)
    }
}

/// Antigravity CLI's conversation summaries (agy 1.4.12 schema).
struct AntigravityConversationsTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func timesAndCommand() throws {
        let date = try #require(AntigravityConversations.date("2026-11-02 15:14:09.924653+00:00"))
        #expect(abs(date.timeIntervalSince1970 - 1_793_632_449.924) < 0.01)
        #expect(AntigravityConversations.date("2026-11-02 15:14:09+00:00") != nil)
        #expect(AntigravityConversations.stamp(date) == "2026-11-02 15:14:09")
        let thread = AgentThread(agent: .antigravity, id: "df2d", project: "App", folder: "/p/App", title: "", updatedAt: now)
        #expect(thread.resumeCommandLine(path: "/opt/homebrew/bin/agy").hasSuffix("\(ShellQuote.quote("--conversation")) \(ShellQuote.quote("df2d"))"))
    }

    @Test func recentConversations() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "agy-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".gemini/antigravity-cli"), withIntermediateDirectories: true)
        var db: OpaquePointer?
        try #require(sqlite3_open(AntigravityConversations.database(home: home).path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let recent = AntigravityConversations.stamp(now.addingTimeInterval(-600)) + ".924653+00:00"
        let old = AntigravityConversations.stamp(now.addingTimeInterval(-5 * 3600)) + ".1+00:00"
        let sql = """
            CREATE TABLE conversation_summaries (conversation_id text, title text NOT NULL DEFAULT '', workspace_uris text NOT NULL,
                last_modified_time datetime NOT NULL, status text NOT NULL DEFAULT '', parent_conversation_id text NOT NULL DEFAULT '');
            INSERT INTO conversation_summaries VALUES ('c1', 'Fix the tests', '["file:///Users/me/My%20App"]', '\(recent)', 'CASCADE_RUN_STATUS_RUNNING', '');
            INSERT INTO conversation_summaries VALUES ('c2', 'Subagent', '["file:///Users/me/My%20App"]', '\(recent)', 'CASCADE_RUN_STATUS_IDLE', 'c1');
            INSERT INTO conversation_summaries VALUES ('c3', 'Old', '["file:///Users/me/Old"]', '\(old)', 'CASCADE_RUN_STATUS_IDLE', '');
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let threads = AntigravityConversations.recent(home: home, now: now)
        #expect(threads.map(\.id) == ["c1"], "subagents and older conversations left out")
        #expect(threads.first?.folder == "/Users/me/My App" && threads.first?.project == "My App")
        #expect(threads.first?.isWorking == true && threads.first?.agent == .antigravity)
    }
}
