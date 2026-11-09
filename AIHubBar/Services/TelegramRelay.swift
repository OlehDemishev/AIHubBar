import Foundation
import Observation

/// The shared bot's messages over the Worker's WebSocket (docs/specs/SPEC-telegram.md §7, `relay/telegram`). Pure, so
/// the tests can read them.
enum RelayMessage {
    enum Event: Equatable {
        case hello(bot: String?, chat: String?, answering: Bool, macs: Int)
        /// One Telegram update, as JSON.
        case update(Data)
        case reply(id: Int, status: Int, body: Data?)
        case pairCode(id: Int, link: URL?)
        /// A Mini App call (§10): its id, the action and the parameters as JSON.
        case app(id: Int, action: String, parameters: Data)
    }

    static func decode(_ text: String) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "hello":
            return .hello(bot: object["bot"] as? String, chat: object["chat"] as? String,
                          answering: object["answering"] as? Bool ?? false, macs: object["macs"] as? Int ?? 0)
        case "update":
            guard let update = object["update"], let data = try? JSONSerialization.data(withJSONObject: update) else { return nil }
            return .update(data)
        case "reply":
            guard let id = object["id"] as? Int else { return nil }
            let body = object["body"].flatMap { $0 is NSNull ? nil : try? JSONSerialization.data(withJSONObject: $0) }
            return .reply(id: id, status: object["status"] as? Int ?? 0, body: body)
        case "pairCode":
            guard let id = object["id"] as? Int else { return nil }
            return .pairCode(id: id, link: (object["link"] as? String).flatMap(URL.init(string:)))
        case "app":
            guard let id = object["id"] as? Int, let action = object["action"] as? String else { return nil }
            let parameters = (object["params"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
            return .app(id: id, action: action, parameters: parameters)
        default:
            return nil
        }
    }

    static func call(id: Int, method: String, parameters: [String: Any]) -> String {
        encode(["type": "call", "id": id, "method": method, "params": parameters])
    }

    static func pair(id: Int) -> String { encode(["type": "pair", "id": id]) }
    static func answer(_ on: Bool) -> String { encode(["type": "answer", "on": on]) }
    static let unpair = #"{"type":"unpair"}"#

    /// The reply to a Mini App call; `body` is JSON already.
    static func appReply(id: Int, body: Data) -> String {
        #"{"type":"appReply","id":"# + "\(id)" + #","body":"# + String(decoding: body, as: UTF8.self) + "}"
    }

    /// Updates in `getUpdates`' shape, so `BotUpdate.parse` reads them like the own bot's.
    static func updatesResponse(_ updates: [Data]) -> Data {
        let result = updates.compactMap { try? JSONSerialization.jsonObject(with: $0) }
        return (try? JSONSerialization.data(withJSONObject: ["ok": true, "result": result])) ?? Data()
    }

    /// `https://…workers.dev` → `wss://…workers.dev/v1/connect`.
    static func socketURL(_ base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/connect"
        return components.url
    }

    private static func encode(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// This Mac's connection to the shared bot: registers once (the key in the Keychain), keeps one WebSocket to the
/// Worker, reconnects after sleep, and hands the updates to `TelegramBotController`. The key is never logged.
@MainActor
@Observable
final class TelegramRelay {
    /// The Worker's address (relay/telegram/README.md). A Mac can be pointed elsewhere with
    /// `defaults write com.demishev.claudepult telegramRelayURL https://…`.
    static let defaultURL = "https://aihubbar-telegram.oleh-demishev.workers.dev"
    static let keychainAccount = "telegram-relay"

    private(set) var connected = false
    private(set) var bot: String?
    /// The paired chat. Set from outside only by the tests.
    var chat: String?
    private(set) var answering = false
    private(set) var macs = 0
    private(set) var lastError: String?
    /// Answers the Mini App's calls (`TelegramBotController.handleApp`).
    @ObservationIgnored var onApp: ((String, Data) async -> Data)?

    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var nextID = 1
    private var calls: [Int: CheckedContinuation<(Int, Data?), Never>] = [:]
    private var pairings: [Int: CheckedContinuation<URL?, Never>] = [:]
    private var updates: [Data] = []
    private var waiter: CheckedContinuation<Void, Never>?

    var baseURL: URL? {
        let custom = UserDefaults.standard.string(forKey: "telegramRelayURL") ?? ""
        return URL(string: custom.isEmpty ? Self.defaultURL : custom).flatMap { $0.host() == nil ? nil : $0 }
    }

    var isRunning: Bool { loop != nil }

    func start(name: String) {
        guard loop == nil, baseURL != nil else { return }
        loop = Task { [weak self] in
            var pause = 2.0
            while !Task.isCancelled {
                guard let self else { return }
                if await self.connectOnce(name: name) { pause = 2 }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(pause))
                pause = min(pause * 2, 60)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        dropConnection()
    }

    /// A Telegram method through the Worker, which sends it into this Mac's chat.
    func call(_ method: String, _ parameters: [String: Any]) async -> (Int, Data?) {
        guard let socket, connected else { return (0, nil) }
        let id = takeID()
        let text = RelayMessage.call(id: id, method: method, parameters: parameters)
        return await withCheckedContinuation { continuation in
            calls[id] = continuation
            socket.send(.string(text)) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.calls.removeValue(forKey: id)?.resume(returning: (0, nil)) }
            }
        }
    }

    /// «Подключить Telegram»: the `t.me` link with a fresh code.
    func pairLink() async -> URL? {
        guard let socket, connected else { return nil }
        let id = takeID()
        return await withCheckedContinuation { continuation in
            pairings[id] = continuation
            socket.send(.string(RelayMessage.pair(id: id))) { _ in }
        }
    }

    func setAnswering(_ on: Bool) {
        socket?.send(.string(RelayMessage.answer(on))) { _ in }
    }

    func unpair() {
        socket?.send(.string(RelayMessage.unpair)) { _ in }
    }

    /// The next updates, waiting up to `timeout` seconds for some.
    func nextUpdates(timeout: Double) async -> Data {
        if updates.isEmpty {
            let wake = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.wakeWaiter()
            }
            await withCheckedContinuation { continuation in waiter = continuation }
            wake.cancel()
        }
        defer { updates.removeAll() }
        return RelayMessage.updatesResponse(updates)
    }

    // MARK: - The socket

    /// One connection, until it drops; true if it got as far as the Worker's hello.
    private func connectOnce(name: String) async -> Bool {
        guard let base = baseURL, let key = await deviceKey(name: name, base: base), let url = RelayMessage.socketURL(base) else {
            return false
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        let pinger = Task { [weak socket] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                socket?.send(.string("ping")) { _ in }
            }
        }
        defer { pinger.cancel() }
        var greeted = false
        while true {
            guard let message = try? await socket.receive() else { break }
            guard case let .string(text) = message, let event = RelayMessage.decode(text) else { continue }
            if case .hello = event { greeted = true }
            receive(event)
        }
        if self.socket === socket { self.socket = nil }
        if !greeted {
            lastError = String(localized: "Нет связи с общим ботом")
            // A key the Worker doesn't know (its storage was reset): register again next time.
            if (socket.response as? HTTPURLResponse)?.statusCode == 401 {
                AppLog.error("Telegram relay: unknown device, registering again")
                await APIKeyStore.delete(account: Self.keychainAccount)
            }
        }
        dropConnection()
        return greeted
    }

    private func receive(_ event: RelayMessage.Event) {
        switch event {
        case let .hello(bot, chat, answering, macs):
            connected = true
            lastError = nil
            self.bot = bot
            self.chat = chat
            self.answering = answering
            self.macs = macs
        case let .update(data):
            updates.append(data)
            wakeWaiter()
        case let .reply(id, status, body):
            calls.removeValue(forKey: id)?.resume(returning: (status, body))
        case let .pairCode(id, link):
            pairings.removeValue(forKey: id)?.resume(returning: link)
        case let .app(id, action, parameters):
            Task { [weak self] in
                guard let self, let onApp else { return }
                let body = await onApp(action, parameters)
                socket?.send(.string(RelayMessage.appReply(id: id, body: body))) { _ in }
            }
        }
    }

    private func dropConnection() {
        connected = false
        answering = false
        for (_, call) in calls { call.resume(returning: (0, nil)) }
        calls.removeAll()
        for (_, pairing) in pairings { pairing.resume(returning: nil) }
        pairings.removeAll()
        wakeWaiter()
    }

    private func wakeWaiter() {
        waiter?.resume()
        waiter = nil
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// The key from the Keychain, or a new registration.
    private func deviceKey(name: String, base: URL) async -> String? {
        if let key = await APIKeyStore.read(account: Self.keychainAccount) { return key }
        var request = URLRequest(url: base.appending(path: "v1/devices"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let key = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["device_key"] as? String else {
            lastError = String(localized: "Нет связи с общим ботом")
            return nil
        }
        do {
            try await APIKeyStore.save(key, account: Self.keychainAccount, label: String(localized: "общий бот Telegram"))
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        AppLog.info("Telegram relay: this Mac registered")
        return key
    }

    /// The Worker forgot this Mac (or it was unpaired for good): a new key next time.
    func forgetDevice() async {
        stop()
        await APIKeyStore.delete(account: Self.keychainAccount)
        chat = nil
        bot = nil
    }
}
