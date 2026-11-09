import AppKit
import Foundation
import IOKit.ps
import Observation

/// The «Telegram» module's bot (docs/specs/SPEC-telegram.md): reads its updates while this Mac answers it, answers only
/// the bound chat, keeps each screen in one message and runs `report.py` / `cleanup.py` like the panel's commands.
/// Two ways to the bot (§7): the shared bot through the relay (`TelegramRelay`), or the person's own bot, whose token is
/// the send-only bot's (`Telegram.keychainAccount`) and only in request URLs, never in the log.
@MainActor
@Observable
final class TelegramBotController {
    private(set) var hasToken = false
    var botName: String?
    var status: String?
    /// Another reader of this bot answered first (HTTP 409): another Mac or `bot.py`.
    var conflict = false
    var isReading = false
    /// «Привязать чат»: the code the `/start` link carries, while it is waited for.
    private(set) var bindingCode: String?
    var job: String?

    var isActive: () -> Bool = { true }
    /// The current profile (id, name), for its own menu.
    var currentProfile: () -> (id: String, name: String)? = { nil }
    /// 🚀: the profile's git projects, and the launcher that starts a task in one (like «Своя задача…»).
    var projectList: () -> [Project] = { [] }
    weak var launcher: LaunchController?
    /// «Не спать»: whether it holds the Mac now (nil — the module isn't installed), and for an hour or off.
    var keepAwakeState: () -> Bool? = { nil }
    var setKeepAwake: (Bool) -> Void = { _ in }
    /// Every AI service's limits, as the panel's «Лимиты AI» shows them.
    var limitServices: () -> [ServiceUsage] = { [] }
    /// Runs a quick command and returns how it went (`QuickToolsController.runForBot`).
    var runCommand: (QuickCommand) async -> (ok: Bool, text: String) = { _ in (false, "") }

    /// The shared bot's connection; used while `usesSharedBot`.
    let relay = TelegramRelay()
    /// Telegram's API, when set: the tests answer here, so nothing leaves the Mac.
    @ObservationIgnored var transport: (@MainActor (_ method: String, _ parameters: [String: Any], _ timeout: TimeInterval) async -> (Int, Data?))?
    /// The notifications' own copy of the bot; the tests leave the Keychain alone.
    @ObservationIgnored var reloadOwnBot: @MainActor (_ chatID: String) async -> Void = { await Telegram.loadOwnBot(chatID: $0) }

    let settings: AppSettings
    let sessions: SessionStore
    let runs: RunStore
    let usage: UsageStore
    let approvals: TelegramApprovals
    var token: String?
    var loop: Task<Void, Never>?
    var offset: Int?
    var lastRead: Date?
    var bindingExpires: Date?
    var commandsSetFor: String?
    /// Screens opened from the bottom menu, oldest first; a new one replaces them so the chat keeps one or two.
    var menuScreens: [Int] = []
    /// The latest message that carries the bottom menu: kept while other screens come and go.
    var menuCarrier: Int?
    /// The menu last sent to the chat, to send it again when the profile changes it.
    var sentMenu: [BotMenuItem]?
    /// Permission requests sent to the chat: request id → its message.
    var sentRequests: [String: (message: Int, request: ApprovalRequest, project: String)] = [:]
    /// Answered from the chat, until the request is gone: request id → allowed.
    var answeredHere: [String: Bool] = [:]
    /// A request whose message didn't go out, and when to try again.
    var retryRequests: [String: Date] = [:]
    private var requestLoop: Task<Void, Never>?
    /// 🚀 being set up: the project, then the task text once typed; it lapses after 10 minutes.
    var taskDraft: (path: String, name: String, text: String?, until: Date)?
    /// «Подключить Telegram» was pressed here: greet the chat once it is paired.
    var greetWhenPaired = false
    let macName = Host.current().localizedName ?? "Mac"

    init(settings: AppSettings, sessions: SessionStore, runs: RunStore, usage: UsageStore, approvals: TelegramApprovals) {
        self.settings = settings
        self.sessions = sessions
        self.runs = runs
        self.usage = usage
        self.approvals = approvals
    }

    /// «Общий бот»: the setting, else the shared bot unless an own bot is already set up.
    var usesSharedBot: Bool {
        get { (settings.telegramBot.shared ?? !hasToken) && relay.baseURL != nil }
        set { settings.telegramBot.shared = newValue }
    }

    /// The bound chat: the shared bot's paired one; the own bot's, else the `_daily-report` one (a private chat's id is
    /// the person's id, the same for every bot).
    var chatID: String {
        if usesSharedBot { return relay.chat ?? "" }
        let own = settings.telegramChatID.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return own }
        return Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory)?.chatID ?? ""
    }

    /// «Этот Мак отвечает боту». Own bot: by default a desktop Mac answers and a laptop doesn't (SPEC-telegram §9).
    /// Shared bot: the Worker decides — the last paired Mac, or the one that took over here or with /macs.
    var answersHere: Bool {
        get { usesSharedBot ? relay.answering : settings.telegramBot.answersHere ?? !Self.hasInternalBattery }
        set {
            if usesSharedBot { relay.setAnswering(newValue) } else { settings.telegramBot.answersHere = newValue }
        }
    }

    /// A bot in `_daily-report/config.json` that isn't this one yet: «Взять бота из _daily-report».
    var dailyReportBotAvailable: Bool {
        !hasToken && Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory) != nil
    }

    func start() {
        guard loop == nil else { return }
        relay.onApp = { [weak self] name, parameters in
            await self?.handleApp(name, parameters) ?? MiniAppReply.failure("gone").json
        }
        requestLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncRequests()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        loop = Task { [weak self] in
            await self?.loadToken()
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await tick()
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    /// The approvals bot is this same bot and it is read here (`TelegramApprovals.botReads`).
    func reads(_ token: String) -> Bool { isReading && self.token == token }

    // MARK: - Settings page

    func loadToken() async {
        token = await APIKeyStore.read(account: Telegram.keychainAccount)
        hasToken = token != nil
        await Telegram.loadOwnBot(chatID: settings.telegramChatID)
        await loadName()
    }

    func saveToken(_ value: String) async {
        do {
            try await APIKeyStore.save(value, account: Telegram.keychainAccount, label: "Telegram bot")
            await loadToken()
            status = botName == nil ? String(localized: "Telegram не принял токен") : nil
        } catch {
            status = error.localizedDescription
        }
    }

    func removeToken() async {
        await APIKeyStore.delete(account: Telegram.keychainAccount)
        token = nil
        hasToken = false
        botName = nil
        bindingCode = nil
        status = nil
        conflict = false
        commandsSetFor = nil
        await Telegram.loadOwnBot(chatID: settings.telegramChatID)
    }

    /// Copies the `_daily-report` bot's token and chat here (SPEC-telegram §1, migration).
    func adoptDailyReportBot() async {
        guard let file = Telegram.fileCredentials(dailyReportDirectory: settings.dailyReportDirectory) else { return }
        settings.telegramChatID = file.chatID
        await saveToken(file.token)
    }

    /// The `t.me` link whose «Start» sends `/start <code>`; the code lives 10 minutes.
    func startBinding() -> URL? {
        guard let botName else { return nil }
        let code = String(Int.random(in: 100_000...999_999))
        bindingCode = code
        bindingExpires = .now.addingTimeInterval(10 * 60)
        return URL(string: "https://t.me/\(botName.dropFirst())?start=\(code)")
    }

    func cancelBinding() {
        bindingCode = nil
        bindingExpires = nil
    }

    func unbind() {
        settings.telegramChatID = ""
        Task { await Telegram.loadOwnBot(chatID: "") }
    }

    /// «Подключить Telegram» (shared bot): opens the bot with a one-time code.
    func connectShared() async {
        guard let link = await relay.pairLink() else {
            status = String(localized: "Нет связи с общим ботом")
            return
        }
        status = nil
        greetWhenPaired = true
        NSWorkspace.shared.open(link)
    }

    /// «Отключить» (shared bot): this Mac leaves the chat.
    func disconnectShared() {
        relay.unpair()
        Telegram.shared = nil
    }

    /// «Проверить»: the home screen as a new message.
    func test() async {
        guard usesSharedBot || token != nil else { status = String(localized: "Сначала сохраните токен бота"); return }
        guard !chatID.isEmpty else { status = String(localized: "Сначала привяжите чат"); return }
        let ok = await show(.home, tapID: nil)
        status = ok ? String(localized: "Отправлено") : String(localized: "Бот не может написать в этот чат — откройте его в Telegram и нажмите «Start»")
    }
}
