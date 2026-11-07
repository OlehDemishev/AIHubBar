import Foundation

/// Paths shared by the app and the hook script.
enum SessionFiles {
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/ClaudePult", directoryHint: .isDirectory)
    static let sessionsDirectory = supportDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    static let hookScriptURL = supportDirectory.appending(path: "hooks/claudepult-hook.py")
}

/// One step of Claude Code's task list (`TodoWrite`, `TaskCreate` / `TaskUpdate`), as the hook keeps it.
struct SessionTodo: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case pending, inProgress = "in_progress", completed

        init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pending
        }
    }

    var content: String
    var status: Status
    /// «Пишет тесты»: what Claude shows while the step is in progress.
    var activeForm: String?

    enum CodingKeys: String, CodingKey {
        case content, status
        case activeForm = "active_form"
    }

    init(content: String, status: Status, activeForm: String? = nil) {
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .pending
        activeForm = try? c.decodeIfPresent(String.self, forKey: .activeForm)
    }

    /// The words for the step: while in progress its `activeForm`, else its title.
    var text: String {
        if status == .inProgress, let activeForm, !activeForm.isEmpty { return activeForm }
        return content
    }
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
    /// The last tool call (PostToolUse): «what Claude is doing now».
    var lastTool: String?
    var lastTarget: String?
    var lastToolAt: Date?
    /// Claude's task list for the current request (SPEC-notch §3.4); empty when it made none.
    var todos: [SessionTodo] = []
    /// When the last request was sent (UserPromptSubmit).
    var promptAt: Date?
    /// Whose session: Claude Code, or Copilot / Codex CLI through the same hook (`CopilotHooks`, `CodexHooks`).
    var agent: AgentKind = .claudeCode

    enum CodingKeys: String, CodingKey {
        case cwd, project, state, event, message, tty, entrypoint, agent
        case lastTool = "last_tool"
        case lastTarget = "last_target"
        case lastToolAt = "last_tool_at"
        case todos
        case promptAt = "prompt_at"
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
        lastTool = try? c.decodeIfPresent(String.self, forKey: .lastTool)
        lastTarget = try? c.decodeIfPresent(String.self, forKey: .lastTarget)
        lastToolAt = c.isoDate(.lastToolAt)
        todos = (try? c.decodeIfPresent([SessionTodo].self, forKey: .todos)) ?? []
        promptAt = c.isoDate(.promptAt)
        agent = (try? c.decodeIfPresent(AgentKind.self, forKey: .agent)) ?? .claudeCode
    }

    /// «Claude», «Copilot»: who waits or works, in notifications and hints.
    var agentName: String {
        switch agent {
        case .claudeCode: "Claude"
        case .copilot: "Copilot"
        case .codex: "Codex"
        default: agent.binary
        }
    }

    /// Steps done and all steps of the task list; nil without one.
    var progress: (done: Int, total: Int)? {
        todos.isEmpty ? nil : (todos.filter { $0.status == .completed }.count, todos.count)
    }

    /// The step in progress.
    var currentTodo: SessionTodo? { todos.first { $0.status == .inProgress } }

    /// «правит LimitsView.swift», «запускает npm test», «ищет TODO»: the last tool call in words.
    var actionText: String? {
        guard let tool = lastTool, !tool.isEmpty else { return nil }
        let target = lastTarget ?? ""
        let verb: String = switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": String(localized: "правит")
        case "Read": String(localized: "читает")
        case "Bash", "BashOutput": String(localized: "запускает")
        case "Grep", "Glob", "ToolSearch": String(localized: "ищет")
        case "WebFetch", "WebSearch": String(localized: "смотрит в сети")
        case "Agent", "Task": String(localized: "работает с агентом")
        case "TodoWrite", "TaskCreate", "TaskUpdate": String(localized: "обновляет план")
        default: tool.hasPrefix("mcp__") ? String(localized: "инструмент") + " " + (tool.split(separator: "_").last.map(String.init) ?? tool) : tool
        }
        return target.isEmpty ? verb : "\(verb) \(target)"
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

    /// The task: the first prompt of the session, else the latest one. Prompts sent by AI Hub Bar's own commands
    /// are shown without their wrapper («Задача: …. Работай по правилам …»).
    var task: String? {
        [firstPrompt, lastPrompt].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .map(Self.taskTitle)
    }

    static func taskTitle(_ prompt: String) -> String {
        // The hook keeps 200 characters with whitespace collapsed; compare the same way.
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let text = normalized(prompt)
        for command in [ClaudeCommand.nextStep, .finishSession] {
            for style in [PromptStyle.workspace, .generic] {
                for language in ContentLanguage.allCases where normalized(command.prompt(style, language: language)).hasPrefix(text.prefix(60)) {
                    return command.title
                }
            }
        }
        // Sessions started by older versions keep their old wrapper.
        let wrappers = ["Задача от Олега: "] + ContentLanguage.allCases.map(\.strings.taskPrefix)
        guard let wrapper = wrappers.first(where: text.hasPrefix) else { return text }
        var task = String(text.dropFirst(wrapper.count))
        for marker in ContentLanguage.allCases.map(\.strings.rulesMarker) {
            if let rules = task.range(of: marker) { task = String(task[..<rules.lowerBound]) }
        }
        return task
    }

    /// Opened in Terminal.app, so «Показать» can bring its tab forward by tty.
    var isInTerminalApp: Bool {
        termProgram == "Apple_Terminal" && tty != nil
    }
}

/// Which sessions the panel shows and how (docs/specs/SPEC.md §2.3).
enum SessionRules {
    /// No events for this long and no live process → stale, hidden.
    static let staleAfter: TimeInterval = 2 * 3600
    /// Ended sessions stay visible for a while so a finished task can still be seen.
    static let keepEndedFor: TimeInterval = 15 * 60
    /// Session files older than this are deleted.
    static let deleteAfter: TimeInterval = 7 * 86_400

    /// How many finished sessions the panel offers to continue.
    static let resumableCount = 5

    /// A finished Claude Code session that has left the list and can still be continued: its folder is there and
    /// nothing runs it. (Other agents have their own list, `AgentThread`.)
    static func isResumable(_ session: Session, isAlive: Bool?, now: Date, folderExists: Bool) -> Bool {
        guard folderExists, isAlive != true, session.agent == .claudeCode else { return false }
        return !isVisible(session, isAlive: isAlive, now: now)
    }

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

    /// Waiting first, then running, then the rest. Inside a group rows stay put, so a button isn't swapped under the
    /// pointer: the oldest request first (a new one joins below it), the others by when they started, not by activity.
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
        return sessions.sorted { a, b in
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            if a.state == .waiting, a.session.updatedAt != b.session.updatedAt { return a.session.updatedAt < b.session.updatedAt }
            let (first, second) = (a.session.startedAt ?? a.session.updatedAt, b.session.startedAt ?? b.session.updatedAt)
            return first != second ? first > second : a.session.id < b.session.id
        }
    }
}
