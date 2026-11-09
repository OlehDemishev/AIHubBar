import Foundation
import IOKit.ps

/// The screens' messages and Telegram's API.
extension TelegramBotController {
    // MARK: - Screens

    var homeScreen: BotMessage {
        let activity = ClaudeActivity(sessions: sessions, runs: runs)
        return BotScreens.home(BotHomeState(
            macName: macName, session: usage.snapshot?.session, week: usage.snapshot?.week,
            working: activity.runningSessions, waiting: sessions.waitingCount, runs: runs.running.count
        ), now: .now)
    }

    func reportsScreen(job: String?) -> BotMessage {
        let file = Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory)
        return BotScreens.reports(job: job, otherBot: file != nil && (usesSharedBot || file?.token != token))
    }

    var macScreen: BotMessage {
        let free = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return BotScreens.mac(freeBytes: free, job: job, keepAwake: keepAwakeState())
    }

    var helpScreen: BotMessage {
        let file = URL(fileURLWithPath: settings.dailyReportDirectory).appending(path: "help.txt")
        return BotScreens.help(hasAllCommands: FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Telegram

    func loadName() async {
        guard token != nil else { return }
        let (code, data) = await api("getMe", [:], timeout: 20)
        let result = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["result"] as? [String: Any]
        botName = code == 200 ? (result?["username"] as? String).map { "@" + $0 } : nil
    }

    func setCommands() async {
        let commands = BotCommand.menuList.map { ["command": $0.command, "description": $0.description] }
        _ = await api("setMyCommands", ["commands": commands], timeout: 20)
        _ = await api("setChatMenuButton", ["menu_button": ["type": "commands"]], timeout: 20)
    }

    /// The new message's id.
    func send(_ message: BotMessage) async -> Int? {
        var parameters: [String: Any] = ["chat_id": chatID, "text": message.html, "parse_mode": "HTML", "disable_web_page_preview": true]
        if message.installsMenu || message.removesMenu || !message.buttons.isEmpty { parameters["reply_markup"] = message.replyMarkup }
        let (_, data) = await api("sendMessage", parameters, timeout: 20)
        let object = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        return (object?["result"] as? [String: Any])?["message_id"] as? Int
    }

    func edit(_ messageID: Int, _ message: BotMessage) async {
        _ = await api("editMessageText", [
            "chat_id": chatID, "message_id": messageID, "text": message.html, "parse_mode": "HTML",
            "disable_web_page_preview": true, "reply_markup": message.replyMarkup,
        ], timeout: 20)
    }

    /// Bots may delete messages in a private chat for 48 hours; older ones simply stay.
    func delete(_ messageID: Int) async {
        _ = await api("deleteMessage", ["chat_id": chatID, "message_id": messageID], timeout: 20)
    }

    func answerPress(_ id: String, _ text: String?) async {
        var parameters: [String: Any] = ["callback_query_id": id]
        if let text { parameters["text"] = text }
        _ = await api("answerCallbackQuery", parameters, timeout: 20)
    }

    /// A Telegram method through the shared bot or straight to the own one.
    func api(_ method: String, _ parameters: [String: Any], timeout: TimeInterval) async -> (Int, Data?) {
        if let transport { return await transport(method, parameters, timeout) }
        if usesSharedBot { return await relay.call(method, parameters) }
        guard let token else { return (0, nil) }
        return await Self.call(token, method, body: try? JSONSerialization.data(withJSONObject: parameters), timeout: timeout)
    }

    /// HTTP status and body. The URL holds the token: errors are logged with the method only; «message is not
    /// modified» (400 on 🔄 with nothing new) is not an error worth a line.
    nonisolated static func call(_ token: String, _ method: String, body: Data?, timeout: TimeInterval) async -> (Int, Data?) {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { return (0, nil) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200, !(code == 400 && ["editMessageText", "deleteMessage"].contains(method)) { AppLog.error("Telegram \(method) returned HTTP \(code)") }
            return (code, code == 200 ? data : nil)
        } catch {
            if (error as? URLError)?.code != .timedOut { AppLog.error("Telegram \(method) failed") }
            return (0, nil)
        }
    }

    /// A laptop: has an internal battery.
    nonisolated static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
