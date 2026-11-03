import Foundation
import Testing
@testable import AIHubBar

/// Copilot CLI through AI Hub Bar's hook: its Claude-style events give the same session file, marked `copilot`.
struct CopilotHooksTests {
    private struct Harness {
        let dir: URL
        var script: URL { dir.appending(path: "claudepult-hook.py") }
        var sessions: URL { dir.appending(path: "sessions") }
        var hooks: CopilotHooks {
            CopilotHooks(fileURL: dir.appending(path: "copilot/hooks/aihubbar.json"), scriptURL: script, projectsDirectory: "/Users/me/Projects")
        }

        init() throws {
            dir = FileManager.default.temporaryDirectory.appending(path: "copilot-hooks-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try HookScript.write(to: script)
        }

        func send(_ event: [String: Any], agent: String = "copilot") async throws {
            let input = try JSONSerialization.data(withJSONObject: event)
            _ = try await ProcessRunner.run(
                script.path, ["--agent", agent, "--projects-dir", "/Users/me/Projects", "--sessions-dir", sessions.path],
                input: input, timeout: .seconds(10)
            )
        }

        func session(_ id: String) throws -> Session {
            try JSONDecoder().decode(Session.self, from: Data(contentsOf: sessions.appending(path: "\(id).json")))
        }
    }

    /// Payloads as the Copilot CLI hooks reference gives them for PascalCase event names (snake_case fields).
    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": "4313e787-2ac1", "hook_event_name": name, "cwd": "/Users/me/Projects/Ambo"].merging(extra) { $1 }
    }

    @Test func copilotStatesThroughASession() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        try await h.send(event("SessionStart", ["source": "startup"]))
        var session = try h.session("4313e787-2ac1")
        #expect(session.agent == .copilot)
        #expect(session.agentName == "Copilot")
        #expect(session.state == .done)
        #expect(session.project == "Ambo")
        #expect(session.entrypoint == "copilot")

        try await h.send(event("UserPromptSubmit", ["prompt": "Добавь экспорт в CSV"]))
        session = try h.session("4313e787-2ac1")
        #expect(session.state == .running)
        #expect(session.task == "Добавь экспорт в CSV")

        try await h.send(event("Notification", ["notification_type": "permission_prompt", "message": "Copilot wants to run ls"]))
        session = try h.session("4313e787-2ac1")
        #expect(session.state == .waiting)
        #expect(session.message == "Copilot wants to run ls")

        try await h.send(event("PostToolUse", ["tool_name": "bash", "tool_input": ["command": "ls"]]))
        #expect(try h.session("4313e787-2ac1").state == .running)

        try await h.send(event("Stop", ["stop_reason": "end_turn"]))
        #expect(try h.session("4313e787-2ac1").state == .done)

        try await h.send(event("SessionEnd", ["reason": "user_exit"]))
        #expect(try h.session("4313e787-2ac1").state == .ended)
    }

    @Test func copilotNeverOpensAnApprovalRequest() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try await h.send(event("PermissionRequest", ["tool_name": "bash"]))
        let approvals = h.dir.appending(path: "approvals")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: approvals.path)) ?? []
        #expect(files.filter { $0.hasSuffix(".request.json") }.isEmpty)
    }

    @Test func claudeSessionsStayClaude() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try await h.send(event("SessionStart", ["source": "startup"]), agent: "claude")
        #expect(try h.session("4313e787-2ac1").agent == .claudeCode)
        // Files written before the agent field existed are Claude's.
        let old = try JSONDecoder().decode(Session.self, from: Data(#"{"session_id":"x","updated_at":"2026-11-03T05:00:00+01:00"}"#.utf8))
        #expect(old.agent == .claudeCode)
    }

    @Test func installWritesOneFileOfItsOwn() throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let hooks = h.hooks
        #expect(hooks.status() == .notInstalled)
        try hooks.install()
        #expect(hooks.status() == .installed)

        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: hooks.fileURL)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let events = try #require(object["hooks"] as? [String: [[String: Any]]])
        #expect(Set(events.keys) == Set(CopilotHooks.events))
        #expect(events["PermissionRequest"] == nil, "Copilot runs it before its rules: not a sign of a prompt")
        let entry = try #require(events["Notification"]?.first)
        #expect(entry["type"] as? String == "command")
        #expect((entry["bash"] as? String)?.contains("--agent copilot") == true)
        #expect(entry["matcher"] == nil, "Copilot matchers are regular expressions; «*» would not be one")

        try Data("{}".utf8).write(to: hooks.fileURL)
        #expect(hooks.status() == .outdated)
        try hooks.uninstall()
        #expect(hooks.status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: hooks.fileURL.path))
    }

    @Test func threadsShownAsSessionsAreNotRepeated() {
        let thread = AgentThread(agent: .copilot, id: "s1", project: "Ambo", folder: "/a", title: "t", updatedAt: .now, context: nil)
        let other = AgentThread(agent: .codex, id: "s2", project: "Ambo", folder: "/a", title: "t", updatedAt: .now, context: nil)
        #expect(AgentThread.without([thread, other], sessionIDs: ["s1"]) == [other])
    }
}
