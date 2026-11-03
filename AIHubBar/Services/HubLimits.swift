import Foundation
import Observation
import WidgetKit

/// Limits and spend of AI services other than the Claude subscription (docs/specs/SPEC-hub.md). Each source turns on by
/// itself when its tool is on the Mac or its key is saved; the formats come from third-party docs, so every parser
/// is tolerant and a source that can't be read shows its error instead of numbers.
struct HubLimit: Equatable, Identifiable, Sendable {
    enum Source: String, CaseIterable, Identifiable, Sendable {
        case codex, openRouter, copilot, gemini, openAICosts, anthropicCosts, cursor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .codex: "Codex"
            case .openRouter: "OpenRouter"
            case .copilot: "GitHub Copilot"
            case .gemini: "Gemini CLI"
            case .openAICosts: String(localized: "OpenAI API")
            case .anthropicCosts: String(localized: "Anthropic API")
            case .cursor: "Cursor"
            }
        }

        /// Sources read with a key the person pastes (kept in the Keychain under this account).
        var keychainAccount: String? {
            switch self {
            case .openRouter: "hub-openrouter"
            case .openAICosts: "hub-openai-admin"
            case .anthropicCosts: "hub-anthropic-admin"
            case .codex, .copilot, .gemini, .cursor: nil
            }
        }

        /// For the menu bar.
        var shortTitle: String {
            switch self {
            case .codex: "Codex"
            case .openRouter: "OpenRouter"
            case .copilot: "Copilot"
            case .gemini: "Gemini"
            case .openAICosts: "OpenAI"
            case .anthropicCosts: "Anthropic"
            case .cursor: "Cursor"
            }
        }

        var keyPage: URL? {
            switch self {
            case .openRouter: URL(string: "https://openrouter.ai/settings/keys")
            case .openAICosts: URL(string: "https://platform.openai.com/settings/organization/admin-keys")
            case .anthropicCosts: URL(string: "https://console.anthropic.com/settings/admin-keys")
            case .codex, .copilot, .gemini, .cursor: nil
            }
        }

        /// What it needs, for Settings.
        var requirement: String {
            switch self {
            case .codex: String(localized: "установленный codex с входом через ChatGPT")
            case .openRouter: String(localized: "ключ OpenRouter")
            case .copilot: String(localized: "установленный gh с входом в GitHub и Copilot")
            case .gemini: String(localized: "установленный Gemini CLI")
            case .openAICosts: String(localized: "админский ключ организации OpenAI (sk-admin-…)")
            case .anthropicCosts: String(localized: "админский ключ Anthropic (sk-ant-admin…)")
            case .cursor: String(localized: "Cursor с входом и ваше согласие")
            }
        }
    }

    struct Window: Equatable, Sendable {
        var title: String
        /// 0…100 when the service says how much of a limit is used; nil for plain spend.
        var percent: Double?
        var detail: String?
        var resetsAt: Date?
        /// At the pace since this window was first seen, the limit runs out before the reset at this time.
        var runsOutAt: Date? = nil
    }

    /// The fullest limit, for the menu bar and the widget.
    var fullest: Double? { windows.compactMap(\.percent).max() }

    var source: Source
    var windows: [Window]
    var error: String?
    /// Plan, credits, context (Codex so far).
    var notes: [ServiceNote] = []
    var projects: [ProjectTokens] = []
    var id: Source { source }
}

// MARK: - The store

@MainActor
@Observable
final class HubLimitsStore {
    private(set) var limits: [HubLimit] = []
    private(set) var isRefreshing = false
    /// Which sources can be read right now (tool found, key saved, consent given); refreshed with the limits.
    private(set) var available: Set<HubLimit.Source> = []
    private(set) var savedKeys: Set<HubLimit.Source> = []
    var isActive: () -> Bool = { false }

    private let settings: AppSettings
    private var loop: Task<Void, Never>?
    /// Kept across restarts, so a relaunch doesn't announce the same threshold again.
    private var notified = Set(UserDefaults.standard.stringArray(forKey: "hubNotified") ?? []) {
        didSet { UserDefaults.standard.set(Array(notified.suffix(200)), forKey: "hubNotified") }
    }
    /// Readings of every window over the last days, for the forecast and the week by day; kept across restarts.
    private(set) var history = LimitHistory.load()

    /// Each service's limits as the panel draws them, the same way as Claude's (SPEC-ai-services stage 2).
    var usages: [ServiceUsage] { limits.map { ServiceUsage.hub($0, history: history) } }

    /// Source raw value → its fullest limit, for the menu bar.
    var percents: [String: Double] {
        Dictionary(limits.compactMap { limit in limit.fullest.map { (limit.source.rawValue, $0) } }) { first, _ in first }
    }

    static let widgetURL = SessionFiles.supportDirectory.appending(path: "other-ai.json")

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    func refresh() async {
        guard isActive(), !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var found: Set<HubLimit.Source> = [], keys: Set<HubLimit.Source> = []
        for source in HubLimit.Source.allCases {
            if let account = source.keychainAccount {
                if await APIKeyStore.exists(account: account) { found.insert(source); keys.insert(source) }
            } else if Self.toolPresent(source) {
                found.insert(source)
            }
        }
        available = found
        savedKeys = keys
        let sources = HubLimit.Source.allCases.filter { found.contains($0) && settings.hubEnabled($0) }
        let geminiLimit = settings.hubGeminiDailyLimit, geminiQuota = settings.hubGeminiQuota
        let results = await withTaskGroup(of: HubLimit.self) { group in
            for source in sources {
                group.addTask { await Self.read(source, geminiDailyLimit: geminiLimit, geminiQuota: geminiQuota) }
            }
            var all: [HubLimit] = []
            for await limit in group { all.append(limit) }
            return all
        }
        limits = forecast(HubLimit.Source.allCases.compactMap { source in results.first { $0.source == source } })
        announce(results)
        writeWidgetFile()
    }

    func saveKey(_ key: String, for source: HubLimit.Source) async throws {
        guard let account = source.keychainAccount else { return }
        try await APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: account, label: source.title)
        await refresh()
    }

    func deleteKey(for source: HubLimit.Source) async {
        guard let account = source.keychainAccount else { return }
        await APIKeyStore.delete(account: account)
        await refresh()
    }

    nonisolated static func toolPresent(_ source: HubLimit.Source) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch source {
        case .codex: return AgentKind.codex.detect() != nil || FileManager.default.fileExists(atPath: home.appending(path: ".codex/sessions").path)
        case .copilot: return HubFetch.tool("gh") != nil
        case .gemini: return FileManager.default.fileExists(atPath: home.appending(path: ".gemini").path)
        case .cursor: return FileManager.default.fileExists(atPath: home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path)
        case .openRouter, .openAICosts, .anthropicCosts: return false
        }
    }

    nonisolated static func read(_ source: HubLimit.Source, geminiDailyLimit: Int, geminiQuota: Bool) async -> HubLimit {
        func done(_ windows: [HubLimit.Window]?, _ error: HubError? = nil) -> HubLimit {
            if let windows { return HubLimit(source: source, windows: windows) }
            return HubLimit(source: source, windows: [], error: (error ?? .unreadable).text)
        }
        func fromHTTP(_ result: Result<Data, HubError>, _ parse: (Data) -> [HubLimit.Window]?) -> HubLimit {
            switch result {
            case let .success(data): done(parse(data))
            case let .failure(error): done(nil, error)
            }
        }
        switch source {
        case .codex:
            // Beyond the limits (SPEC-ai-services stage 3): plan and credits from the same answer, tokens per project
            // and the context from Codex's own threads.
            let extras = CodexThreads.extras()
            var limit: HubLimit
            if let path = AgentKind.codex.detect(), let data = await HubFetch.codexRPC(path: path), let windows = HubParse.codexRPC(data) {
                limit = done(windows)
                limit.notes = CodexThreads.accountNotes(data)
            } else {
                limit = done(HubFetch.codexSessions(), .missing)
            }
            limit.notes += extras.notes
            limit.projects = extras.projects
            return limit
        case .openRouter:
            guard let key = await APIKeyStore.read(account: "hub-openrouter") else { return done(nil, .missing) }
            return fromHTTP(await HubFetch.get(URL(string: "https://openrouter.ai/api/v1/key")!, headers: ["Authorization": "Bearer \(key)"]), HubParse.openRouter)
        case .copilot:
            guard let gh = HubFetch.tool("gh"),
                  let result = try? await ProcessRunner.run(gh, ["api", "/copilot_internal/user"], timeout: .seconds(20)) else { return done(nil, .missing) }
            guard result.exitCode == 0 else {
                return done(nil, .failed(result.stderrText.split(separator: "\n").first.map(String.init) ?? "gh"))
            }
            // Beyond the quota (SPEC-ai-services stage 6): tokens and AI credits per project and the context, from
            // Copilot CLI's own records when it is used here.
            var limit = done(HubParse.copilot(result.stdout))
            let extras = CopilotSessions.extras()
            limit.notes = extras.notes
            limit.projects = extras.projects
            return limit
        case .gemini:
            if geminiQuota, let token = HubFetch.geminiAccessToken() {
                let base = "https://cloudcode-pa.googleapis.com/v1internal"
                let headers = ["Authorization": "Bearer \(token)"]
                if case let .success(load) = await HubFetch.post(URL(string: base + ":loadCodeAssist")!, body: ["metadata": ["pluginType": "GEMINI"]], headers: headers),
                   let project = HubParse.object(load)?["cloudaicompanionProject"] as? String,
                   case let .success(quota) = await HubFetch.post(URL(string: base + ":retrieveUserQuota")!, body: ["project": project], headers: headers),
                   let windows = HubParse.geminiQuota(quota) {
                    return done(windows)
                }
            }
            return done([HubParse.geminiRequests(today: HubFetch.geminiTodayRequests(), dailyLimit: geminiDailyLimit)])
        case .openAICosts:
            guard let key = await APIKeyStore.read(account: "hub-openai-admin") else { return done(nil, .missing) }
            let start = Int(Calendar.current.dateInterval(of: .month, for: .now)?.start.timeIntervalSince1970 ?? 0)
            return fromHTTP(await HubFetch.get(URL(string: "https://api.openai.com/v1/organization/costs?start_time=\(start)&bucket_width=1d&limit=31")!,
                                               headers: ["Authorization": "Bearer \(key)"]), HubParse.openAICosts)
        case .anthropicCosts:
            guard let key = await APIKeyStore.read(account: "hub-anthropic-admin") else { return done(nil, .missing) }
            let start = (Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now).ISO8601Format()
            return fromHTTP(await HubFetch.get(URL(string: "https://api.anthropic.com/v1/organizations/cost_report?starting_at=\(start)&bucket_width=1d&limit=31")!,
                                               headers: ["x-api-key": key, "anthropic-version": "2023-06-01"]), HubParse.anthropicCosts)
        case .cursor:
            guard let token = await HubFetch.cursorToken() else { return done(nil, .missing) }
            return fromHTTP(await HubFetch.post(URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!,
                                                body: [:], headers: ["Authorization": "Bearer \(token)"]), HubParse.cursor)
        }
    }

    /// Records the readings and fills each window's «runs out at» from the pace since its last reset.
    private func forecast(_ limits: [HubLimit], now: Date = .now) -> [HubLimit] {
        let result = limits.map { limit in
            var limit = limit
            for index in limit.windows.indices {
                let window = limit.windows[index]
                guard let percent = window.percent else { continue }
                let key = LimitHistory.key(limit.source, window.title)
                history.record(key, percent: percent, resetsAt: window.resetsAt, at: now)
                limit.windows[index].runsOutAt = history.runsOut(key, resetsAt: window.resetsAt, now: now)
            }
            return limit
        }
        history.save()
        return result
    }

    /// `other-ai.json` for the «Лимиты» widget: the sandboxed widget only reads Application Support/ClaudePult.
    private func writeWidgetFile() {
        struct Entry: Encodable { var name: String; var percent: Double }
        let entries = limits.compactMap { limit in limit.fullest.map { Entry(name: limit.source.shortTitle, percent: $0) } }
        AppLog.attempt("Widget limits not written") {
            try FileManager.default.createDirectory(at: Self.widgetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: Self.widgetURL, options: .atomic)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudePultUsage")
    }

    /// Each service's thresholds (its own or the common ones), once per window and reset.
    private func announce(_ limits: [HubLimit]) {
        for limit in limits {
            let thresholds = settings.thresholds(for: ServiceTab(hub: limit.source)).sorted()
            for window in limit.windows {
                guard let percent = window.percent, let threshold = thresholds.last(where: { Double($0) <= percent }) else { continue }
                let key = "\(limit.source.rawValue)|\(window.title)|\(window.resetsAt.map { Int($0.timeIntervalSince1970 / 600) } ?? 0)|\(threshold)"
                guard !notified.contains(key) else { continue }
                notified.insert(key)
                let title = String(localized: "\(limit.source.title): использовано \(Int(percent.rounded())) %")
                let body = [window.title, window.detail, window.resetsAt.map { String(localized: "сброс \($0.formatted(date: .abbreviated, time: .shortened))") }]
                    .compactMap { $0 }.joined(separator: " · ")
                Notifier.post(id: "hub-\(key)", title: title, body: body)
                Telegram.notify(.limitAlerts, html: "⚠️ <b>\(RunMessage.escape(title))</b>\n\(RunMessage.escape(body))", settings: settings)
            }
        }
    }
}
