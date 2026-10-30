import Foundation
import Testing
@testable import ClaudePult

/// Permission requests answered from Telegram: the message, its buttons and the button presses.
struct TelegramApprovalTests {
    private let request = ApprovalRequest(id: "0f3a9c", sessionID: "s", project: "Ambo<x>", tool: "Bash",
                                          summary: "rm -rf build && echo \"ok\"", created: 0, pid: nil)

    @Test func messageEscapesEverything() {
        let html = TelegramApprovalText.html(request)
        #expect(html.contains("<b>Ambo&lt;x&gt;</b>"))
        #expect(html.contains("<code>rm -rf build &amp;&amp; echo &quot;ok&quot;</code>"))
        #expect(html.contains("Bash"))
    }

    @Test func buttonsCarryTheRequest() throws {
        let rows = try #require(TelegramApprovalText.keyboard(request)["inline_keyboard"] as? [[[String: String]]])
        #expect(rows.first?.map { $0["callback_data"] } == ["allow:0f3a9c", "deny:0f3a9c"])
    }

    @Test func onlyThisChatsPresses() throws {
        let updates: [String: Any] = ["ok": true, "result": [
            ["update_id": 10, "callback_query": ["id": "c1", "data": "allow:0f3a9c", "from": ["id": 42], "message": ["message_id": 7]]],
            // Someone else who found the bot.
            ["update_id": 11, "callback_query": ["id": "c2", "data": "allow:0f3a9c", "from": ["id": 99]]],
            // Tampered data.
            ["update_id": 12, "callback_query": ["id": "c3", "data": "allow:../../x", "from": ["id": 42]]],
            ["update_id": 13, "callback_query": ["id": "c4", "data": "drop:0f3a9c", "from": ["id": 42]]],
            ["update_id": 14, "callback_query": ["id": "c5", "data": "deny:0f3a9c", "from": ["id": 42]]],
            ["update_id": 15, "message": ["text": "hi"]],
        ]]
        let (answers, next) = TelegramApprovalText.answers(in: try JSONSerialization.data(withJSONObject: updates), chatID: "42")
        #expect(answers == [
            .init(callbackID: "c1", requestID: "0f3a9c", allow: true, messageID: 7),
            .init(callbackID: "c5", requestID: "0f3a9c", allow: false, messageID: nil),
        ])
        #expect(next == 16)
        #expect(TelegramApprovalText.answers(in: Data("garbage".utf8), chatID: "42").answers.isEmpty)
    }
}
