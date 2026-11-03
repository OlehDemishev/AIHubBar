import Foundation
import SQLite3

/// A recent conversation of an agent other than Claude, for the «Сессии» block (SPEC-ai-services stages 5–6). Without
/// a hook there is no «working» or «waiting» — only when it was last updated and how full its context is (Copilot with
/// `CopilotHooks` and Codex with `CodexHooks` are session rows instead). A click continues it in Terminal.
struct AgentThread: Equatable, Identifiable, Sendable {
    var agent: AgentKind
    var id: String
    var project: String
    var folder: String
    var title: String
    var updatedAt: Date
    var context: Double?
    /// The agent says it is running right now (Antigravity keeps a run status; Codex and Copilot don't).
    var isWorking = false

    /// Terminal command that continues the conversation in its folder.
    func resumeCommandLine(path: String) -> String {
        let arguments = switch agent {
        case .copilot: ["--resume=\(id)"]
        case .antigravity: ["--conversation", id]
        default: ["resume", id]
        }
        return "cd \(ShellQuote.quote(folder)) && " + ([path] + arguments).map(ShellQuote.quote).joined(separator: " ")
    }

    /// The threads not already shown as hook sessions (Copilot with `CopilotHooks`, Codex with `CodexHooks`: Codex's
    /// hook `session_id` is its thread id).
    static func without(_ threads: [AgentThread], sessionIDs: Set<String>) -> [AgentThread] {
        threads.filter { !sessionIDs.contains($0.id) }
    }

    /// Codex, Copilot and Antigravity conversations, newest first.
    static func recent(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now) -> [AgentThread] {
        (CodexThreads.recent(home: home, now: now) + CopilotSessions.recent(home: home, now: now)
            + AntigravityConversations.recent(home: home, now: now))
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// Read-only queries of the agents' own SQLite files; a busy or missing database gives no rows.
enum SQLiteReader {
    enum Value: Sendable { case int(Int64), text(String) }

    /// Opened read-only; a WAL database whose agent isn't running has no `-shm`, which a read-only connection can't
    /// create (SQLITE_CANTOPEN), so then it is read as immutable — still nothing written next to it.
    static func rows(_ database: URL, _ sql: String, _ bindings: [Value] = []) -> [[Value?]] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        let path = database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path
        return query("file:\(path)?mode=ro", sql, bindings) ?? query("file:\(path)?mode=ro&immutable=1", sql, bindings) ?? []
    }

    /// Nil when the database can't be opened or read.
    private static func query(_ uri: String, _ sql: String, _ bindings: [Value]) -> [[Value?]]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            switch value {
            case let .int(number): sqlite3_bind_int64(statement, Int32(index + 1), number)
            case let .text(text): sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            }
        }
        var result: [[Value?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { return result.isEmpty ? nil : result }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER, SQLITE_FLOAT: .int(sqlite3_column_int64(statement, column))
                case SQLITE_TEXT: sqlite3_column_text(statement, column).map { .text(String(cString: $0)) }
                default: nil
                }
            })
        }
    }
}

extension Optional where Wrapped == SQLiteReader.Value {
    var text: String {
        if case let .text(text) = self { return text }
        if case let .int(number) = self { return String(number) }
        return ""
    }

    var int: Int64 {
        if case let .int(number) = self { return number }
        if case let .text(text) = self { return Int64(text) ?? 0 }
        return 0
    }
}

/// GitHub Copilot CLI's own records (checked on Copilot CLI 1.0.105, 2026-11-02): `~/.copilot/session-store.db` —
/// `sessions` (`id`, `cwd`, `summary`, `updated_at` as ISO text) and `assistant_usage_events` (per request: `input_tokens`,
/// `output_tokens`, `total_nano_aiu` — AI credits × 10⁹, `created_at`); each session's
/// `session-state/<id>/events.jsonl` has `session.usage_record` with `inputTokens` and `maxPromptTokens`.
enum CopilotSessions {
    static func database(home: URL) -> URL { home.appending(path: ".copilot/session-store.db") }

    /// The way Copilot writes its times: `2026-11-02T14:38:31.556Z` (compared as text in the queries).
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Sessions updated in the last `within` seconds (3 hours), newest first.
    static func recent(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now,
                       within: TimeInterval = 3 * 3600, limit: Int = 5) -> [AgentThread] {
        let rows = SQLiteReader.rows(database(home: home),
            "SELECT id, cwd, summary, updated_at FROM sessions WHERE updated_at >= ? ORDER BY updated_at DESC LIMIT ?",
            [.text(iso(now.addingTimeInterval(-within))), .int(Int64(limit))])
        return rows.compactMap { row in
            let id = row[0].text, cwd = row[1].text
            guard !id.isEmpty, !cwd.isEmpty, let updated = ISODate.parse(row[3].text) else { return nil }
            return AgentThread(agent: .copilot, id: id, project: URL(fileURLWithPath: cwd).lastPathComponent, folder: cwd,
                               title: row[2].text, updatedAt: updated, context: context(session: id, home: home))
        }
    }

    /// How full the context was at the session's last request: `inputTokens` over `maxPromptTokens`.
    static func context(session: String, home: URL) -> Double? {
        let url = home.appending(path: ".copilot/session-state/\(session)/events.jsonl")
        guard let data = try? Data(contentsOf: url) else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            if let fill = contextFill(Data(line)) { return fill }
        }
        return nil
    }

    static func contextFill(_ line: Data) -> Double? {
        guard let object = HubParse.object(line), object["type"] as? String == "session.usage_record",
              let usage = (object["data"] as? [String: Any])?["usage"] as? [String: Any],
              let input = HubParse.number(usage["inputTokens"]), let window = HubParse.number(usage["maxPromptTokens"]), window > 0
        else { return nil }
        return min(max(input / window, 0), 1)
    }

    /// Tokens (input + output) per project folder since `since`, and the AI credits they took.
    static func projects(home: URL = FileManager.default.homeDirectoryForCurrentUser, since: Date) -> (projects: [ProjectTokens], credits: Double) {
        let rows = SQLiteReader.rows(database(home: home), """
            SELECT s.cwd, SUM(COALESCE(e.input_tokens, 0) + COALESCE(e.output_tokens, 0)), SUM(COALESCE(e.total_nano_aiu, 0))
            FROM assistant_usage_events e JOIN sessions s ON s.id = e.session_id
            WHERE e.created_at >= ? GROUP BY s.cwd
            """, [.text(iso(since))])
        let projects = rows.compactMap { row -> ProjectTokens? in
            let cwd = row[0].text, tokens = Int(row[1].int)
            guard !cwd.isEmpty, tokens > 0 else { return nil }
            return ProjectTokens(path: cwd, name: URL(fileURLWithPath: cwd).lastPathComponent, tokens: tokens)
        }
        let credits = rows.reduce(0) { $0 + Double($1[2].int) } / 1_000_000_000
        return (projects.sorted { $0.tokens > $1.tokens }, credits)
    }

    /// Projects and notes for the Copilot card: credits this week and the context of a session used today.
    static func extras(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now) -> (projects: [ProjectTokens], notes: [ServiceNote]) {
        let week = projects(home: home, since: now.addingTimeInterval(-7 * 86_400))
        var notes: [ServiceNote] = []
        if week.credits > 0 {
            notes.append(ServiceNote(text: String(localized: "AI-кредиты за неделю: \(week.credits.formatted(.number.precision(.fractionLength(0...2))))"), symbol: "creditcard"))
        }
        if let latest = recent(home: home, now: now, within: 86_400, limit: 1).first, let fill = latest.context {
            notes.append(ServiceNote(text: String(localized: "Контекст последней беседы в «\(latest.project)»: \(Int((fill * 100).rounded())) %"), symbol: "gauge.medium"))
        }
        return (week.projects, notes)
    }
}

/// Antigravity CLI's own records (checked on agy 1.4.12, 2026-11-02): `~/.gemini/antigravity-cli/conversation_summaries.db`,
/// table `conversation_summaries` — `conversation_id`, `title`, `workspace_uris` (a JSON list of `file://` URLs),
/// `last_modified_time` (`2026-11-02 15:14:09.924653+00:00`) and `status` (`CASCADE_RUN_STATUS_IDLE` / `…_RUNNING`). It
/// keeps no limits or token counts that can be read without decoding its protobuf blobs.
enum AntigravityConversations {
    static func database(home: URL) -> URL { home.appending(path: ".gemini/antigravity-cli/conversation_summaries.db") }

    /// UTC `yyyy-MM-dd HH:mm:ss`, which sorts as text against the stored times.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// `2026-11-02 15:14:09.924653+00:00` → a date (the fraction is cut to milliseconds).
    static func date(_ text: String) -> Date? {
        var value = text.replacingOccurrences(of: " ", with: "T")
        if let dot = value.firstIndex(of: "."), let zone = value[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = value[value.index(after: dot)..<zone].prefix(3)
            value = String(value[..<dot]) + "." + fraction + String(value[zone...])
        }
        return ISODate.parse(value)
    }

    static func recent(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now,
                       within: TimeInterval = 3 * 3600, limit: Int = 5) -> [AgentThread] {
        let rows = SQLiteReader.rows(database(home: home), """
            SELECT conversation_id, title, workspace_uris, last_modified_time, status FROM conversation_summaries
            WHERE last_modified_time >= ? AND parent_conversation_id = '' ORDER BY last_modified_time DESC LIMIT ?
            """, [.text(stamp(now.addingTimeInterval(-within))), .int(Int64(limit))])
        return rows.compactMap { row in
            let id = row[0].text
            let workspaces = (try? JSONSerialization.jsonObject(with: Data(row[2].text.utf8))) as? [String] ?? []
            guard !id.isEmpty, let updated = date(row[3].text),
                  let folder = workspaces.first.flatMap(URL.init(string:))?.path, !folder.isEmpty else { return nil }
            return AgentThread(agent: .antigravity, id: id, project: URL(fileURLWithPath: folder).lastPathComponent, folder: folder,
                               title: row[1].text, updatedAt: updated, context: nil, isWorking: row[4].text.contains("RUNNING"))
        }
    }
}
