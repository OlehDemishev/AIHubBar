import Foundation

/// A background `claude -p` run (docs/SPEC.md §2.4, «Фон»). Stored as `runs/<id>.json` next to its log `runs/<id>.log`.
/// The id doubles as Claude's `--session-id`, so the hook's session file has the same name.
struct BackgroundRun: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case running, succeeded, failed, stopped, timedOut

        var isFinished: Bool { self != .running }
    }

    var id: String
    var project: String
    var projectPath: String
    var folder: String
    var worktreeBranch: String?
    var commandTitle: String
    var task: String
    var startedAt: Date
    var timeLimitMinutes: Int
    var pid: Int32?
    var state: State
    var finishedAt: Date?
    var summary: String?
    var pullRequestURL: String?
    var notified: Bool
    /// A command of a folder mode writes this file (absolute path); the notification opens it.
    var resultFile: String?
    /// Paused by the limit guard (the process is stopped with SIGSTOP); paused time doesn't count toward the time limit.
    var pausedAt: Date? = nil
    var pausedSeconds: Double? = nil

    var isPaused: Bool { state == .running && pausedAt != nil }

    static var runsDirectory: URL { SessionFiles.supportDirectory.appending(path: "runs", directoryHint: .isDirectory) }
    var logURL: URL { Self.runsDirectory.appending(path: "\(id).log") }
    var metadataURL: URL { Self.runsDirectory.appending(path: "\(id).json") }

    func deadline(now: Date = .now) -> Date {
        let paused = (pausedSeconds ?? 0) + (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        return startedAt.addingTimeInterval(TimeInterval(timeLimitMinutes * 60) + paused)
    }
}

/// The parts of Claude's `--output-format stream-json` output ClaudePult uses (checked against a real run of 2.1.312).
enum StreamJSON {
    struct Outcome: Equatable, Sendable {
        var isError: Bool
        var subtype: String?
        var result: String?
        var deniedTools: [String]
    }

    /// A readable line for the run log window.
    struct Entry: Equatable, Sendable, Identifiable {
        enum Kind: Sendable { case text, tool, result, error }
        var id: Int
        var kind: Kind
        var text: String
    }

    /// The last `{"type":"result"}` event, or nil if the run ended without one (killed, crashed).
    static func outcome(fromLog text: String) -> Outcome? {
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"result\""), let event = object(line), event["type"] as? String == "result" else { continue }
            let denials = (event["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
            return Outcome(
                isError: event["is_error"] as? Bool ?? true,
                subtype: event["subtype"] as? String,
                result: event["result"] as? String,
                deniedTools: denials
            )
        }
        return nil
    }

    /// Assistant text, tool calls and the result as readable entries; other events are skipped.
    static func entries(fromLog text: String) -> [Entry] {
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let event = object(line) else { continue }
            switch event["type"] as? String {
            case "assistant":
                let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            entries.append(Entry(id: entries.count, kind: .text, text: text))
                        }
                    case "tool_use":
                        entries.append(Entry(id: entries.count, kind: .tool, text: toolLine(block)))
                    default: break
                    }
                }
            case "result":
                let isError = event["is_error"] as? Bool ?? false
                let text = (event["result"] as? String) ?? (event["subtype"] as? String ?? "")
                entries.append(Entry(id: entries.count, kind: isError ? .error : .result, text: text))
            default:
                break
            }
        }
        return entries
    }

    private static func toolLine(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let detail = (input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["description"]) as? String
        return detail.map { "\(name): \($0)" } ?? name
    }

    private static func object(_ line: Substring) -> [String: Any]? {
        guard line.first == "{" else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    /// First 1–3 non-empty lines of the result, at most ~300 characters.
    static func summary(_ result: String?) -> String? {
        guard let result else { return nil }
        let lines = result.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy { "-=#*_`".contains($0) } }
            .prefix(3)
        guard !lines.isEmpty else { return nil }
        var text = lines.joined(separator: "\n")
        if text.count > 300 { text = String(text.prefix(299)) + "…" }
        return text
    }

    /// The last GitHub pull request URL mentioned in the result.
    static func pullRequestURL(in text: String?) -> String? {
        guard let text else { return nil }
        let pattern = /https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/\d+/
        return text.matches(of: pattern).last.map { String($0.output) }
    }
}
