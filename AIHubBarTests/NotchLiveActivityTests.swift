import Foundation
import Testing
@testable import AIHubBar

/// SPEC-notch stage 4: a working session's task list in the island. The hook payloads follow Claude Code 2.1.314:
/// `TodoWrite` sends `todos` [{content, status, activeForm}]; `TaskCreate` sends {subject, activeForm} and answers
/// {task: {id, subject}}; `TaskUpdate` sends {taskId, status (or "deleted"), subject, activeForm}.
struct NotchLiveActivityTests {
    private func runHook(_ events: [[String: Any]]) async throws -> Session {
        let dir = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "claudepult-hook.py")
        try HookScript.write(to: script)
        for event in events {
            let base: [String: Any] = ["session_id": "s-1", "cwd": "/Users/me/Projects/Ambo", "transcript_path": "/t.jsonl"]
            _ = try await ProcessRunner.run(
                script.path, ["--projects-dir", "/Users/me/Projects", "--sessions-dir", dir.appending(path: "sessions").path],
                input: try JSONSerialization.data(withJSONObject: base.merging(event) { $1 }), timeout: .seconds(10)
            )
        }
        return try JSONDecoder().decode(Session.self, from: Data(contentsOf: dir.appending(path: "sessions/s-1.json")))
    }

    private static func todoWrite(_ statuses: [String]) -> [String: Any] {
        let todos = statuses.enumerated().map { index, status in
            ["content": "Шаг \(index + 1)", "status": status, "activeForm": "Делает шаг \(index + 1)"]
        }
        return ["hook_event_name": "PostToolUse", "tool_name": "TodoWrite", "tool_input": ["todos": todos],
                "tool_response": ["oldTodos": [], "newTodos": todos]]
    }

    private static func taskCreate(_ id: String, _ subject: String) -> [String: Any] {
        ["hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
         "tool_input": ["subject": subject, "description": "…", "activeForm": "Делает: \(subject)"],
         "tool_response": ["task": ["id": id, "subject": subject]]]
    }

    private static func taskUpdate(_ id: String, _ status: String) -> [String: Any] {
        ["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_input": ["taskId": id, "status": status]]
    }

    @Test func todoWriteReplacesTheList() async throws {
        // Two lists in a row with the same tool: the second must not be skipped as «the same action».
        let session = try await runHook([
            ["hook_event_name": "UserPromptSubmit", "prompt": "Почини тесты"],
            Self.todoWrite(["in_progress", "pending", "pending"]),
            Self.todoWrite(["completed", "completed", "in_progress"]),
        ])
        #expect(session.todos.map(\.status) == [.completed, .completed, .inProgress])
        #expect(session.progress?.done == 2 && session.progress?.total == 3)
        #expect(session.currentTodo?.text == "Делает шаг 3", "the step in progress reads as its activeForm")
        #expect(session.todos[0].text == "Шаг 1")
        #expect(session.promptAt != nil)
        #expect(session.actionText == "обновляет план")
    }

    @Test func tasksOneByOne() async throws {
        let session = try await runHook([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            Self.taskCreate("1", "Прочитать код"),
            Self.taskCreate("2", "Написать тесты"),
            Self.taskCreate("3", "Лишнее"),
            Self.taskUpdate("1", "completed"),
            Self.taskUpdate("2", "in_progress"),
            Self.taskUpdate("3", "deleted"),
            Self.taskUpdate("9", "completed"),
        ])
        #expect(session.todos.map(\.content) == ["Прочитать код", "Написать тесты"])
        #expect(session.todos.map(\.status) == [.completed, .inProgress])
        #expect(session.currentTodo?.text == "Делает: Написать тесты")
    }

    @Test func whenTheListGoes() async throws {
        let finished = try await runHook([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            Self.todoWrite(["completed", "completed"]),
            ["hook_event_name": "Stop"],
        ])
        #expect(finished.todos.count == 2, "Stop keeps the list for «Готово»")

        let next = try await runHook([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            Self.todoWrite(["completed", "completed"]),
            ["hook_event_name": "Stop"],
            ["hook_event_name": "UserPromptSubmit", "prompt": "ещё"],
        ])
        #expect(next.todos.isEmpty, "a new request after a finished list starts clean")

        let unfinished = try await runHook([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            Self.todoWrite(["completed", "pending"]),
            ["hook_event_name": "Stop"],
            ["hook_event_name": "UserPromptSubmit", "prompt": "продолжай"],
        ])
        #expect(unfinished.todos.count == 2, "an unfinished list carries on")

        let ended = try await runHook([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            Self.todoWrite(["pending"]),
            ["hook_event_name": "SessionEnd", "reason": "exit"],
        ])
        #expect(ended.todos.isEmpty)
    }

    @Test func longListsAreCut() async throws {
        let session = try await runHook([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            Self.todoWrite(Array(repeating: "pending", count: 25)),
        ])
        #expect(session.todos.count == 20)
    }

    @Test func olderRecordsHaveNoList() throws {
        let object: [String: Any] = ["session_id": "s", "updated_at": "2026-11-02T19:00:00+01:00", "todos": [["content": "a", "status": "odd"]]]
        let session = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(session.todos.first?.status == .pending, "an unknown status reads as pending")
        let bare = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: ["session_id": "s"]))
        #expect(bare.todos.isEmpty && bare.progress == nil && bare.promptAt == nil)
    }

    private func item(_ id: String, _ state: Session.State, promptAt: String?, todos: [[String: Any]] = []) throws -> SessionStore.Item {
        var object: [String: Any] = ["session_id": id, "cwd": "/p/\(id)", "updated_at": "2026-11-02T19:00:00+01:00", "todos": todos]
        if let promptAt { object["prompt_at"] = promptAt }
        let session = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object))
        return SessionStore.Item(session: session, state: state)
    }

    @Test func theEarFollowsTheLatestRequest() throws {
        let items = [
            try item("old", .running, promptAt: "2026-11-02T18:00:00+01:00"),
            try item("new", .running, promptAt: "2026-11-02T18:30:00+01:00"),
            try item("idle", .done, promptAt: "2026-11-02T18:50:00+01:00"),
        ]
        #expect(NotchText.featured(items)?.id == "new")
        #expect(NotchText.featured(items.filter { $0.state != .running }) == nil)
        // An older hook's session (no request time) that just used a tool doesn't take the ear.
        var busy = try item("busy", .running, promptAt: nil)
        busy.session.startedAt = ISODate.parse("2026-11-02T17:00:00+01:00")
        busy.session.updatedAt = .now
        #expect(NotchText.featured(items + [busy])?.id == "new")
    }

    @Test func words() throws {
        let todos: [[String: Any]] = [
            ["content": "Прочитать", "status": "completed"],
            ["content": "Написать тесты", "status": "in_progress", "active_form": "Пишет тесты"],
            ["content": "Проверить", "status": "pending"],
        ]
        let working = try item("ClaudePult", .running, promptAt: "2026-11-02T18:56:00+01:00", todos: todos)
        let now = try #require(ISODate.parse("2026-11-02T19:00:30+01:00"))
        #expect(NotchText.activity(working.session, now: now) == "ClaudePult: сделано 1 из 3, Пишет тесты, 4 мин")
        let summary = NotchText.earSummary(.sessions, main: nil, sessions: [working], background: 0, liveActivity: true, now: now)
        #expect(summary.hasPrefix("ClaudePult: сделано 1 из 3"))
        #expect(NotchText.earSummary(.sessions, main: nil, sessions: [working], background: 0) == "Ждут ответа: 0, работают: 1",
                "with the live activity off, as before")
        #expect(NotchText.minutes(from: now, to: now.addingTimeInterval(-30)) == 0)
        #expect(NotchText.minutes(from: now, to: now.addingTimeInterval(125)) == 2)

        #expect(NotchText.finishedBody(progress: (7, 7), duration: "12 мин", files: 5) == "7/7 · 12 мин · файлов: 5")
        #expect(NotchText.finishedBody(progress: nil, duration: "45 с", files: 0) == "45 с", "no list and no files: just the time")
        #expect(NotchText.stepLabel(SessionTodo(content: "x", status: .inProgress, activeForm: "Пишет тесты")) == "Сейчас: Пишет тесты")
    }

    @Test func sevenStepsAroundTheCurrentOne() {
        func todos(current: Int, count: Int) -> [SessionTodo] {
            (0..<count).map { SessionTodo(content: "\($0)", status: $0 < current ? .completed : $0 == current ? .inProgress : .pending) }
        }
        #expect(NotchText.visibleSteps(todos(current: 2, count: 5)) == 0..<5)
        #expect(NotchText.visibleSteps(todos(current: 1, count: 12)) == 0..<7)
        #expect(NotchText.visibleSteps(todos(current: 6, count: 12)) == 4..<11, "two done steps above the current one")
        #expect(NotchText.visibleSteps(todos(current: 11, count: 12)) == 5..<12, "never past the end")
        #expect(NotchText.visibleSteps(todos(current: 12, count: 12)) == 5..<12, "all done: the last ones")
    }

    @Test func settingIsOnByDefault() throws {
        #expect(NotchSettings().liveActivity)
        let old = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"leftEar":"weekLimit"}"#.utf8))
        #expect(old.liveActivity && old.leftEar == .weekLimit)
    }
}
