import Foundation
import Testing
@testable import AIHubBar

/// The Mini App (docs/specs/SPEC-telegram.md §10): what the page may ask and what it gets back. No real tokens here.
struct TelegramMiniAppTests {
    private func call(_ name: String, _ parameters: [String: Any] = [:]) -> MiniAppCall.Action? {
        MiniAppCall(action: name, parameters: (try? JSONSerialization.data(withJSONObject: parameters)) ?? Data())?.action
    }

    @Test func readsThePagesCalls() {
        #expect(call("state") == .state)
        #expect(call("answer", ["id": "0f3a9c", "allow": true]) == .answer(id: "0f3a9c", allow: true))
        #expect(call("report", ["ai": false]) == .report(ai: false, hours: nil))
        #expect(call("report", ["ai": true, "hours": 3]) == .report(ai: true, hours: 3))
        #expect(call("cleanup", ["run": true]) == .cleanup(run: true))
        #expect(call("task", ["project": "0a1b2c3d", "text": "  Почини сборку  "]) == .task(project: "0a1b2c3d", text: "Почини сборку"))
        #expect(call("taskAfterReset", ["project": "0a1b2c3d"]) == .taskAfterReset(project: "0a1b2c3d"))
        #expect(call("stopRun", ["id": "0f3a9c2e-1111-4222-8333-444455556666"]) == .stopRun(id: "0f3a9c2e-1111-4222-8333-444455556666"))
        #expect(call("event", ["id": "lim", "on": false]) == .event(.limitAlerts, on: false))
        #expect(call("quiet", ["from": 23, "to": 8]) == .quiet(QuietHours(from: 23, to: 8)))
        #expect(call("quiet", [:]) == .quiet(nil))
        #expect(call("mute", ["on": true]) == .mute(true))
        #expect(call("keepAwake", ["on": false]) == .keepAwake(false))
    }

    @Test func refusesWhatDoesntFit() {
        #expect(call("rm") == nil)
        #expect(call("answer", ["id": "../x", "allow": true]) == nil)
        #expect(call("answer", ["id": "0f3a9c"]) == nil)
        #expect(call("report", ["hours": 1000]) == nil)
        #expect(call("task", ["project": "../../etc", "text": "x"]) == nil)
        #expect(call("task", ["project": "0a1b2c3d", "text": "   "]) == nil)
        #expect(call("task", ["project": "0a1b2c3d", "text": String(repeating: "a", count: 4001)]) == nil)
        #expect(call("stopRun", ["id": "a b"]) == nil)
        #expect(call("event", ["id": "everything", "on": true]) == nil)
        #expect(call("quiet", ["from": 5, "to": 6]) == nil)
        #expect(MiniAppCall(action: "state", parameters: Data("garbage".utf8))?.action == .state)
    }

    @Test func replyIsJSONThePageReads() throws {
        let state = MiniAppState(
            mac: "Mac mini", freeBytes: 182_000_000_000, keepAwake: false, job: nil,
            sessions: [.init(project: "Ambo", agent: "Claude", waiting: true, detail: "Ждёт", since: Date(timeIntervalSince1970: 1_700_000_000))],
            requests: [.init(id: "0f3a9c", project: "Ambo", tool: "Bash", summary: "rm -rf build", task: nil)], canAnswer: true,
            services: [.init(title: "Claude", windows: [.init(title: "Сессия", percent: 42, resetsAt: Date(timeIntervalSince1970: 1_700_007_800))], stale: false)],
            projects: [.init(key: "0a1b2c3d", name: "Ambo")], runs: [], tasksAllowed: false, commands: [], commandsAllowed: false,
            events: [.init(id: "bg", title: "Итоги фоновых задач", on: true)], quiet: QuietHours(from: 23, to: 8),
            quietPresets: QuietHours.presets, mutedUntil: nil, hasDailyReport: true
        )
        let reply = MiniAppReply(ok: true, note: "Разрешено", state: state, question: .init(text: "Сессия 92 %", limit: true, project: "0a1b2c3d"))
        let object = try #require(try JSONSerialization.jsonObject(with: reply.json) as? [String: Any])
        let decoded = try #require(object["state"] as? [String: Any])
        #expect(object["ok"] as? Bool == true && object["note"] as? String == "Разрешено")
        #expect(decoded["mac"] as? String == "Mac mini" && decoded["tasksAllowed"] as? Bool == false)
        #expect((decoded["sessions"] as? [[String: Any]])?.first?["since"] as? Double == 1_700_000_000)
        #expect(((decoded["quiet"] as? [String: Any])?["from"]) as? Int == 23)
        #expect((object["question"] as? [String: Any])?["limit"] as? Bool == true)
        #expect(try JSONSerialization.jsonObject(with: MiniAppReply.failure("нет").json) as? [String: Any] != nil)
    }

    @Test func logTail() {
        let entries = (1...40).map { StreamJSON.Entry(id: $0, kind: $0 == 40 ? .error : .tool, text: String(repeating: "x", count: 500)) }
        let lines = MiniAppReply.logLines(entries)
        #expect(lines.count == 30 && lines.last?.kind == "error" && lines.first?.text.count == 400)
    }

    @Test func relayCarriesTheCalls() throws {
        guard case let .app(id, action, parameters) = RelayMessage.decode(#"{"type":"app","id":7,"action":"answer","params":{"id":"0f3a9c","allow":true}}"#) else {
            Issue.record("no app call")
            return
        }
        #expect(id == 7 && action == "answer")
        #expect(MiniAppCall(action: action, parameters: parameters)?.action == .answer(id: "0f3a9c", allow: true))
        let reply = RelayMessage.appReply(id: 7, body: Data(#"{"ok":true}"#.utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "appReply" && object["id"] as? Int == 7 && (object["body"] as? [String: Any])?["ok"] as? Bool == true)
    }

    @Test func removingTheBottomMenu() {
        var message = BotMessage(html: "☰")
        message.removesMenu = true
        #expect(message.replyMarkup["remove_keyboard"] as? Bool == true)
    }
}
