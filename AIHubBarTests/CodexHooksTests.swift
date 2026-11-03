import Foundation
import Testing
@testable import AIHubBar

/// Codex CLI through AI Hub Bar's hook (SPEC-ai-services stage 7): its Claude-style events give the same session file,
/// marked `codex`, and our entries share `~/.codex/hooks.json` with the person's own hooks.
struct CodexHooksTests {
    private struct Harness {
        let dir: URL
        var script: URL { dir.appending(path: "claudepult-hook.py") }
        var sessions: URL { dir.appending(path: "sessions") }
        var hooks: CodexHooks {
            CodexHooks(fileURL: dir.appending(path: "codex/hooks.json"), scriptURL: script, projectsDirectory: "/Users/me/Projects")
        }

        init() throws {
            dir = FileManager.default.temporaryDirectory.appending(path: "codex-hooks-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try HookScript.write(to: script)
        }

        func send(_ event: [String: Any]) async throws {
            let input = try JSONSerialization.data(withJSONObject: event)
            _ = try await ProcessRunner.run(
                script.path, ["--agent", "codex", "--projects-dir", "/Users/me/Projects", "--sessions-dir", sessions.path],
                input: input, timeout: .seconds(10)
            )
        }

        func session(_ id: String) throws -> Session {
            try JSONDecoder().decode(Session.self, from: Data(contentsOf: sessions.appending(path: "\(id).json")))
        }
    }

    private static let id = "01a1a155-5d4a-7ac2-8d14-645e724789a8"

    /// Payloads as learn.chatgpt.com/docs/hooks gives them (common fields plus Codex's `turn_id`, `model`,
    /// `permission_mode`); the id is a Codex thread id, the same as its rollout's and `state_5.sqlite`'s.
    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        [
            "session_id": Self.id, "hook_event_name": name, "cwd": "/Users/me/Projects/Ambo", "model": "gpt-6-luna",
            "transcript_path": "/Users/me/.codex/sessions/2026/11/03/rollout-2026-11-03T13-14-51-\(Self.id).jsonl",
        ].merging(extra) { $1 }
    }

    @Test func codexStatesThroughASession() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        try await h.send(event("SessionStart", ["source": "startup", "permission_mode": "default"]))
        var session = try h.session(Self.id)
        #expect(session.agent == .codex)
        #expect(session.agentName == "Codex")
        #expect(session.state == .done)
        #expect(session.project == "Ambo")
        #expect(session.entrypoint == "codex")

        try await h.send(event("UserPromptSubmit", ["turn_id": "t1", "prompt": "Добавь экспорт в CSV", "permission_mode": "default"]))
        session = try h.session(Self.id)
        #expect(session.state == .running)
        #expect(session.task == "Добавь экспорт в CSV")

        try await h.send(event("PermissionRequest", [
            "turn_id": "t1", "tool_name": "Bash", "permission_mode": "default",
            "tool_input": ["command": "npm install", "description": "Install dependencies"],
        ]))
        session = try h.session(Self.id)
        #expect(session.state == .waiting)
        #expect(session.message == "Нужно разрешение: Bash")

        try await h.send(event("PostToolUse", [
            "turn_id": "t1", "tool_name": "apply_patch", "tool_use_id": "call_1", "tool_response": "Success",
            "tool_input": ["command": "*** Begin Patch\n*** Update File: Sources/Export.swift\n@@\n-old\n+new\n*** End Patch"],
        ]))
        session = try h.session(Self.id)
        #expect(session.state == .running)
        #expect(session.actionText == "правит Export.swift")

        try await h.send(event("Stop", ["turn_id": "t1", "stop_hook_active": false, "last_assistant_message": "Готово"]))
        #expect(try h.session(Self.id).state == .done)

        try await h.send(event("UserPromptSubmit", ["turn_id": "t2", "prompt": "Ещё тесты"]))
        #expect(try h.session(Self.id).state == .running)
        try await h.send(event("Interrupt", ["turn_id": "t2", "permission_mode": "default"]))
        session = try h.session(Self.id)
        #expect(session.state == .done)
        #expect(session.lastTool == nil)

        try await h.send(event("SessionEnd", ["reason": "other"]))
        #expect(try h.session(Self.id).state == .ended)
    }

    @Test func codexNeverOpensAnApprovalRequest() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try await h.send(event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]]))
        let approvals = h.dir.appending(path: "approvals")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: approvals.path)) ?? []
        #expect(files.filter { $0.hasSuffix(".request.json") }.isEmpty)
    }

    @Test func installMergesIntoTheSharedFile() throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let hooks = h.hooks
        #expect(hooks.status() == .notInstalled)

        // The person's own hook stays where it is.
        let own: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/bin/true"]]]]]]
        try FileManager.default.createDirectory(at: hooks.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: own).write(to: hooks.fileURL)

        let backup = try #require(try hooks.install())
        #expect(backup.lastPathComponent.hasPrefix("hooks.json.claudepult-backup-"))
        #expect(hooks.status() == .installed)
        #expect(try hooks.install() == nil, "installing again changes nothing")

        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: hooks.fileURL)) as? [String: Any])
        let events = try #require(object["hooks"] as? [String: [[String: Any]]])
        #expect(Set(events.keys) == Set(CodexHooks.events + ["PreToolUse"]))
        #expect(events["PreToolUse"]?.count == 1)
        let entry = try #require((events["PermissionRequest"]?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(entry["type"] as? String == "command")
        #expect((entry["command"] as? String)?.contains("--agent codex") == true)
        #expect(entry["timeout"] as? Int == HookInstaller.timeoutSeconds)
        let end = try #require((events["SessionEnd"]?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(end["timeout"] as? Int == 3, "Codex clamps SessionEnd to 3 s")

        try hooks.uninstall()
        #expect(hooks.status() == .notInstalled)
        let left = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: hooks.fileURL)) as? [String: Any])
        #expect(NSDictionary(dictionary: left).isEqual(to: own))
    }

    @Test func aFileOnlyOursIsRemoved() throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let hooks = h.hooks
        #expect(try hooks.install() == nil, "no file before: no backup")
        #expect(hooks.status() == .installed)
        try hooks.uninstall()
        #expect(!FileManager.default.fileExists(atPath: hooks.fileURL.path))
    }

    @Test func anUnreadableFileIsLeftAlone() throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let hooks = h.hooks
        try FileManager.default.createDirectory(at: hooks.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: hooks.fileURL)
        #expect(throws: HookInstallError.self) { try hooks.install() }
        #expect(try String(contentsOf: hooks.fileURL, encoding: .utf8) == "{ not json")
    }

    @Test func anOldScriptIsOutdated() throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let hooks = h.hooks
        try hooks.install()
        try Data("#!/usr/bin/python3\n".utf8).write(to: h.script)
        #expect(hooks.status() == .outdated)
        #expect(try hooks.updateScriptIfNeeded())
        #expect(hooks.status() == .installed)
    }
}
