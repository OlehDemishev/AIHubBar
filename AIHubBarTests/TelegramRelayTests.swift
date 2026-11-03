import Foundation
import Testing
@testable import AIHubBar

/// The shared bot's WebSocket messages (docs/specs/SPEC-telegram.md §7, relay/telegram/src/hub.js on the other end).
struct TelegramRelayTests {
    @Test func readsTheWorkersMessages() throws {
        #expect(RelayMessage.decode(#"{"type":"hello","bot":"AIHubBarBot","chat":"42","answering":true,"macs":2}"#)
                == .hello(bot: "AIHubBarBot", chat: "42", answering: true, macs: 2))
        #expect(RelayMessage.decode(#"{"type":"hello","bot":null,"chat":null,"answering":false,"macs":0}"#)
                == .hello(bot: nil, chat: nil, answering: false, macs: 0))
        #expect(RelayMessage.decode(#"{"type":"pairCode","id":3,"code":"abc","link":"https://t.me/AIHubBarBot?start=abc"}"#)
                == .pairCode(id: 3, link: URL(string: "https://t.me/AIHubBarBot?start=abc")))
        guard case let .reply(id, status, body) = RelayMessage.decode(#"{"type":"reply","id":7,"status":200,"body":{"ok":true,"result":{"message_id":5}}}"#) else {
            Issue.record("no reply")
            return
        }
        #expect(id == 7 && status == 200)
        let bodyData = try #require(body)
        let object = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect((object["result"] as? [String: Any])?["message_id"] as? Int == 5)
        #expect(RelayMessage.decode("pong") == nil)
        #expect(RelayMessage.decode(#"{"type":"reply"}"#) == nil)
        #expect(RelayMessage.decode(#"{"type":"surprise"}"#) == nil)
    }

    /// Updates from the relay read exactly like the own bot's `getUpdates`.
    @Test func updatesReadLikeGetUpdates() throws {
        guard case let .update(data) = RelayMessage.decode(
            #"{"type":"update","update":{"update_id":9,"message":{"message_id":4,"date":1700000000,"text":"🏠 Главная","chat":{"id":42,"type":"private"},"from":{"id":42}}}}"#
        ) else {
            Issue.record("no update")
            return
        }
        let (updates, next) = BotUpdate.parse(RelayMessage.updatesResponse([data]))
        #expect(next == 10)
        #expect(updates.first?.kind == .message(text: "🏠 Главная", messageID: 4))
        #expect(updates.first?.isFrom(chat: "42") == true)
        #expect(BotUpdate.parse(RelayMessage.updatesResponse([])).updates.isEmpty)
    }

    @Test func writesTheMacsMessages() throws {
        let call = try #require(try JSONSerialization.jsonObject(with: Data(RelayMessage.call(id: 2, method: "sendMessage", parameters: ["text": "hi"]).utf8)) as? [String: Any])
        #expect(call["type"] as? String == "call" && call["id"] as? Int == 2 && call["method"] as? String == "sendMessage")
        #expect((call["params"] as? [String: Any])?["text"] as? String == "hi")
        #expect(RelayMessage.pair(id: 4).contains(#""type":"pair""#))
        #expect(RelayMessage.answer(false).contains(#""on":false"#))
        #expect(RelayMessage.unpair == #"{"type":"unpair"}"#)
    }

    @Test func socketAddress() {
        #expect(RelayMessage.socketURL(URL(string: "https://aihubbar-telegram.example.workers.dev")!)?.absoluteString
                == "wss://aihubbar-telegram.example.workers.dev/v1/connect")
        #expect(RelayMessage.socketURL(URL(string: "http://localhost:8787/")!)?.absoluteString == "ws://localhost:8787/v1/connect")
    }
}
