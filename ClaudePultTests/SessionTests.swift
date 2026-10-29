import Foundation
import Testing
@testable import ClaudePult

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "claudepult-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct HookInstallerTests {
    private static var foreignHook: [String: Any] { [
        "matcher": "Bash",
        "hooks": [["type": "command", "command": "/usr/local/bin/my-guard"]],
    ] }

    @Test func mergeKeepsOtherSettingsAndIsIdempotent() throws {
        let original: [String: Any] = ["theme": "dark", "hooks": ["PreToolUse": [Self.foreignHook], "Stop": [Self.foreignHook]]]
        let once = HookInstaller.merged(original, command: "'/x/claudepult-hook.py'")
        let twice = HookInstaller.merged(once, command: "'/x/claudepult-hook.py'")
        #expect(NSDictionary(dictionary: once).isEqual(to: twice))
        #expect(once["theme"] as? String == "dark")

        let hooks = try #require(once["hooks"] as? [String: Any])
        #expect((hooks["PreToolUse"] as? [Any])?.count == 1)
        #expect((hooks["Stop"] as? [Any])?.count == 2)
        for event in HookInstaller.events {
            #expect(hooks[event] != nil, "missing \(event)")
        }
        let post = try #require((hooks["PostToolUse"] as? [[String: Any]])?.last)
        #expect(post["matcher"] as? String == "*")
        #expect(HookInstaller.status(of: once, expectedCommand: "'/x/claudepult-hook.py'") == .installed)
        #expect(HookInstaller.status(of: once, expectedCommand: "'/y/claudepult-hook.py'") == .outdated)
    }

    @Test func removeRestoresOriginal() {
        let original: [String: Any] = ["theme": "dark", "hooks": ["Stop": [Self.foreignHook]]]
        let restored = HookInstaller.removed(HookInstaller.merged(original, command: "c claudepult-hook"))
        #expect(NSDictionary(dictionary: restored).isEqual(to: original))

        let bare = HookInstaller.removed(HookInstaller.merged(["theme": "dark"], command: "c claudepult-hook"))
        #expect(NSDictionary(dictionary: bare).isEqual(to: ["theme": "dark"]))
        #expect(HookInstaller.status(of: bare, expectedCommand: "c claudepult-hook") == .notInstalled)
    }

    @Test func installAndUninstallFiles() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsURL = dir.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme": "dark", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other"}]}]}}"#.utf8).write(to: settingsURL)

        let installer = HookInstaller(settingsURL: settingsURL, scriptURL: dir.appending(path: "Support Dir/hooks/claudepult-hook.py"), projectsDirectory: "/P")
        #expect(installer.status() == .notInstalled)
        #expect(installer.command == "'\(dir.path)/Support Dir/hooks/claudepult-hook.py' --projects-dir '/P'")

        let backup = try #require(try installer.install())
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("other"))
        #expect(installer.status() == .installed)
        #expect(FileManager.default.isExecutableFile(atPath: installer.scriptURL.path))

        // A second install changes nothing: no rewrite, no new backup that could replace the original one.
        #expect(try installer.install() == nil)
        let backups = try FileManager.default.contentsOfDirectory(atPath: settingsURL.deletingLastPathComponent().path)
            .filter { $0.contains("claudepult-backup") }
        #expect(backups.count == 1)

        let secondBackup = try #require(try installer.uninstall())
        #expect(secondBackup != backup)
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("other"))
        #expect(try !String(contentsOf: backup, encoding: .utf8).contains("claudepult-hook"))
        #expect(installer.status() == .notInstalled)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        #expect(NSDictionary(dictionary: after ?? [:]).isEqual(to: [
            "theme": "dark", "hooks": ["Stop": [["hooks": [["type": "command", "command": "other"]]]]],
        ]))
    }

    @Test func refusesMalformedSettings() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsURL = dir.appending(path: "settings.json")
        try Data("{ not json".utf8).write(to: settingsURL)
        let installer = HookInstaller(settingsURL: settingsURL, scriptURL: dir.appending(path: "h/claudepult-hook.py"), projectsDirectory: "/P")
        #expect(throws: HookInstallError.self) { try installer.install() }
        #expect(try String(contentsOf: settingsURL, encoding: .utf8) == "{ not json")
    }

    @Test func installsIntoMissingSettings() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installer = HookInstaller(settingsURL: dir.appending(path: ".claude/settings.json"), scriptURL: dir.appending(path: "h/claudepult-hook.py"), projectsDirectory: "/P")
        #expect(try installer.install() == nil)
        #expect(installer.status() == .installed)
    }
}

/// Runs the real hook script with python3, feeding events the way Claude Code does.
struct HookScriptTests {
    private struct Harness {
        let dir: URL
        var script: URL { dir.appending(path: "claudepult-hook.py") }
        var sessions: URL { dir.appending(path: "sessions") }

        init() throws {
            dir = try tempDirectory()
            try HookScript.write(to: script)
        }

        @discardableResult
        func send(_ event: [String: Any]) async throws -> ProcessResult {
            let input = try JSONSerialization.data(withJSONObject: event)
            return try await ProcessRunner.run(
                script.path, ["--projects-dir", "/Users/me/Projects", "--sessions-dir", sessions.path],
                input: input, environment: ["TERM_PROGRAM": "Apple_Terminal"], timeout: .seconds(10)
            )
        }

        func session(_ id: String) throws -> Session {
            try JSONDecoder().decode(Session.self, from: Data(contentsOf: sessions.appending(path: "\(id).json")))
        }
    }

    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": "abc-123", "hook_event_name": name, "cwd": "/Users/me/Projects/Ambo/.claude/worktrees/cb-x/apps",
         "transcript_path": "/t.jsonl"].merging(extra) { $1 }
    }

    @Test func tracksStateThroughASession() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let start = try await h.send(event("SessionStart", ["source": "startup"]))
        #expect(start.exitCode == 0 && start.stdout.isEmpty && start.stderr.isEmpty)
        var s = try h.session("abc-123")
        #expect(s.state == .done)
        #expect(s.project == "Ambo")
        #expect(s.projectPath == "/Users/me/Projects/Ambo")
        #expect(s.worktreeName == "cb-x")
        #expect(s.termProgram == "Apple_Terminal")
        #expect(s.startedAt != nil)

        let prompt = try await h.send(event("UserPromptSubmit", ["prompt": "  Сделай\nэкспорт  " + String(repeating: "x", count: 300)]))
        #expect(prompt.stdout.isEmpty)
        s = try h.session("abc-123")
        #expect(s.state == .running)
        #expect(s.firstPrompt?.hasPrefix("Сделай экспорт xxx") == true)
        #expect(s.firstPrompt?.count == 200)

        try await h.send(event("UserPromptSubmit", ["prompt": "second"]))
        s = try h.session("abc-123")
        #expect(s.lastPrompt == "second")
        #expect(s.task?.hasPrefix("Сделай") == true)

        try await h.send(event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]]))
        s = try h.session("abc-123")
        #expect(s.state == .waiting)
        #expect(s.message == "Нужно разрешение: Bash")

        try await h.send(event("PostToolUse", ["tool_name": "Bash"]))
        #expect(try h.session("abc-123").state == .running)

        try await h.send(event("Notification", ["notification_type": "idle_prompt", "message": "idle"]))
        #expect(try h.session("abc-123").state == .running)

        try await h.send(event("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]))
        s = try h.session("abc-123")
        #expect(s.state == .waiting)
        #expect(s.message == "Claude needs your permission to use Bash")

        try await h.send(event("Stop", ["stop_hook_active": false]))
        s = try h.session("abc-123")
        #expect(s.state == .done)
        #expect(s.message == nil)

        try await h.send(event("SessionStart", ["source": "compact"]))
        #expect(try h.session("abc-123").state == .done)

        try await h.send(event("SessionEnd", ["reason": "prompt_input_exit"]))
        #expect(try h.session("abc-123").state == .ended)
    }

    @Test func ignoresGarbageSilently() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        for input in [Data("not json".utf8), Data(#"{"session_id": "../../etc/passwd", "hook_event_name": "Stop"}"#.utf8), Data()] {
            let result = try await ProcessRunner.run(
                h.script.path, ["--sessions-dir", h.sessions.path], input: input, timeout: .seconds(10)
            )
            #expect(result.exitCode == 0)
            #expect(result.stdout.isEmpty && result.stderr.isEmpty)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: h.sessions.path)) ?? []
        #expect(files.filter { $0.hasSuffix(".json") }.isEmpty)
    }

    @Test func sessionsOutsideProjects() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try await h.send(["session_id": "s2", "hook_event_name": "SessionStart", "cwd": "/Users/me/Documents/notes"])
        let s = try h.session("s2")
        #expect(s.project == nil)
        #expect(s.displayProject == "notes")
    }
}

struct SessionRulesTests {
    private func session(state: String, updated: Date, pid: Int? = nil) throws -> Session {
        var json: [String: Any] = ["session_id": UUID().uuidString, "cwd": "/P/A", "state": state,
                                   "updated_at": updated.ISO8601Format()]
        if let pid { json["claude_pid"] = pid }
        return try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func deadProcessMeansEnded() throws {
        let s = try session(state: "running", updated: .now)
        #expect(SessionRules.effectiveState(s, isAlive: false) == .ended)
        #expect(SessionRules.effectiveState(s, isAlive: true) == .running)
        #expect(SessionRules.effectiveState(s, isAlive: nil) == .running)
    }

    @Test func visibility() throws {
        let now = Date.now
        #expect(SessionRules.isVisible(try session(state: "done", updated: now.addingTimeInterval(-3 * 3600)), isAlive: true, now: now))
        #expect(!SessionRules.isVisible(try session(state: "done", updated: now.addingTimeInterval(-3 * 3600)), isAlive: nil, now: now))
        #expect(SessionRules.isVisible(try session(state: "running", updated: now.addingTimeInterval(-3600)), isAlive: nil, now: now))
        #expect(SessionRules.isVisible(try session(state: "ended", updated: now.addingTimeInterval(-60)), isAlive: false, now: now))
        #expect(!SessionRules.isVisible(try session(state: "ended", updated: now.addingTimeInterval(-3600)), isAlive: false, now: now))
        #expect(!SessionRules.isVisible(try session(state: "running", updated: now.addingTimeInterval(-3600)), isAlive: false, now: now))
    }

    @Test func waitingFirst() throws {
        let now = Date.now
        let done = try session(state: "done", updated: now)
        let waiting = try session(state: "waiting", updated: now.addingTimeInterval(-600))
        let running = try session(state: "running", updated: now.addingTimeInterval(-60))
        let sorted = SessionRules.sorted([(done, .done), (running, .running), (waiting, .waiting)])
        #expect(sorted.map(\.state) == [.waiting, .running, .done])
    }

    @Test func taskTitleDropsClaudePultWrappers() {
        #expect(Session.taskTitle(ClaudeCommand.customTask("Добавь экспорт").prompt) == "Добавь экспорт")
        #expect(Session.taskTitle(String(ClaudeCommand.nextStep.prompt.prefix(200))) == "Следующий шаг")
        #expect(Session.taskTitle(String(ClaudeCommand.finishSession.prompt.prefix(200))) == "Завершить сессию")
        let long = String(ClaudeCommand.customTask(String(repeating: "очень длинная задача ", count: 20)).prompt.prefix(200))
        #expect(Session.taskTitle(long).hasPrefix("очень длинная задача"))
        #expect(!Session.taskTitle(long).hasPrefix("Задача от Олега"))
        #expect(Session.taskTitle("Почини   логин\nсрочно") == "Почини логин срочно")
    }

    @Test func childEnvironmentDropsClaudeVariables() {
        let env = ProcessRunner.environment(base: ["PATH": "/usr/bin", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDECODE": "1", "HOME": "/h"])
        #expect(env["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["HOME"] == "/h")
    }

    @Test func liveProcessCheck() {
        #expect(!SessionStore.isClaudeProcessAlive(getpid()))
        #expect(!SessionStore.isClaudeProcessAlive(999_999))
    }

    @Test(arguments: [(30.0, "30 с"), (125, "2 мин"), (3 * 3600 + 5 * 60, "3 ч 05 мин"), (2 * 86_400 + 5, "2 дн")] as [(TimeInterval, String)])
    func duration(seconds: TimeInterval, expected: String) {
        let start = Date(timeIntervalSince1970: 0)
        #expect(DurationText.short(from: start, to: start.addingTimeInterval(seconds)) == expected)
    }

    @Test func loadsDirectory() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date.now
        func write(_ id: String, _ state: String, _ age: TimeInterval) throws {
            let json: [String: Any] = ["session_id": id, "cwd": "/P/\(id)", "state": state, "updated_at": now.addingTimeInterval(-age).ISO8601Format()]
            try JSONSerialization.data(withJSONObject: json).write(to: dir.appending(path: "\(id).json"))
        }
        try write("a", "done", 60)
        try write("b", "waiting", 120)
        try write("old", "done", 5 * 3600)
        try Data("garbage".utf8).write(to: dir.appending(path: "bad.json"))
        let items = SessionStore.loadItems(from: dir, now: now)
        #expect(items.map(\.id) == ["b", "a"])
    }
}
