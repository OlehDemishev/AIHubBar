import Foundation

/// Finish messages for background runs: «✅/❌ <Проект>: <начало задачи> — <итог>, ссылка на PR» (docs/SPEC.md §2.4).
enum RunMessage {
    static let taskPrefixLength = 60

    static func icon(_ state: BackgroundRun.State) -> String {
        state == .succeeded ? "✅" : "❌"
    }

    static func taskStart(_ task: String) -> String {
        let flat = task.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > taskPrefixLength ? String(flat.prefix(taskPrefixLength - 1)) + "…" : flat
    }

    static func outcomeText(_ run: BackgroundRun) -> String {
        switch run.state {
        case .timedOut: String(localized: "остановлено по лимиту времени (\(run.timeLimitMinutes) мин)")
        case .stopped: String(localized: "остановлено вручную")
        case .running: run.pausedAt == nil ? String(localized: "выполняется") : String(localized: "на паузе до сброса лимита")
        case .succeeded, .failed: run.summary ?? (run.state == .succeeded ? String(localized: "готово") : String(localized: "завершилось с ошибкой"))
        }
    }

    /// Telegram HTML: user text is escaped, the PR link is the only markup besides the bold project name.
    static func telegramHTML(_ run: BackgroundRun) -> String {
        var text = "\(icon(run.state)) <b>\(escape(run.project))</b>: \(escape(taskStart(run.task))) — \(escape(outcomeText(run)))"
        if let url = run.pullRequestURL {
            let number = url.split(separator: "/").last.map { " #\($0)" } ?? ""
            text += "\n<a href=\"\(escape(url))\">PR\(number)</a>"
        }
        return text
    }

    static func notificationTitle(_ run: BackgroundRun) -> String {
        "\(icon(run.state)) \(run.project): \(taskStart(run.task))"
    }

    static func notificationBody(_ run: BackgroundRun) -> String {
        [outcomeText(run), run.pullRequestURL].compactMap { $0 }.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Sends messages with the bot set in Settings → Основные → Telegram (token in the Keychain), or else the one from
/// `_daily-report/config.json` (`telegram.bot_token`, `telegram.chat_id`). The token is never logged.
enum Telegram {
    struct Credentials: Sendable, Equatable {
        var token: String
        var chatID: String
    }

    static let keychainAccount = "telegram-bot"

    /// The bot from Settings, read from the Keychain at launch and whenever it changes.
    @MainActor static var ownBot: Credentials?

    @MainActor
    static func loadOwnBot(chatID: String) async {
        let token = await APIKeyStore.read(account: keychainAccount) ?? ""
        let chat = chatID.trimmingCharacters(in: .whitespaces)
        ownBot = token.isEmpty || chat.isEmpty ? nil : Credentials(token: token, chatID: chat)
    }

    @MainActor
    static func credentials(dailyReportDirectory: String) -> Credentials? {
        ownBot ?? fileCredentials(dailyReportDirectory: dailyReportDirectory)
    }

    static func fileCredentials(dailyReportDirectory: String) -> Credentials? {
        let url = URL(fileURLWithPath: dailyReportDirectory).appending(path: "config.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return credentials(fromConfig: data)
    }

    static func credentials(fromConfig data: Data) -> Credentials? {
        guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let telegram = config["telegram"] as? [String: Any],
              let token = telegram["bot_token"] as? String, !token.isEmpty
        else { return nil }
        let chat: String? = (telegram["chat_id"] as? String) ?? (telegram["chat_id"] as? NSNumber)?.stringValue
        guard let chat, !chat.isEmpty else { return nil }
        return Credentials(token: token, chatID: chat)
    }

    /// «Определить»: the chat of the latest message sent to the bot (the person writes to it first).
    static func latestChat(token: String) async -> String? {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getUpdates") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return latestChat(in: data)
    }

    static func latestChat(in data: Data) -> String? {
        let updates = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"] as? [[String: Any]] ?? []
        return updates.reversed().lazy.compactMap { update -> String? in
            let message = (update["message"] ?? update["my_chat_member"]) as? [String: Any]
            return ((message?["chat"] as? [String: Any])?["id"] as? NSNumber)?.stringValue
        }.first
    }

    /// Returns true on success. Errors are logged without the request URL (it contains the token).
    static func send(html: String, with credentials: Credentials) async -> Bool {
        guard let url = URL(string: "https://api.telegram.org/bot\(credentials.token)/sendMessage") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": credentials.chatID,
            "text": html,
            "parse_mode": "HTML",
            "disable_web_page_preview": true,
        ])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                AppLog.info("Telegram message sent")
            } else {
                AppLog.error("Telegram sendMessage returned HTTP \(status)")
            }
            return status == 200
        } catch let error as URLError {
            AppLog.error("Telegram sendMessage failed: URLError \(error.code.rawValue)")
            return false
        } catch {
            AppLog.error("Telegram sendMessage failed")
            return false
        }
    }
}
