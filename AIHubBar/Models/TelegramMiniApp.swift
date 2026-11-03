import Foundation

// The Mini App's data (docs/specs/SPEC-telegram.md §10): what the page in Telegram gets from this Mac, and what it may
// ask. Pure and Codable, so the tests read it as JSON; `TelegramBotController` fills it from the same stores as the bot.

/// Everything the page shows, in one answer to `state`.
struct MiniAppState: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        var title: String
        var percent: Double?
        var detail: String?
        var resetsAt: Date?
        var runsOutAt: Date?
    }

    struct Service: Codable, Equatable, Sendable {
        var title: String
        var windows: [Window]
        var error: String?
        var stale: Bool
    }

    struct Session: Codable, Equatable, Sendable {
        var project: String
        var agent: String
        var waiting: Bool
        var detail: String?
        var since: Date?
    }

    struct Request: Codable, Equatable, Sendable {
        var id: String
        var project: String
        var tool: String
        var summary: String
        var task: String?
    }

    struct Project: Codable, Equatable, Sendable {
        var key: String
        var name: String
    }

    struct Run: Codable, Equatable, Sendable {
        var id: String
        var project: String
        var task: String
        var state: String
        var paused: Bool
        var startedAt: Date
        var pr: String?
    }

    struct Command: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var confirm: Bool
    }

    struct Event: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var on: Bool
    }

    var mac: String
    var freeBytes: Int64?
    /// Nil when «Не спать» isn't installed.
    var keepAwake: Bool?
    /// A report or cleanup running now.
    var job: String?
    var sessions: [Session]
    var requests: [Request]
    var canAnswer: Bool
    var services: [Service]
    var projects: [Project]
    var runs: [Run]
    var tasksAllowed: Bool
    var commands: [Command]
    var commandsAllowed: Bool
    var events: [Event]
    var quiet: QuietHours?
    var quietPresets: [QuietHours]
    var mutedUntil: Date?
    var hasDailyReport: Bool
}

/// The page's call: an action and its parameters, as the relay passes them on.
struct MiniAppCall: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case state
        case answer(id: String, allow: Bool)
        case report(ai: Bool, hours: Double?)
        case cleanup(run: Bool)
        case task(project: String, text: String)
        case taskForce(project: String), taskAfterReset(project: String), taskWorktree(project: String)
        case stopRun(id: String)
        case log(id: String)
        case command(id: String)
        case event(BotEvent, on: Bool)
        case quiet(QuietHours?)
        case mute(Bool)
        case keepAwake(Bool)
    }

    var action: Action

    /// Nil for an unknown action or parameters that don't fit; ids are checked like the bot's buttons.
    init?(action name: String, parameters data: Data) {
        let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { p[key] as? String }
        func id(_ key: String, _ valid: (String) -> Bool) -> String? { string(key).flatMap { valid($0) ? $0 : nil } }
        func projectKey() -> String? { id("project") { $0.count == 8 && $0.allSatisfy(\.isHexDigit) } }
        switch name {
        case "state": action = .state
        case "answer":
            guard let request = id("id", ApprovalFiles.isValidID), let allow = p["allow"] as? Bool else { return nil }
            action = .answer(id: request, allow: allow)
        case "report":
            let hours = (p["hours"] as? NSNumber)?.doubleValue
            if let hours, !(0.25...168).contains(hours) { return nil }
            action = .report(ai: p["ai"] as? Bool ?? true, hours: hours)
        case "cleanup": action = .cleanup(run: p["run"] as? Bool ?? false)
        case "task":
            guard let project = projectKey(),
                  let text = string("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 4000 else { return nil }
            action = .task(project: project, text: text)
        case "taskForce", "taskAfterReset", "taskWorktree":
            guard let project = projectKey() else { return nil }
            action = name == "taskForce" ? .taskForce(project: project) : name == "taskAfterReset" ? .taskAfterReset(project: project) : .taskWorktree(project: project)
        case "stopRun", "log", "command":
            guard let value = id("id", BotMenuItem.isCommandID) else { return nil }
            action = name == "stopRun" ? .stopRun(id: value) : name == "log" ? .log(id: value) : .command(id: value)
        case "event":
            guard let event = string("id").flatMap(BotEvent.init(rawValue:)), let on = p["on"] as? Bool else { return nil }
            action = .event(event, on: on)
        case "quiet":
            if p["from"] == nil || p["from"] is NSNull {
                action = .quiet(nil)
            } else {
                guard let from = p["from"] as? Int, let to = p["to"] as? Int, QuietHours.presets.contains(QuietHours(from: from, to: to)) else { return nil }
                action = .quiet(QuietHours(from: from, to: to))
            }
        case "mute":
            guard let on = p["on"] as? Bool else { return nil }
            action = .mute(on)
        case "keepAwake":
            guard let on = p["on"] as? Bool else { return nil }
            action = .keepAwake(on)
        default: return nil
        }
    }
}

/// The answer to every call: `ok`, a note to show, the new state, a question to ask (a task's 90 % limit or a busy
/// folder), a log tail.
struct MiniAppReply: Codable, Equatable, Sendable {
    struct Question: Codable, Equatable, Sendable {
        var text: String
        /// true: «Всё равно» / «После сброса»; false: «Да, в worktree».
        var limit: Bool
        var project: String
    }

    struct LogLine: Codable, Equatable, Sendable {
        var kind: String
        var text: String
    }

    var ok: Bool
    var error: String?
    var note: String?
    var state: MiniAppState?
    var question: Question?
    var log: [LogLine]?

    static func failure(_ text: String) -> MiniAppReply { MiniAppReply(ok: false, error: text) }

    var json: Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(self)) ?? Data(#"{"ok":false}"#.utf8)
    }

    /// The log's last steps, newest last.
    static func logLines(_ entries: [StreamJSON.Entry]) -> [LogLine] {
        entries.suffix(30).map { entry in
            let kind = switch entry.kind {
            case .text: "text"
            case .tool: "tool"
            case .result: "result"
            case .error: "error"
            }
            return LogLine(kind: kind, text: String(entry.text.prefix(400)))
        }
    }
}
