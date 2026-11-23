import Foundation
import Testing
@testable import AIHubBar

/// «Агент мог застрять»: a long quiet stretch and the same command over and over.
struct StuckWatchTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(id: String = "s", tool: String? = nil, command: String? = nil, toolAt: Date? = nil, prompt: Date? = nil,
                         updated: Date) throws -> Session {
        var json: [String: Any] = ["session_id": id, "cwd": "/P/A", "project": "A", "state": "running", "updated_at": updated.ISO8601Format()]
        if let tool { json["last_tool"] = tool }
        if let command { json["last_target"] = command }
        if let toolAt { json["last_tool_at"] = toolAt.ISO8601Format() }
        if let prompt { json["prompt_at"] = prompt.ISO8601Format() }
        return try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func quietOncePerStretch() throws {
        var watch = StuckWatch()
        let s = try session(tool: "Read", toolAt: start, updated: start)
        #expect(watch.evaluate([(s, .running)], now: start.addingTimeInterval(60)).isEmpty)
        #expect(watch.evaluate([(s, .running)], now: start.addingTimeInterval(19 * 60)).isEmpty)
        #expect(watch.evaluate([(s, .running)], now: start.addingTimeInterval(21 * 60))
            == [StuckWatch.Alert(sessionID: "s", reason: .quiet(minutes: 21))])
        #expect(watch.evaluate([(s, .running)], now: start.addingTimeInterval(40 * 60)).isEmpty)

        // It moved and went quiet again: a new stretch.
        let later = start.addingTimeInterval(45 * 60)
        let moved = try session(tool: "Read", toolAt: later, updated: later)
        #expect(watch.evaluate([(moved, .running)], now: later.addingTimeInterval(60)).isEmpty)
        #expect(watch.evaluate([(moved, .running)], now: later.addingTimeInterval(20 * 60)).count == 1)
    }

    @Test func oldQuietIsNotReplayedAtStart() throws {
        var watch = StuckWatch()
        let s = try session(updated: start)
        #expect(watch.evaluate([(s, .running)], now: start.addingTimeInterval(3 * 3600)).isEmpty)
        #expect(watch.evaluate([(s, .running)], now: start.addingTimeInterval(3 * 3600 + 15)).isEmpty)
    }

    @Test func waitingAndFinishedSessionsAreNotStuck() throws {
        var watch = StuckWatch()
        let s = try session(updated: start)
        _ = watch.evaluate([(s, .waiting)], now: start)
        #expect(watch.evaluate([(s, .waiting)], now: start.addingTimeInterval(30 * 60)).isEmpty)
        #expect(watch.evaluate([(s, .done)], now: start.addingTimeInterval(31 * 60)).isEmpty)
    }

    @Test func sameCommandAgainAndAgain() throws {
        var watch = StuckWatch()
        var alerts: [StuckWatch.Alert] = []
        // Edit, test, edit, test…: the test command comes back every other call.
        for step in 0..<12 {
            let at = start.addingTimeInterval(Double(step) * 30)
            let isEdit = step.isMultiple(of: 2)
            let s = try session(tool: isEdit ? "Edit" : "Bash", command: isEdit ? "A.swift" : "npm test", toolAt: at, updated: at)
            alerts += watch.evaluate([(s, .running)], now: at)
        }
        #expect(alerts == [StuckWatch.Alert(sessionID: "s", reason: .loop(times: 5, command: "npm test"))])
    }

    @Test func editsOfOneFileAreNotALoop() throws {
        var watch = StuckWatch()
        var alerts: [StuckWatch.Alert] = []
        for step in 0..<10 {
            let at = start.addingTimeInterval(Double(step) * 70)
            let s = try session(tool: "Edit", command: "A.swift", toolAt: at, updated: at)
            alerts += watch.evaluate([(s, .running)], now: at)
        }
        #expect(alerts.isEmpty)
    }

    @Test func newRequestStartsTheCountAgain() throws {
        var watch = StuckWatch()
        var alerts: [StuckWatch.Alert] = []
        for step in 0..<8 {
            let at = start.addingTimeInterval(Double(step) * 70)
            // The fifth run belongs to a new request.
            let prompt = step < 4 ? start : start.addingTimeInterval(4 * 70 - 1)
            let s = try session(tool: "Bash", command: "make", toolAt: at, prompt: prompt, updated: at)
            alerts += watch.evaluate([(s, .running)], now: at)
        }
        #expect(alerts.isEmpty)
    }

    @Test func texts() throws {
        let s = try session(updated: start)
        #expect(StuckWatch.title(s).contains("A"))
        #expect(StuckWatch.body(.quiet(minutes: 25)).contains("25"))
        #expect(StuckWatch.body(.loop(times: 5, command: "npm test")).contains("npm test"))
    }
}
