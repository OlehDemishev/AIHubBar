import Foundation

/// Codex's own records on this Mac (SPEC-ai-services stage 3): its threads in `~/.codex/state_<N>.sqlite` (table
/// `threads`: `cwd`, `tokens_used`, `updated_at`, `rollout_path`, `archived` — the schema checked on Codex 0.166,
/// 2026-11-02) and each thread's log (`rollout-*.jsonl`), whose `token_count` events say how full the context is.
/// Read only; nothing is written.
enum CodexThreads {
    struct Thread: Equatable, Sendable {
        var id: String = ""
        var title: String = ""
        var cwd: String
        var tokens: Int
        var updatedAt: Date
        var rolloutPath: String
    }

    /// The newest state database (`state_5.sqlite` today; the number grows with Codex's schema).
    static func database(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let folder = home.appending(path: ".codex")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let numbered = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let number = Int(name.dropFirst("state_".count).dropLast(".sqlite".count)) else { return nil }
            return (number, name)
        }
        return numbered.max { $0.0 < $1.0 }.map { folder.appending(path: $0.1) }
    }

    /// Threads not archived and updated since `since`, newest first.
    static func threads(in database: URL, since: Date) -> [Thread] {
        SQLiteReader.rows(database, """
            SELECT cwd, tokens_used, updated_at, rollout_path, id, title FROM threads
            WHERE archived = 0 AND updated_at >= ? ORDER BY updated_at DESC
            """, [.int(Int64(since.timeIntervalSince1970))]).map { row in
            Thread(id: row[4].text, title: row[5].text, cwd: row[0].text, tokens: Int(row[1].int),
                   updatedAt: Date(timeIntervalSince1970: TimeInterval(row[2].int)), rolloutPath: row[3].text)
        }
    }

    /// Tokens per project folder, most first. A thread counts whole: Codex keeps one total per thread.
    static func projects(_ threads: [Thread]) -> [ProjectTokens] {
        Dictionary(grouping: threads.filter { !$0.cwd.isEmpty && $0.tokens > 0 }, by: \.cwd)
            .map { cwd, threads in
                ProjectTokens(path: cwd, name: URL(fileURLWithPath: cwd).lastPathComponent, tokens: threads.reduce(0) { $0 + $1.tokens })
            }
            .sorted { $0.tokens > $1.tokens }
    }

    /// How full the context was at the thread's last request, 0…1, from the end of its log.
    static func context(rollout: URL, tail: Int = 256 * 1024) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: rollout) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tail) ? size - UInt64(tail) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            if let fill = contextFill(Data(line)) { return fill }
        }
        return nil
    }

    /// A log line `{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{…},
    /// "model_context_window":N}}}`: the last request's tokens without reasoning over the window, as Codex's own
    /// status line counts it.
    static func contextFill(_ line: Data) -> Double? {
        guard let object = HubParse.object(line), let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = (info["last_token_usage"] ?? info["lastTokenUsage"]) as? [String: Any],
              let window = HubParse.number(info["model_context_window"] ?? info["modelContextWindow"]), window > 0,
              let total = HubParse.number(last["total_tokens"] ?? last["totalTokens"]) else { return nil }
        let reasoning = HubParse.number(last["reasoning_output_tokens"] ?? last["reasoningOutputTokens"]) ?? 0
        return min(max((total - reasoning) / window, 0), 1)
    }

    /// The plan and credits from the same `account/rateLimits/read` answer as the limits (`rateLimits.planType`,
    /// `rateLimits.credits {hasCredits, unlimited, balance}`).
    static func accountNotes(_ data: Data) -> [ServiceNote] {
        guard let object = HubParse.object(data) else { return [] }
        let result = object["result"] as? [String: Any] ?? object
        guard let limits = (result["rateLimits"] ?? result["rate_limits"]) as? [String: Any] else { return [] }
        var notes: [ServiceNote] = []
        if let plan = (limits["planType"] ?? limits["plan_type"]) as? String, !plan.isEmpty {
            notes.append(ServiceNote(text: String(localized: "План: \(plan.capitalized)"), symbol: "person.crop.circle"))
        }
        if let credits = limits["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true {
                notes.append(ServiceNote(text: String(localized: "Кредиты: без ограничений"), symbol: "creditcard"))
            } else if let balance = credits["balance"].flatMap({ $0 is NSNull ? nil : $0 }), let amount = HubParse.number(balance) {
                notes.append(ServiceNote(text: String(localized: "Кредиты: \(amount.formatted(.number.precision(.fractionLength(0...2))))"), symbol: "creditcard"))
            }
        }
        return notes
    }

    /// Threads updated in the last `within` seconds (3 hours), newest first, at most `limit` (SPEC-ai-services stage 5).
    static func recent(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now,
                       within: TimeInterval = 3 * 3600, limit: Int = 5) -> [AgentThread] {
        guard let database = database(home: home) else { return [] }
        return threads(in: database, since: now.addingTimeInterval(-within)).prefix(limit).map { thread in
            AgentThread(
                agent: .codex, id: thread.id, project: URL(fileURLWithPath: thread.cwd).lastPathComponent, folder: thread.cwd,
                title: thread.title, updatedAt: thread.updatedAt,
                context: thread.rolloutPath.isEmpty ? nil : context(rollout: URL(fileURLWithPath: thread.rolloutPath))
            )
        }
    }

    /// What Codex adds beyond its limits: tokens per project this week and the context of a thread used today.
    static func extras(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now) -> (projects: [ProjectTokens], notes: [ServiceNote]) {
        guard let database = database(home: home) else { return ([], []) }
        let threads = threads(in: database, since: now.addingTimeInterval(-7 * 86_400))
        var notes: [ServiceNote] = []
        if let latest = threads.first, now.timeIntervalSince(latest.updatedAt) < 86_400,
           let fill = context(rollout: URL(fileURLWithPath: latest.rolloutPath)) {
            let name = URL(fileURLWithPath: latest.cwd).lastPathComponent
            notes.append(ServiceNote(text: String(localized: "Контекст последней беседы в «\(name)»: \(Int((fill * 100).rounded())) %"), symbol: "gauge.medium"))
        }
        return (projects(threads), notes)
    }
}
