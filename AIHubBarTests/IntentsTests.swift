import Foundation
import Testing
@testable import AIHubBar

/// The Shortcuts actions: picking a project by its name and the «Кто ждёт ответа» line.
struct IntentsTests {
    @Test func aNameMeansOneThing() {
        let names = ["Ambo", "Ambo Site", "Cantero"]
        #expect(IntentMatch.pick("ambo", in: names) { $0 } == "Ambo", "the whole name, any case")
        #expect(IntentMatch.pick("amb", in: names) { $0 } == nil, "two projects: neither is picked")
        #expect(IntentMatch.pick("cant", in: names) { $0 } == "Cantero")
        #expect(IntentMatch.pick("nothing", in: names) { $0 } == nil)
    }

    @Test func whoWaits() throws {
        func session(_ project: String, message: String? = nil) throws -> Session {
            var json: [String: Any] = ["session_id": project, "cwd": "/P/\(project)", "project": project, "state": "waiting",
                                       "updated_at": Date(timeIntervalSince1970: 1_800_000_000).ISO8601Format(), "first_prompt": "Fix the build"]
            if let message { json["message"] = message }
            return try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(WaitingSessionsIntent.text([]) == "Никто не ждёт ответа")
        let ambo = try session("Ambo", message: "Which port?")
        let site = try session("Site")
        #expect(WaitingSessionsIntent.text([ambo, site]) == "Ambo: Which port?; Site: Fix the build")
    }
}
