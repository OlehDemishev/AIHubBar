import Foundation
import Testing
@testable import AIHubBar

private func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "aihubbar-remote-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct RemoteMachineTests {
    @Test func hostsSSHTakesAsOneWord() {
        for host in ["air", "oleh@192.168.1.20", "build.example.com", "dev_box-2", "user@host.local"] {
            #expect(RemoteMachine.isValidHost(host), "\(host)")
        }
    }

    @Test func hostsThatWouldReadAsOptionsOrShell() {
        for host in ["", "-oProxyCommand=sh", "a b", "host;rm", "$(id)", "user@", "@host", "a@b@c", "host\n", "`id`", "'x'"] {
            #expect(!RemoteMachine.isValidHost(host), "\(host)")
        }
    }

    @Test func titleFallsBackToTheHost() {
        #expect(RemoteMachine(name: "  ", host: "air").title == "air")
        #expect(RemoteMachine(name: "Ноутбук", host: "air").title == "Ноутбук")
    }

    @Test func sshNeverAsksAndTheHostCannotBeAnOption() {
        let arguments = SSHCommand.arguments(host: "air", remote: "python3 .aihubbar/remote.py watch", keepAlive: true)
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ServerAliveInterval=15"))
        #expect(Array(arguments.suffix(3)) == ["--", "air", "python3 .aihubbar/remote.py watch"])
        #expect(!SSHCommand.arguments(host: "air", remote: "x").contains("ServerAliveInterval=15"))
    }

    @Test func terminalLineQuotesTheFolderForBothShells() {
        let line = SSHCommand.terminalCommandLine(host: "air", folder: "/home/me/it's here", run: "claude --resume 'abc'")
        #expect(line.hasPrefix("ssh -t -- $'air' $'"))
        #expect(line.contains(#"cd \'/home/me/it\'\\\'\'s here\' && exec "$SHELL" -lic"#))
        #expect(SSHCommand.terminalCommandLine(host: "air", folder: "") == #"ssh -t -- $'air' $'exec "$SHELL" -l'"#)
    }

    @Test func reasonIsSSHsLastLine() {
        let stderr = "Warning: Permanently added 'air' (ED25519) to the list of known hosts.\nssh: connect to host air port 22: Operation timed out\n"
        #expect(SSHCommand.reason(stderr: stderr, exitCode: 255) == "connect to host air port 22: Operation timed out")
        #expect(SSHCommand.reason(stderr: "", exitCode: 255) == "ssh: 255")
        #expect(SSHCommand.isMissingHelper(stderr: "python3: can't open file '/home/me/.aihubbar/remote.py': [Errno 2] No such file or directory"))
        #expect(!SSHCommand.isMissingHelper(stderr: "Permission denied (publickey)."))
    }

    @Test func snapshotSkipsABrokenRecordAndMarksTheComputer() throws {
        let line = """
        {"format": 1, "sessions": [{"session_id": "a", "cwd": "/srv/app", "state": "waiting", "updated_at": "2026-11-27T10:00:00+00:00", "alive": true}, {"cwd": "/no-id"}, 7],
         "requests": [{"id": "r1", "session_id": "a", "tool": "Bash", "summary": "git push", "created": 100},
                      {"id": "r2", "session_id": "someone-elses", "tool": "Bash", "summary": "rm -rf", "created": 101}]}
        """
        let snapshot = try #require(RemoteSnapshot.parse(line: Data(line.utf8)))
        #expect(snapshot.sessions.map(\.session.id) == ["a"])
        #expect(snapshot.sessions.first?.alive == true)
        let machine = RemoteMachine(id: "m1", name: "Сервер", host: "srv")
        #expect(snapshot.entries(on: machine).first?.session.machine == SessionMachine(id: "m1", name: "Сервер", host: "srv"))
        #expect(snapshot.entries(on: machine).first?.session.placeTitle == "app · Сервер")
        // A request for a session that computer did not report is not shown: it could sit on another one's row.
        #expect(snapshot.requests(on: machine).map(\.id) == ["r1"])
        #expect(snapshot.requests(on: machine).map(\.machineID) == ["m1"])
        #expect(RemoteSnapshot.parse(line: Data("not json".utf8)) == nil)
    }

    @Test func setupResultInWords() {
        let done = RemoteMachines.setupResult(exitCode: 0, stdout: #"{"format": 1, "hook": "installed", "backup": "settings.json.claudepult-backup-1", "claude": true}"# + "\n", stderr: "")
        #expect(!done.isError)
        #expect(done.text.contains("settings.json.claudepult-backup-1"))
        let failed = RemoteMachines.setupResult(exitCode: 0, stdout: #"{"format": 1, "error": "the root is not a JSON object"}"#, stderr: "")
        #expect(failed == .init(isError: true, text: "the root is not a JSON object"))
        #expect(RemoteMachines.setupResult(exitCode: 127, stdout: "", stderr: "bash: python3: command not found").isError)
        #expect(RemoteMachines.setupResult(exitCode: 255, stdout: "", stderr: "Permission denied (publickey).").text == "Permission denied (publickey).")
    }
}

struct RemoteSessionMergeTests {
    private func session(_ id: String, state: String, updated: Date) throws -> Session {
        let json = #"{"session_id": "\#(id)", "cwd": "/srv/\#(id)", "state": "\#(state)", "updated_at": "\#(updated.ISO8601Format())"}"#
        return try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    @Test func remoteSessionsJoinTheListByTheSameRules() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let local = SessionStore.Item(session: try session("local", state: "running", updated: now), state: .running, context: 0.4)
        let remote = [
            RemoteSnapshot.Entry(session: try session("waits", state: "waiting", updated: now), alive: true),
            // Its process is gone: ended, and long enough ago to leave the list.
            RemoteSnapshot.Entry(session: try session("gone", state: "running", updated: now.addingTimeInterval(-3600)), alive: false),
            RemoteSnapshot.Entry(session: try session("just-ended", state: "running", updated: now.addingTimeInterval(-60)), alive: false),
            // The same id as a local one (this Mac added as its own «other computer»): shown once.
            RemoteSnapshot.Entry(session: try session("local", state: "done", updated: now), alive: true),
        ]
        let merged = SessionStore.merged(local: [local], remote: remote, now: now)
        #expect(merged.map(\.id) == ["waits", "local", "just-ended"])
        #expect(merged.map(\.state) == [.waiting, .running, .ended])
        #expect(merged[1].context == 0.4)
        #expect(merged[0].context == nil)
        #expect(SessionStore.merged(local: [local], remote: [], now: now) == [local])
    }

    @Test @MainActor func aRemoteAnswerGoesToItsComputer() throws {
        let dir = try tempHome()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir.appending(path: "sessions"), approvalsDirectory: dir.appending(path: "approvals"))
        var sent: [String] = []
        store.decideRemotely = { machine, request, allow in sent.append("\(machine) \(request) \(allow)") }
        store.approvals = [
            "s1": ApprovalRequest(id: "r1", sessionID: "s1", tool: "Bash", summary: "ls", created: 1, machineID: "m1"),
            "s2": ApprovalRequest(id: "r2", sessionID: "s2", tool: "Bash", summary: "ls", created: 1),
        ]
        store.decide(requestID: "r1", allow: true)
        store.decide(requestID: "r2", allow: false)
        #expect(sent == ["m1 r1 true"])
        #expect(store.approvals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "approvals/r1.decision").path))
        #expect(try String(contentsOf: dir.appending(path: "approvals/r2.decision"), encoding: .utf8) == "deny")
    }
}

/// Runs the real bootstrap and helper with python3 in a home folder of their own, the way `ssh` would.
struct RemoteScriptTests {
    private struct Harness {
        let home: URL
        /// Where the helper keeps its files on this Mac (`root()` in the script).
        var root: URL { home.appending(path: "Library/Application Support/ClaudePult") }
        var settings: URL { home.appending(path: ".claude/settings.json") }

        init() throws { home = try tempHome() }

        func python(_ arguments: [String], input: String? = nil, timeout: Duration = .seconds(20)) async throws -> ProcessResult {
            try await ProcessRunner.run("/usr/bin/python3", arguments, currentDirectory: home, input: input.map { Data($0.utf8) },
                                        environment: ["HOME": home.path], timeout: timeout)
        }

        func install() async throws -> [String: Any] {
            let result = try await python(["-"], input: RemoteScript.bootstrap())
            #expect(result.exitCode == 0, "\(result.stderrText)")
            return try #require(try JSONSerialization.jsonObject(with: Data(result.stdoutText.utf8)) as? [String: Any])
        }

        func helper(_ arguments: [String]) async throws -> [String: Any] {
            let result = try await python([RemoteScript.helperPath] + arguments)
            return try #require(try JSONSerialization.jsonObject(with: Data(result.stdoutText.utf8)) as? [String: Any])
        }

        func readSettings() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        }
    }

    @Test func installMergesTheHookAndKeepsOtherSettings() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.home) }
        try FileManager.default.createDirectory(at: h.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mine = #"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#
        try Data(mine.utf8).write(to: h.settings)

        let reply = try await h.install()
        #expect(reply["hook"] as? String == "installed")
        #expect((reply["backup"] as? String)?.hasPrefix("settings.json.claudepult-backup-") == true)
        let settings = try h.readSettings()
        #expect(settings["model"] as? String == "opus")
        let command = "'\(h.root.path)/hooks/claudepult-hook.py' --sessions-dir '\(h.root.path)/sessions'"
        // The same entries the app writes on this Mac: this Mac's own check reads them as installed.
        #expect(HookInstaller.status(of: settings, expectedCommand: command) == .installed)
        let stop = try #require((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(try String(contentsOf: h.root.appending(path: "hooks/claudepult-hook.py"), encoding: .utf8) == HookScript.source)
        #expect(FileManager.default.isExecutableFile(atPath: h.home.appending(path: RemoteScript.helperPath).path))

        // A second install changes nothing and makes no second backup.
        let again = try await h.install()
        #expect(again["backup"] is NSNull || again["backup"] == nil)
        #expect(NSDictionary(dictionary: try h.readSettings()).isEqual(to: settings))
    }

    @Test func aComputerWithItsOwnAIHubBarKeepsItsHook() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.home) }
        let own = HookInstaller.merged([:], command: "'/Users/x/Library/Application Support/ClaudePult/hooks/claudepult-hook.py' --projects-dir '/P'")
        try FileManager.default.createDirectory(at: h.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: own).write(to: h.settings)

        let reply = try await h.install()
        #expect(reply["hook"] as? String == "kept")
        #expect(NSDictionary(dictionary: try h.readSettings()).isEqual(to: own))
        // Removing the computer from the list takes the helper only: the hook there is not ours to remove.
        _ = try await h.helper(["uninstall"])
        #expect(NSDictionary(dictionary: try h.readSettings()).isEqual(to: own))
        #expect(!FileManager.default.fileExists(atPath: h.home.appending(path: RemoteScript.helperPath).path))
    }

    @Test func unreadableSettingsStayAsTheyAre() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.home) }
        try FileManager.default.createDirectory(at: h.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: h.settings)
        let reply = try await h.install()
        #expect(reply["error"] != nil)
        #expect(try String(contentsOf: h.settings, encoding: .utf8) == "{ not json")
    }

    @Test func uninstallTakesBackWhatInstallPut() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.home) }
        _ = try await h.install()
        _ = try await h.helper(["uninstall"])
        #expect(try h.readSettings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.root.appending(path: "hooks/claudepult-hook.py").path))
        #expect(!FileManager.default.fileExists(atPath: h.home.appending(path: RemoteScript.helperPath).path))
    }

    @Test func snapshotCarriesSessionsAndOpenRequests() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.home) }
        _ = try await h.install()
        let sessions = h.root.appending(path: "sessions"), approvals = h.root.appending(path: "approvals")
        try FileManager.default.createDirectory(at: approvals, withIntermediateDirectories: true)
        let now = Date.now
        try Data(#"{"session_id": "s1", "cwd": "/srv/app", "state": "waiting", "updated_at": "\#(now.ISO8601Format())", "claude_pid": 999999}"#.utf8)
            .write(to: sessions.appending(path: "s1.json"))
        try Data("{ half".utf8).write(to: sessions.appending(path: "broken.json"))
        let me = ProcessInfo.processInfo.processIdentifier
        try Data(#"{"id": "open", "session_id": "s1", "tool": "Bash", "summary": "git push", "created": \#(now.timeIntervalSince1970), "pid": \#(me)}"#.utf8)
            .write(to: approvals.appending(path: "open.request.json"))
        try Data(#"{"id": "old", "session_id": "s1", "tool": "Bash", "summary": "x", "created": \#(now.timeIntervalSince1970 - 400)}"#.utf8)
            .write(to: approvals.appending(path: "old.request.json"))
        try Data(#"{"id": "dead", "session_id": "s1", "tool": "Bash", "summary": "x", "created": \#(now.timeIntervalSince1970), "pid": 999999}"#.utf8)
            .write(to: approvals.appending(path: "dead.request.json"))

        let result = try await h.python([RemoteScript.helperPath, "snapshot"])
        let snapshot = try #require(RemoteSnapshot.parse(line: Data(result.stdoutText.utf8)))
        #expect(snapshot.format == RemoteScript.format)
        #expect(snapshot.sessions.map(\.session.id) == ["s1"])
        // No such process: the session reads as ended on this Mac.
        #expect(snapshot.sessions.first?.alive == false)
        #expect(snapshot.requests.map(\.id) == ["open"])
    }

    @Test func decideWritesTheAnswerTheHookWaitsFor() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.home) }
        _ = try await h.install()
        #expect(try await h.helper(["decide", "abc-123", "allow"])["ok"] as? Bool == true)
        #expect(try String(contentsOf: h.root.appending(path: "approvals/abc-123.decision"), encoding: .utf8) == "allow")
        #expect(try await h.helper(["decide", "../x", "allow"])["error"] != nil)
        #expect(try await h.helper(["decide", "abc", "maybe"])["error"] != nil)
        #expect(!FileManager.default.fileExists(atPath: h.root.appending(path: "x.decision").path))
    }

    @Test func watchPrintsASnapshotAndKeepsApprovalsAlive() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.home) }
        _ = try await h.install()
        // The stream never ends by itself: two seconds are enough for its first line.
        let result = try? await h.python([RemoteScript.helperPath, "watch", "--approvals"], timeout: .seconds(2))
        #expect(result == nil)
        #expect(FileManager.default.fileExists(atPath: h.root.appending(path: "approvals/alive").path))
    }

    @Test func theStreamDeliversWholeLines() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.home) }
        _ = try await h.install()
        let stream = RemoteStream(arguments: [h.home.appending(path: RemoteScript.helperPath).path, "watch"], executable: "/usr/bin/python3",
                                  environment: ["HOME": h.home.path])
        let first = AsyncStream<Data> { continuation in
            stream.start(onLine: { continuation.yield($0) }, onEnd: { _, _ in continuation.finish() })
        }
        var snapshot: RemoteSnapshot?
        for await line in first {
            snapshot = RemoteSnapshot.parse(line: line)
            break
        }
        stream.stop()
        #expect(snapshot == RemoteSnapshot(format: RemoteScript.format))
    }
}
