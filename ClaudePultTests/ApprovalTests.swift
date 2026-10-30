import Foundation
import Testing
@testable import ClaudePult

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "approvals-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Answering Claude Code's permission requests from ClaudePult: the hook, the files and the notification.
struct ApprovalTests {
    private struct Harness {
        let dir: URL
        var script: URL { dir.appending(path: "claudepult-hook.py") }
        var sessions: URL { dir.appending(path: "sessions") }
        var approvals: URL { dir.appending(path: "approvals") }

        init(alive: Bool) throws {
            dir = try tempDirectory()
            try HookScript.write(to: script)
            if alive { ApprovalFiles.touchAlive(in: approvals) }
        }

        func send(_ event: [String: Any]) async throws -> ProcessResult {
            let input = try JSONSerialization.data(withJSONObject: event)
            return try await ProcessRunner.run(
                script.path, ["--projects-dir", "/Users/me/Projects", "--sessions-dir", sessions.path],
                input: input, timeout: .seconds(20)
            )
        }

        /// Waits for the hook's request file.
        func request() async throws -> ApprovalRequest {
            for _ in 0..<100 {
                if let request = ApprovalFiles.requests(in: approvals).first { return request }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CancellationError()
        }
    }

    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": "abc-123", "hook_event_name": name, "cwd": "/Users/me/Projects/Ambo", "transcript_path": "/t.jsonl"]
            .merging(extra) { $1 }
    }

    private var permission: [String: Any] {
        event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test", "description": "Run tests"]])
    }

    @Test func allowFromClaudePultReachesClaude() async throws {
        let h = try Harness(alive: true)
        defer { try? FileManager.default.removeItem(at: h.dir) }
        async let result = h.send(permission)
        let request = try await h.request()
        #expect(request.tool == "Bash" && request.summary == "npm test" && request.project == "Ambo" && request.sessionID == "abc-123")
        // The session shows as waiting right after the request (the request is written first).
        let record = h.sessions.appending(path: "abc-123.json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: record.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try JSONDecoder().decode(Session.self, from: Data(contentsOf: record)).state == .waiting)
        ApprovalFiles.decide(request.id, allow: true, in: h.approvals)

        let output = try await result
        let json = try #require(try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        let specific = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect((specific["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        #expect(ApprovalFiles.requests(in: h.approvals).isEmpty)
    }

    @Test func denyCarriesAMessage() async throws {
        let h = try Harness(alive: true)
        defer { try? FileManager.default.removeItem(at: h.dir) }
        async let result = h.send(permission)
        ApprovalFiles.decide(try await h.request().id, allow: false, in: h.approvals)
        let decision = try #require(((try JSONSerialization.jsonObject(with: try await result.stdout) as? [String: Any])?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "Отклонено в AI Hub Bar")
    }

    @Test func withoutClaudePultNothingWaits() async throws {
        let h = try Harness(alive: false)
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let started = Date.now
        let output = try await h.send(permission)
        #expect(output.stdout.isEmpty && output.exitCode == 0)
        #expect(Date.now.timeIntervalSince(started) < 5)
    }

    @Test func answeredInClaudeEndsTheWait() async throws {
        let h = try Harness(alive: true)
        defer { try? FileManager.default.removeItem(at: h.dir) }
        async let result = h.send(permission)
        _ = try await h.request()
        // Claude's own dialog was answered: the tool ran.
        _ = try await h.send(event("PostToolUse", ["tool_name": "Bash"]))
        let output = try await result
        #expect(output.stdout.isEmpty)
        #expect(ApprovalFiles.requests(in: h.approvals).isEmpty)
    }

    @Test func requestFiles() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date.now.timeIntervalSince1970
        for (id, session, age) in [("a1", "s1", 10.0), ("b2", "s1", 2.0), ("c3", "s2", 1000.0)] {
            let request = ApprovalRequest(id: id, sessionID: session, project: nil, tool: "Bash", summary: "", created: now - age, pid: nil)
            try JSONEncoder().encode(request).write(to: dir.appending(path: "\(id).request.json"))
        }
        let requests = ApprovalFiles.requests(in: dir)
        // Older than the hook's wait: the hook is gone.
        #expect(requests.map { $0.id } == ["a1", "b2"])
        #expect(ApprovalFiles.bySession(requests)["s1"]?.id == "b2")
        // A hook Claude already cancelled can't take an answer.
        let gone = ApprovalRequest(id: "d4", sessionID: "s3", project: nil, tool: "Bash", summary: "", created: now, pid: 999_999)
        try JSONEncoder().encode(gone).write(to: dir.appending(path: "d4.request.json"))
        #expect(!ApprovalFiles.requests(in: dir).contains { $0.id == "d4" })
        #expect(ApprovalFiles.isValidID("0f3a9c") && !ApprovalFiles.isValidID("../x") && !ApprovalFiles.isValidID(""))
        ApprovalFiles.decide("../evil", allow: true, in: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appending(path: "evil.decision").path))
    }

    @Test func notificationButtons() {
        let target = NotificationTarget.approval(sessionID: "s1", requestID: "r1")
        #expect(NotificationTarget(userInfo: target.userInfo) == target)
        #expect(target.category == NotificationAction.approvalCategory)
        #expect(NotificationAction.resolve(target, action: NotificationAction.allow) == .decide(requestID: "r1", allow: true))
        #expect(NotificationAction.resolve(target, action: NotificationAction.deny) == .decide(requestID: "r1", allow: false))
        #expect(NotificationAction.resolve(target, action: "com.apple.UNNotificationDefaultActionIdentifier") == .showSession(id: "s1"))
    }

    @Test func permissionHookGetsTimeToWait() throws {
        let merged = HookInstaller.merged([:], command: "'/x/claudepult-hook.py'")
        let hooks = try #require(merged["hooks"] as? [String: Any])
        let entry = try #require((((hooks["PermissionRequest"] as? [[String: Any]])?.first)?["hooks"] as? [[String: Any]])?.first)
        #expect(entry["timeout"] as? Int == ApprovalFiles.waitSeconds + 10)
        // Hooks installed before this version (5 s everywhere) need «Обновить hooks».
        var old = merged
        var oldHooks = hooks
        oldHooks["PermissionRequest"] = [["hooks": [["type": "command", "command": "'/x/claudepult-hook.py'", "timeout": 5]]]]
        old["hooks"] = oldHooks
        #expect(HookInstaller.status(of: old, expectedCommand: "'/x/claudepult-hook.py'") == .outdated)
    }
}
