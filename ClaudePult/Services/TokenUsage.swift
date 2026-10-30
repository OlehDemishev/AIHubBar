import Foundation

/// Token use per project and session from Claude Code's local transcripts (`~/.claude/projects/**/*.jsonl`,
/// `usage` of assistant messages). The format is undocumented: lines are parsed tolerantly and anything unknown
/// is skipped. This is an estimate of how usage is distributed, not the plan's own accounting (spec §2.8).
struct TokenRecord: Equatable, Sendable {
    var date: Date
    var sessionID: String
    var cwd: String
    var model: String?
    var input: Int
    var output: Int
    var cacheCreation: Int
    var cacheRead: Int

    /// Tokens shown to the user: input, output and cache writes. Cache reads are left out — they dwarf
    /// everything else (hundreds of millions per day) while costing a tenth; they still count in `weight`.
    var total: Int { input + output + cacheCreation }

    /// Rough weight of a message against the limits, in "input-token equivalents" — output and cache writes
    /// cost more than input, cache reads much less (relative API prices). Used only to rank and share.
    var weight: Double { Double(input) + Double(output) * 5 + Double(cacheCreation) * 1.25 + Double(cacheRead) * 0.1 }
}

enum TokenLog {
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects") }

    /// One assistant message with usage, or nil. Streaming writes the same message (same `message.id`) on several
    /// lines with the same usage, so the id is returned for de-duplication.
    static func parse(line: Substring) -> (id: String, record: TokenRecord)? {
        parse(data: Data(line.utf8))
    }

    private static let usageNeedle = Data("\"usage\"".utf8)
    private static let assistantNeedle = Data("\"assistant\"".utf8)

    static func parse(data line: Data) -> (id: String, record: TokenRecord)? {
        // Cheap byte filter before JSON: most lines are tool output or user messages.
        guard line.range(of: usageNeedle) != nil, line.range(of: assistantNeedle) != nil else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestamp = (object["timestamp"] as? String).flatMap(ISODate.parse)
        else { return nil }
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let record = TokenRecord(
            date: timestamp,
            sessionID: object["sessionId"] as? String ?? "",
            cwd: object["cwd"] as? String ?? "",
            model: message["model"] as? String,
            input: int("input_tokens"), output: int("output_tokens"),
            cacheCreation: int("cache_creation_input_tokens"), cacheRead: int("cache_read_input_tokens")
        )
        guard record.total + record.cacheRead > 0 else { return nil }
        let id = (message["id"] as? String) ?? (object["requestId"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
        return (id, record)
    }

    /// Project name for a working directory: the first folder under the projects folder (worktrees included).
    static func project(of cwd: String, projectsDirectory: String) -> String {
        let root = (projectsDirectory as NSString).standardizingPath
        let path = (cwd as NSString).standardizingPath
        guard path.hasPrefix(root + "/") else { return String(localized: "Другое") }
        return path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init) ?? String(localized: "Другое")
    }
}

/// Reads the transcripts incrementally: each file is read from where the previous scan stopped.
actor TokenScanner {
    private var offsets: [String: UInt64] = [:]
    private var records: [String: TokenRecord] = [:]

    /// Scans files changed within `days` and returns all known records since `since`.
    func scan(directory: URL = TokenLog.directory, days: Double = 8, since: Date) -> [TokenRecord] {
        let cutoff = Date.now.addingTimeInterval(-days * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified > cutoff else { continue }
            readNewLines(url, size: UInt64(values.fileSize ?? 0))
        }
        records = records.filter { $0.value.date > cutoff }
        return records.values.filter { $0.date >= since }
    }

    private func readNewLines(_ url: URL, size: UInt64) {
        var offset = offsets[url.path] ?? 0
        if size < offset { offset = 0 } // rewritten file
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only complete lines; a half-written last line is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        var start = data.startIndex
        while start <= lastNewline, let end = data[start...lastNewline].firstIndex(of: 0x0A) {
            if end > start, let (id, record) = TokenLog.parse(data: data[start..<end]) { records[id] = record }
            start = end + 1
        }
        offsets[url.path] = offset + UInt64(lastNewline - data.startIndex + 1)
    }
}

/// Totals for one period: per project and the heaviest session.
struct TokenBreakdown: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        var name: String
        var tokens: Int
        var share: Double
        var id: String { name }
    }

    struct TopSession: Equatable, Sendable {
        var sessionID: String
        var project: String
        var tokens: Int
        var share: Double
    }

    var projects: [Row]
    var topSession: TopSession?
    var totalTokens: Int

    static func make(_ records: [TokenRecord], since: Date, projectsDirectory: String) -> TokenBreakdown {
        let period = records.filter { $0.date >= since }
        let totalWeight = period.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return TokenBreakdown(projects: [], topSession: nil, totalTokens: 0) }

        var byProject: [String: (tokens: Int, weight: Double)] = [:]
        var bySession: [String: (project: String, tokens: Int, weight: Double)] = [:]
        for record in period {
            let project = TokenLog.project(of: record.cwd, projectsDirectory: projectsDirectory)
            byProject[project, default: (0, 0)].tokens += record.total
            byProject[project, default: (0, 0)].weight += record.weight
            bySession[record.sessionID, default: (project, 0, 0)].tokens += record.total
            bySession[record.sessionID, default: (project, 0, 0)].weight += record.weight
        }
        let rows = byProject
            .map { Row(name: $0.key, tokens: $0.value.tokens, share: $0.value.weight / totalWeight) }
            .sorted { $0.share > $1.share }
        let top = bySession.max { $0.value.weight < $1.value.weight }.map {
            TopSession(sessionID: $0.key, project: $0.value.project, tokens: $0.value.tokens, share: $0.value.weight / totalWeight)
        }
        return TokenBreakdown(projects: rows, topSession: top, totalTokens: period.reduce(0) { $0 + $1.total })
    }

    /// «12,3 млн», «850 тыс.».
    static func tokensText(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: (Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(1))) + String(localized: " млн")
        case 1_000...: String(localized: "\(tokens / 1_000) тыс.")
        default: "\(tokens)"
        }
    }
}
