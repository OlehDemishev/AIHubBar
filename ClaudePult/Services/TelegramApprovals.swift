import Foundation
import Observation

/// The Telegram side of answering permission requests: a message with «Разрешить» / «Отклонить» buttons, answered
/// from the phone. It needs its own bot: the `_daily-report` bot already reads its updates (`getUpdates`), and two
/// readers of one bot take each other's updates. The token lives in the Keychain (`telegram-approvals`).
enum TelegramApprovalText {
    static let keychainAccount = "telegram-approvals"

    static func html(_ request: ApprovalRequest) -> String {
        let project = RunMessage.escape(request.project ?? "Claude")
        let summary = request.summary.isEmpty ? "" : "\n<code>\(RunMessage.escape(request.summary))</code>"
        return "✋ <b>\(project)</b>: " + RunMessage.escape(String(localized: "Claude просит разрешение")) + " — \(RunMessage.escape(request.tool))" + summary
    }

    static func keyboard(_ request: ApprovalRequest) -> [String: Any] {
        ["inline_keyboard": [[
            ["text": "✅ " + String(localized: "Разрешить"), "callback_data": "allow:\(request.id)"],
            ["text": "❌ " + String(localized: "Отклонить"), "callback_data": "deny:\(request.id)"],
        ]]]
    }

    struct Answer: Equatable {
        var callbackID: String
        var requestID: String
        var allow: Bool
        var messageID: Int?
    }

    /// Button presses from `getUpdates`, only from the configured chat; the next offset.
    static func answers(in data: Data, chatID: String) -> (answers: [Answer], nextOffset: Int?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updates = object["result"] as? [[String: Any]] else { return ([], nil) }
        var answers: [Answer] = []
        var offset: Int?
        for update in updates {
            if let id = update["update_id"] as? Int { offset = max(offset ?? 0, id + 1) }
            guard let callback = update["callback_query"] as? [String: Any],
                  let callbackID = callback["id"] as? String,
                  let data = callback["data"] as? String,
                  let from = callback["from"] as? [String: Any],
                  "\((from["id"] as? NSNumber)?.stringValue ?? "")" == chatID else { continue }
            let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["allow", "deny"].contains(parts[0]), ApprovalFiles.isValidID(parts[1]) else { continue }
            let message = (callback["message"] as? [String: Any])?["message_id"] as? Int
            answers.append(Answer(callbackID: callbackID, requestID: parts[1], allow: parts[0] == "allow", messageID: message))
        }
        return (answers, offset)
    }
}

@MainActor
@Observable
final class TelegramApprovals {
    private(set) var botName: String?
    private(set) var status: String?
    private(set) var hasToken = false

    private let settings: AppSettings
    private let sessions: SessionStore
    private var token: String?
    private var loop: Task<Void, Never>?
    /// Request id → the Telegram message that asks about it.
    private var sent: [String: Int] = [:]
    private var offset: Int?

    init(settings: AppSettings, sessions: SessionStore) {
        self.settings = settings
        self.sessions = sessions
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.loadToken()
            while !Task.isCancelled {
                guard let self else { return }
                await tick()
                try? await Task.sleep(for: .seconds(sent.isEmpty ? 2 : 0.2))
            }
        }
    }

    func loadToken() async {
        token = await APIKeyStore.read(account: TelegramApprovalText.keychainAccount)
        hasToken = token != nil
    }

    func saveToken(_ value: String) async {
        do {
            try await APIKeyStore.save(value, account: TelegramApprovalText.keychainAccount, label: String(localized: "бот для ответов в Telegram"))
            await loadToken()
            await check()
        } catch {
            status = error.localizedDescription
        }
    }

    func removeToken() async {
        await APIKeyStore.delete(account: TelegramApprovalText.keychainAccount)
        token = nil
        hasToken = false
        botName = nil
        status = nil
    }

    /// «Проверить»: the bot's name, and a test message to the chat.
    func check() async {
        guard let token else { status = String(localized: "Сначала сохраните токен бота"); return }
        guard let me = await call(token, "getMe", [:]), let result = me["result"] as? [String: Any],
              let username = result["username"] as? String else {
            status = String(localized: "Telegram не принял токен")
            return
        }
        botName = "@" + username
        let ok = await call(token, "sendMessage", ["chat_id": chatID, "text": String(localized: "ClaudePult: сюда будут приходить запросы разрешений Claude.")]) != nil
        status = ok ? String(localized: "Работает: тестовое сообщение отправлено") : String(localized: "Бот не может написать в этот чат — откройте его в Telegram и нажмите «Start»")
    }

    private var chatID: String {
        let own = settings.telegramApprovalsChatID.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return own }
        return Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory)?.chatID ?? ""
    }

    private func tick() async {
        guard settings.telegramApprovals, let token, !chatID.isEmpty else { return }
        let open = sessions.approvals.values
        // New requests get a message; answered ones (here, in Claude or by timeout) lose their buttons.
        for request in open where sent[request.id] == nil {
            if let reply = await call(token, "sendMessage", [
                "chat_id": chatID, "text": TelegramApprovalText.html(request), "parse_mode": "HTML",
                "reply_markup": TelegramApprovalText.keyboard(request),
            ]), let message = (reply["result"] as? [String: Any])?["message_id"] as? Int {
                sent[request.id] = message
            }
        }
        for (id, message) in sent where !open.contains(where: { $0.id == id }) {
            sent[id] = nil
            _ = await call(token, "editMessageReplyMarkup", ["chat_id": chatID, "message_id": message, "reply_markup": ["inline_keyboard": []]])
        }
        guard !sent.isEmpty else { return }
        var parameters: [String: Any] = ["timeout": 20, "allowed_updates": ["callback_query"]]
        if let offset { parameters["offset"] = offset }
        guard let data = await callData(token, "getUpdates", parameters, timeout: 30) else { return }
        let (answers, next) = TelegramApprovalText.answers(in: data, chatID: chatID)
        if let next { offset = next }
        for answer in answers {
            sessions.decide(requestID: answer.requestID, allow: answer.allow)
            _ = await call(token, "answerCallbackQuery", ["callback_query_id": answer.callbackID,
                                                         "text": answer.allow ? String(localized: "Разрешено") : String(localized: "Отклонено")])
            if let message = answer.messageID ?? sent[answer.requestID] {
                _ = await call(token, "editMessageReplyMarkup", ["chat_id": chatID, "message_id": message, "reply_markup": ["inline_keyboard": []]])
            }
            sent[answer.requestID] = nil
            AppLog.info("Permission \(answer.allow ? "allowed" : "denied") from Telegram")
        }
    }

    private func call(_ token: String, _ method: String, _ parameters: [String: Any]) async -> [String: Any]? {
        guard let data = await callData(token, method, parameters, timeout: 20),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true else { return nil }
        return object
    }

    /// The URL holds the token: errors are logged with the method only.
    private func callData(_ token: String, _ method: String, _ parameters: [String: Any], timeout: TimeInterval) async -> Data? {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 { AppLog.error("Telegram \(method) returned HTTP \(code)") }
            return code == 200 ? data : nil
        } catch {
            AppLog.error("Telegram \(method) failed")
            return nil
        }
    }
}
