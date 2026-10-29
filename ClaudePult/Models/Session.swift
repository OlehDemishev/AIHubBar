import Foundation

/// Paths shared by the app and the hook script.
enum SessionFiles {
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/ClaudePult", directoryHint: .isDirectory)
    static let sessionsDirectory = supportDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    static let hookScriptURL = supportDirectory.appending(path: "hooks/claudepult-hook.py")
}

/// One Claude Code session as written by the hook to `sessions/<session_id>.json` (format version 1).
struct Session: Decodable, Identifiable, Equatable, Sendable {
    enum State: String, Decodable, Sendable {
        case running, waiting, done, ended, error, unknown

        init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    var id: String
    var cwd: String
    var project: String?
    var projectPath: String?
    var state: State
    var event: String?
    var startedAt: Date?
    var updatedAt: Date
    var firstPrompt: String?
    var lastPrompt: String?
    var message: String?
    var transcriptPath: String?
    var claudePID: Int32?
    var tty: String?
    var termProgram: String?
    var entrypoint: String?

    enum CodingKeys: String, CodingKey {
        case cwd, project, state, event, message, tty, entrypoint
        case id = "session_id"
        case projectPath = "project_path"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case firstPrompt = "first_prompt"
        case lastPrompt = "last_prompt"
        case transcriptPath = "transcript_path"
        case claudePID = "claude_pid"
        case termProgram = "term_program"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cwd = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        project = try? c.decodeIfPresent(String.self, forKey: .project)
        projectPath = try? c.decodeIfPresent(String.self, forKey: .projectPath)
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .unknown
        event = try? c.decodeIfPresent(String.self, forKey: .event)
        startedAt = c.isoDate(.startedAt)
        updatedAt = c.isoDate(.updatedAt) ?? .distantPast
        firstPrompt = try? c.decodeIfPresent(String.self, forKey: .firstPrompt)
        lastPrompt = try? c.decodeIfPresent(String.self, forKey: .lastPrompt)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
        claudePID = try? c.decodeIfPresent(Int32.self, forKey: .claudePID)
        tty = try? c.decodeIfPresent(String.self, forKey: .tty)
        termProgram = try? c.decodeIfPresent(String.self, forKey: .termProgram)
        entrypoint = try? c.decodeIfPresent(String.self, forKey: .entrypoint)
    }

    /// Project name, or the last folder of `cwd` for sessions outside the projects folder.
    var displayProject: String {
        project ?? (cwd as NSString).lastPathComponent
    }

    /// Worktree name when the session runs in `<project>/.claude/worktrees/<name>`.
    var worktreeName: String? {
        guard let range = cwd.range(of: "/.claude/worktrees/") else { return nil }
        return cwd[range.upperBound...].split(separator: "/").first.map(String.init)
    }

    /// The task: the first prompt of the session, else the latest one. Prompts sent by ClaudePult's own commands
    /// are shown without their wrapper («Задача от Олега: …. Работай по правилам …»).
    var task: String? {
        [firstPrompt, lastPrompt].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .map(Self.taskTitle)
    }

    static func taskTitle(_ prompt: String) -> String {
        // The hook keeps 200 characters with whitespace collapsed; compare the same way.
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let text = normalized(prompt)
        for command in [ClaudeCommand.nextStep, .finishSession] where normalized(command.prompt).hasPrefix(text.prefix(60)) {
            return command.title
        }
        let wrapper = "Задача от Олега: "
        guard text.hasPrefix(wrapper) else { return text }
        var task = String(text.dropFirst(wrapper.count))
        if let rules = task.range(of: ". Работай по правилам") { task = String(task[..<rules.lowerBound]) }
        return task
    }

    /// Opened in Terminal.app, so «Показать» can bring its tab forward by tty.
    var isInTerminalApp: Bool {
        termProgram == "Apple_Terminal" && tty != nil
    }
}

/// Which sessions the panel shows and how (docs/SPEC.md §2.3).
enum SessionRules {
    /// No events for this long and no live process → stale, hidden.
    static let staleAfter: TimeInterval = 2 * 3600
    /// Ended sessions stay visible for a while so a finished task can still be seen.
    static let keepEndedFor: TimeInterval = 15 * 60
    /// Session files older than this are deleted.
    static let deleteAfter: TimeInterval = 7 * 86_400

    /// The state to show: a session whose process is gone counts as ended.
    static func effectiveState(_ session: Session, isAlive: Bool?) -> Session.State {
        if session.state != .ended, isAlive == false { return .ended }
        return session.state
    }

    static func isVisible(_ session: Session, isAlive: Bool?, now: Date) -> Bool {
        let age = now.timeIntervalSince(session.updatedAt)
        switch effectiveState(session, isAlive: isAlive) {
        case .ended:
            return age < keepEndedFor
        default:
            // Without a known process, rely on recent activity only.
            return isAlive == true || age < staleAfter
        }
    }

    /// Waiting first, then running, then the rest; newest activity first within a group.
    static func sorted(_ sessions: [(session: Session, state: Session.State)]) -> [(session: Session, state: Session.State)] {
        func rank(_ state: Session.State) -> Int {
            switch state {
            case .waiting: 0
            case .running: 1
            case .error: 2
            case .done: 3
            case .unknown: 4
            case .ended: 5
            }
        }
        return sessions.sorted {
            rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state) : $0.session.updatedAt > $1.session.updatedAt
        }
    }
}
