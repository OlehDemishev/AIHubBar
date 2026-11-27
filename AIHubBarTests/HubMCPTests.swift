import Foundation
import Testing
@testable import AIHubBar

@MainActor
struct HubMCPTests {
    /// The app's folder with a few files in it, as the app writes them.
    @MainActor
    final class Bench {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hub-mcp-\(UUID().uuidString)")
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        var context: HubMCP.Context { HubMCP.Context(support: folder, now: now) }

        init() throws {
            try FileManager.default.createDirectory(at: folder.appending(path: "runs"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder.appending(path: "sessions"), withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: folder) }

        func call(_ method: String, _ params: [String: Any] = [:], id: Any = 1) throws -> [String: Any] {
            let request = HubMCP.encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            let line = try #require(HubMCP.handle(request, context: context))
            #expect(!line.contains("\n"), "one message, one line")
            return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }

        func tool(_ name: String) throws -> [String: Any] {
            let result = try #require(try call("tools/call", ["name": name, "arguments": [String: Any]()])["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == false)
            // The text is the same value, for clients that read only the text.
            let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
            #expect(try JSONSerialization.jsonObject(with: Data(text.utf8)) is [String: Any])
            return try #require(result["structuredContent"] as? [String: Any])
        }
    }

    @Test func initializeAnswersTheClientsVersionWhenItKnowsIt() throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        let known = try #require(try bench.call("initialize", ["protocolVersion": "2025-03-26"])["result"] as? [String: Any])
        #expect(known["protocolVersion"] as? String == "2025-03-26")
        #expect((known["serverInfo"] as? [String: Any])?["name"] as? String == "aihubbar")
        #expect((known["capabilities"] as? [String: Any])?["tools"] != nil)
        let other = try #require(try bench.call("initialize", ["protocolVersion": "1999-01-01"])["result"] as? [String: Any])
        #expect(other["protocolVersion"] as? String == HubMCP.protocolVersions[0], "an unknown one gets the newest this server speaks")
    }

    @Test func theIdComesBackAsItCame() throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        #expect(try bench.call("ping", id: "abc")["id"] as? String == "abc")
        #expect(try bench.call("ping", id: 7)["id"] as? Int == 7)
        #expect(try bench.call("ping")["result"] is [String: Any])
    }

    @Test func notificationsAndAnswersGetNoReply() throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        #expect(HubMCP.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, context: bench.context) == nil)
        #expect(HubMCP.handle(#"{"jsonrpc":"2.0","id":3,"result":{}}"#, context: bench.context) == nil)
    }

    @Test func whatItDoesNotKnowIsAnError() throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        #expect((try bench.call("resources/list")["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect((try bench.call("tools/call", ["name": "stop_everything"])["error"] as? [String: Any])?["code"] as? Int == -32602)
        let broken = try #require(HubMCP.handle("{not json", context: bench.context))
        #expect(broken.contains("-32700"))
    }

    @Test func everyToolOnlyReadsAndTakesNothing() throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        let tools = try #require((try bench.call("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["limits", "sessions", "background_tasks"])
        for tool in tools {
            #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object" && (schema["properties"] as? [String: Any])?.isEmpty == true)
        }
    }

    @Test func limitsComeFromWhatTheAppLastWrote() throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        #expect(try bench.tool("limits")["claude"] is NSNull, "the app has written nothing yet")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = UsageSnapshot(fetchedAt: bench.now, windows: [
            UsageWindow(key: "five_hour", title: "Сессия (5 ч)", utilization: 41.26, resetsAt: bench.now.addingTimeInterval(3600)),
            UsageWindow(key: "seven_day", title: "Неделя", utilization: 65, resetsAt: nil),
        ], extra: nil)
        try encoder.encode(snapshot).write(to: bench.context.snapshot)
        var history = LimitHistory()
        history.record(LimitHistory.key(.codex, "5 ч"), percent: 34, resetsAt: nil, at: bench.now.addingTimeInterval(-600))
        history.record(LimitHistory.key(.copilot, "30 дн"), percent: 12, resetsAt: nil, at: bench.now.addingTimeInterval(-3 * 86_400))
        history.save(to: bench.context.limitHistory)

        let limits = try bench.tool("limits")
        let windows = try #require((limits["claude"] as? [String: Any])?["windows"] as? [[String: Any]])
        #expect(windows.map { $0["key"] as? String } == ["five_hour", "seven_day"])
        #expect(windows[0]["used_percent"] as? Double == 41.3 && windows[0]["resets_at"] is String && windows[1]["resets_at"] is NSNull)
        let others = try #require(limits["other_services"] as? [[String: Any]])
        #expect(others.count == 1, "a reading three days old says nothing about now")
        #expect(others[0]["service"] as? String == "codex" && others[0]["window"] as? String == "5 ч" && others[0]["used_percent"] as? Double == 34)
    }

    @Test func backgroundTasksAreListedNewestFirstAndNothingIsRemoved() throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func run(_ id: String, started: TimeInterval, state: BackgroundRun.State, task: String, usage: RunUsage? = nil, agent: String? = nil) throws {
            let start = bench.now.addingTimeInterval(started)
            let run = BackgroundRun(id: id, project: "atlas", projectPath: "/p", folder: "/p", worktreeBranch: nil, commandTitle: "Своя задача",
                                    task: task, startedAt: start, timeLimitMinutes: 90, pid: nil, state: state,
                                    finishedAt: state == .running ? nil : start.addingTimeInterval(60), summary: state == .running ? nil : "Готово",
                                    pullRequestURL: nil, notified: true, agent: agent, usage: usage)
            try encoder.encode(run).write(to: bench.context.runs.appending(path: "\(id).json"))
        }
        // Long finished: the app's own loader would delete this file, the server must not.
        try run("old", started: -40 * 86_400, state: .succeeded, task: "старое")
        try run("new", started: -600, state: .running, task: String(repeating: "очень длинная задача\n", count: 40), agent: "codex")
        try run("mid", started: -7200, state: .succeeded, task: "починить поиск", usage: RunUsage(input: 1000, output: 500, cacheRead: 9000, cacheWrite: 100, cost: 1.234))
        try "не json".write(to: bench.context.runs.appending(path: "broken.json"), atomically: true, encoding: .utf8)

        let tasks = try #require(try bench.tool("background_tasks")["background_tasks"] as? [[String: Any]])
        #expect(tasks.map { $0["id"] as? String } == ["new", "mid", "old"])
        #expect(tasks[0]["agent"] as? String == "codex" && tasks[1]["agent"] as? String == "claude")
        let task = try #require(tasks[0]["task"] as? String)
        #expect(task.count == HubMCP.textLimit + 1 && !task.contains("\n") && task.hasSuffix("…"), "one line, cut short")
        #expect(tasks[0]["finished_at"] is NSNull && tasks[0]["tokens"] == nil)
        #expect(tasks[1]["tokens"] as? Int == 1600 && tasks[1]["cost_usd"] as? Double == 1.23)
        #expect(FileManager.default.fileExists(atPath: bench.context.runs.appending(path: "old.json").path), "read-only")
    }

    @Test func noSessionsIsAnEmptyList() throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        #expect((try bench.tool("sessions")["sessions"] as? [Any])?.isEmpty == true)
    }
}
