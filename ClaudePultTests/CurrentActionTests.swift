import Foundation
import Testing
@testable import ClaudePult

/// «What Claude is doing now»: the hook keeps the last tool call, the panel puts it into words.
struct CurrentActionTests {
    private func runHook(_ events: [[String: Any]]) async throws -> Session {
        let dir = FileManager.default.temporaryDirectory.appending(path: "action-\(UUID().uuidString)")
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

    @Test func hookKeepsTheLastToolCall() async throws {
        let session = try await runHook([
            ["hook_event_name": "UserPromptSubmit", "prompt": "Почини тесты"],
            ["hook_event_name": "PostToolUse", "tool_name": "Edit", "tool_input": ["file_path": "/Users/me/Projects/Ambo/Sources/LimitsView.swift"]],
        ])
        #expect(session.state == .running)
        #expect(session.lastTool == "Edit" && session.lastTarget == "LimitsView.swift")
        #expect(session.lastToolAt != nil)
        #expect(session.actionText == "правит LimitsView.swift")
    }

    @Test func stopClearsIt() async throws {
        let session = try await runHook([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            ["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": ["command": "npm   test"]],
            ["hook_event_name": "Stop"],
        ])
        #expect(session.lastTool == nil && session.actionText == nil)
    }

    @Test func wordsForTools() throws {
        func text(_ tool: String, _ target: String?) throws -> String? {
            var object: [String: Any] = ["session_id": "s", "updated_at": "2026-10-30T19:00:00+01:00", "last_tool": tool]
            if let target { object["last_target"] = target }
            return try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object)).actionText
        }
        #expect(try text("Bash", "npm test") == "запускает npm test")
        #expect(try text("Read", "README.md") == "читает README.md")
        #expect(try text("Grep", "TODO") == "ищет TODO")
        #expect(try text("TodoWrite", nil) == "обновляет план")
        #expect(try text("mcp__github__create_pull_request", nil) == "инструмент request")
    }
}
