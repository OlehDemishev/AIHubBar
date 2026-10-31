import Foundation
import Observation
import WidgetKit

/// Limits and spend of AI services other than the Claude subscription (docs/SPEC-hub.md). Each source turns on by
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
    var id: Source { source }
}

// MARK: - Parsing the services' answers

enum HubParse {
    static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Unix seconds, Unix milliseconds or an ISO date — the services disagree, and change it between versions.
    static func date(_ value: Any?) -> Date? {
        if let number = number(value) { return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) }
        if let string = value as? String {
            return ISODate.parse(string) ?? (try? Date(string, strategy: Date.ISO8601FormatStyle().year().month().day()))
        }
        return nil
    }

    static func money(_ dollars: Double) -> String {
        dollars.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func windowTitle(minutes: Double?) -> String {
        guard let minutes else { return String(localized: "лимит") }
        if minutes <= 24 * 60 { return String(localized: "\(Int((minutes / 60).rounded())) ч") }
        return minutes >= 7 * 24 * 60 - 60 ? String(localized: "неделя") : String(localized: "\(Int((minutes / 1440).rounded())) дн")
    }

    // Codex: `account/rateLimits/read` of `codex app-server`: rateLimits.primary / secondary — usedPercent, resetsAt,
    // windowDurationMins (names vary: snake or camel case).
    static func codexRPC(_ data: Data) -> [HubLimit.Window]? {
        guard let object = object(data) else { return nil }
        let result = object["result"] as? [String: Any] ?? object
        guard let limits = (result["rateLimits"] ?? result["rate_limits"]) as? [String: Any] else { return nil }
        return codexWindows(limits, now: .now)
    }

    /// A session log line: `event_msg` with `payload.type == "token_count"` and `payload.rate_limits`.
    static func codexSessionLine(_ line: Data) -> [HubLimit.Window]? {
        guard let object = object(line), let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let written = (object["timestamp"] as? String).flatMap(ISODate.parse) ?? .now
        return codexWindows(limits, now: written)
    }

    static func codexWindows(_ limits: [String: Any], now: Date) -> [HubLimit.Window]? {
        let windows = ["primary", "secondary"].compactMap { key -> HubLimit.Window? in
            guard let window = limits[key] as? [String: Any],
                  let used = number(window["used_percent"] ?? window["usedPercent"]) else { return nil }
            let minutes = number(window["window_minutes"] ?? window["windowDurationMins"] ?? window["windowMinutes"])
            var reset = date(window["resets_at"] ?? window["resetsAt"])
            if reset == nil, let seconds = number(window["resets_in_seconds"] ?? window["resetsInSeconds"]) {
                reset = now.addingTimeInterval(seconds)
            }
            return HubLimit.Window(title: windowTitle(minutes: minutes ?? (key == "primary" ? 300 : 10_080)), percent: used, resetsAt: reset)
        }
        return windows.isEmpty ? nil : windows
    }

    // OpenRouter `GET /api/v1/key`: data.limit, limit_remaining, usage, usage_monthly (dollars).
    static func openRouter(_ data: Data) -> [HubLimit.Window]? {
        guard let body = object(data)?["data"] as? [String: Any] else { return nil }
        var windows: [HubLimit.Window] = []
        if let limit = number(body["limit"]), limit > 0 {
            let remaining = number(body["limit_remaining"]) ?? limit
            windows.append(.init(title: String(localized: "кредиты"), percent: (limit - remaining) / limit * 100,
                                 detail: String(localized: "осталось \(money(remaining)) из \(money(limit))")))
        }
        if let month = number(body["usage_monthly"]) {
            windows.append(.init(title: String(localized: "за месяц"), detail: money(month)))
        } else if let usage = number(body["usage"]) {
            windows.append(.init(title: String(localized: "всего"), detail: money(usage)))
        }
        return windows.isEmpty ? nil : windows
    }

    // Copilot `gh api /copilot_internal/user`: quota_snapshots.premium_interactions — entitlement, remaining, unlimited;
    // quota_reset_date.
    static func copilot(_ data: Data) -> [HubLimit.Window]? {
        guard let body = object(data), let snapshots = body["quota_snapshots"] as? [String: Any] else { return nil }
        let reset = date(body["quota_reset_date_utc"] ?? body["quota_reset_date"])
        let names: [(String, String)] = [("premium_interactions", String(localized: "премиум-запросы")), ("chat", String(localized: "чат")), ("completions", String(localized: "дополнения"))]
        let windows = names.compactMap { key, title -> HubLimit.Window? in
            guard let snapshot = snapshots[key] as? [String: Any], snapshot["unlimited"] as? Bool != true,
                  let entitlement = number(snapshot["entitlement"]), entitlement > 0 else { return nil }
            let remaining = number(snapshot["remaining"]) ?? entitlement
            return .init(title: title, percent: (entitlement - remaining) / entitlement * 100,
                         detail: String(localized: "осталось \(Int(remaining)) из \(Int(entitlement))"), resetsAt: reset)
        }
        return windows.isEmpty ? nil : windows
    }

    // Gemini Code Assist `retrieveUserQuota`: buckets[] — remainingFraction, resetTime, modelId.
    static func geminiQuota(_ data: Data) -> [HubLimit.Window]? {
        guard let buckets = object(data)?["buckets"] as? [[String: Any]] else { return nil }
        let windows = buckets.compactMap { bucket -> HubLimit.Window? in
            guard let fraction = number(bucket["remainingFraction"]) else { return nil }
            let model = (bucket["modelId"] as? String).map { $0.replacingOccurrences(of: "gemini-", with: "") } ?? String(localized: "квота")
            return .init(title: model, percent: (1 - fraction) * 100, resetsAt: date(bucket["resetTime"]))
        }
        return windows.isEmpty ? nil : Array(windows.prefix(3))
    }

    /// Without the quota call: today's requests from the CLI's session files against the plan's daily limit.
    static func geminiRequests(today count: Int, dailyLimit: Int, now: Date = .now) -> HubLimit.Window {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let reset = pacific.date(byAdding: .day, value: 1, to: pacific.startOfDay(for: now))
        return .init(title: String(localized: "запросы за день"), percent: Double(count) / Double(max(dailyLimit, 1)) * 100,
                     detail: String(localized: "\(count) из \(dailyLimit)"), resetsAt: reset)
    }

    /// User turns in a session file written today (Pacific day): «type» or «role» == "user".
    static func geminiUserTurns(_ data: Data, since start: Date) -> Int {
        guard let object = object(data), let messages = object["messages"] as? [[String: Any]] else { return 0 }
        return messages.filter { message in
            let isUser = (message["type"] as? String ?? message["role"] as? String) == "user"
            let time = date(message["timestamp"]) ?? .distantFuture
            return isUser && time >= start
        }.count
    }

    // OpenAI `GET /v1/organization/costs`: data[].results[].amount.value (dollars).
    static func openAICosts(_ data: Data) -> [HubLimit.Window]? {
        guard let buckets = object(data)?["data"] as? [[String: Any]] else { return nil }
        let total = buckets.flatMap { $0["results"] as? [[String: Any]] ?? [] }
            .compactMap { number(($0["amount"] as? [String: Any])?["value"]) }.reduce(0, +)
        return [.init(title: String(localized: "за месяц"), detail: money(total))]
    }

    // Anthropic Admin API cost report: data[].results[].amount — a decimal string in cents.
    static func anthropicCosts(_ data: Data) -> [HubLimit.Window]? {
        guard let buckets = object(data)?["data"] as? [[String: Any]] else { return nil }
        let cents = buckets.flatMap { $0["results"] as? [[String: Any]] ?? [] }.compactMap { number($0["amount"]) }.reduce(0, +)
        return [.init(title: String(localized: "за месяц"), detail: money(cents / 100))]
    }

    // Cursor `GetCurrentPeriodUsage`: planUsage.totalSpend / limit (cents), totalPercentUsed; billingCycleEnd.
    static func cursor(_ data: Data) -> [HubLimit.Window]? {
        guard let body = object(data), let plan = body["planUsage"] as? [String: Any] else { return nil }
        let spend = number(plan["totalSpend"]) ?? 0
        let limit = number(plan["limit"])
        let percent = number(plan["totalPercentUsed"]) ?? limit.map { $0 > 0 ? spend / $0 * 100 : 0 }
        let detail = limit.map { String(localized: "\(money(spend / 100)) из \(money($0 / 100))") } ?? money(spend / 100)
        return [.init(title: String(localized: "тариф"), percent: percent, detail: detail, resetsAt: date(body["billingCycleEnd"]))]
    }
}

/// «Хватит до сброса»: the pace from the first reading of a window to the latest one.
enum HubForecast {
    struct Reading: Equatable, Sendable {
        var at: Date
        var percent: Double
    }

    /// When the limit runs out at this pace, if that comes before the reset; nil when it lasts, or there's too little
    /// to tell (under 15 minutes or no growth).
    static func runsOut(first: Reading, latest: Reading, resetsAt: Date?) -> Date? {
        let elapsed = latest.at.timeIntervalSince(first.at)
        let grown = latest.percent - first.percent
        guard elapsed >= 15 * 60, grown > 0, latest.percent < 100 else { return nil }
        let date = latest.at.addingTimeInterval((100 - latest.percent) / grown * elapsed)
        guard let resetsAt else { return date }
        return date < resetsAt ? date : nil
    }
}

// MARK: - Reading each service

enum HubFetch {
    static func get(_ url: URL, headers: [String: String]) async -> Result<Data, HubError> {
        await request(url, method: "GET", body: nil, headers: headers)
    }

    static func post(_ url: URL, body: [String: Any], headers: [String: String]) async -> Result<Data, HubError> {
        await request(url, method: "POST", body: try? JSONSerialization.data(withJSONObject: body), headers: headers)
    }

    private static func request(_ url: URL, method: String, body: Data?, headers: [String: String]) async -> Result<Data, HubError> {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("AIHubBar", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code) ? .success(data) : .failure(.http(code))
        } catch {
            return .failure(.network)
        }
    }

    /// `codex app-server` over stdio: initialize, then `account/rateLimits/read`. The CLI keeps its own sign-in.
    static func codexRPC(path: String) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["app-server"]
                process.environment = ProcessRunner.environment()
                let input = Pipe(), output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continuation.resume(returning: nil); return }
                // Ending the process closes its output, which ends the read loop below if codex never answers.
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
                func send(_ object: [String: Any]) {
                    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
                    data.append(0x0A)
                    try? input.fileHandleForWriting.write(contentsOf: data)
                }
                send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "AIHubBar", "version": "1"]]])
                usleep(500_000)
                send(["jsonrpc": "2.0", "method": "initialized"])
                send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [String: Any]()])
                var buffer = Data()
                var answer: Data?
                while answer == nil {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    for line in buffer.split(separator: 0x0A) {
                        if let object = HubParse.object(Data(line)), (object["id"] as? NSNumber)?.intValue == 2 { answer = Data(line) }
                    }
                }
                process.terminate()
                continuation.resume(returning: answer)
            }
        }
    }

    /// The newest Codex session log's last rate-limit line.
    static func codexSessions(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [HubLimit.Window]? {
        let root = home.appending(path: ".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
            .max { (modified($0) ?? .distantPast) < (modified($1) ?? .distantPast) }
        guard let newest, let data = try? Data(contentsOf: newest) else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            if let windows = HubParse.codexSessionLine(Data(line)) { return windows }
        }
        return nil
    }

    static func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }

    static func tool(_ name: String) -> String? {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Gemini CLI session files of today's Pacific day: their user turns.
    static func geminiTodayRequests(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now) -> Int {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = pacific.startOfDay(for: now)
        guard let enumerator = FileManager.default.enumerator(at: home.appending(path: ".gemini/tmp"), includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("session") && (modified($0) ?? .distantPast) >= start }
            .reduce(0) { total, url in total + ((try? Data(contentsOf: url)).map { HubParse.geminiUserTurns($0, since: start) } ?? 0) }
    }

    /// Cursor's own access token from its settings database (read-only), only with the person's consent.
    static func cursorToken(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> String? {
        let db = home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        for table in ["ItemTable", "cursorDiskKV"] {
            let sql = "select value from \(table) where key = 'cursorAuth/accessToken' limit 1;"
            if let result = try? await ProcessRunner.run("/usr/bin/sqlite3", ["-readonly", db, sql], timeout: .seconds(10)),
               result.exitCode == 0 {
                let token = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !token.isEmpty { return token }
            }
        }
        return nil
    }

    /// Gemini CLI's own OAuth token, only while it is still valid (no refreshing someone else's sign-in).
    static func geminiAccessToken(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let data = try? Data(contentsOf: home.appending(path: ".gemini/oauth_creds.json")),
              let object = HubParse.object(data), let token = object["access_token"] as? String else { return nil }
        if let expiry = HubParse.number(object["expiry_date"]), Date(timeIntervalSince1970: expiry / 1000) < .now { return nil }
        return token
    }
}

enum HubError: Error, Equatable {
    case http(Int), network, unreadable, missing, failed(String)

    var text: String {
        switch self {
        case let .http(code) where code == 401 || code == 403: String(localized: "ключ или вход не подходят (HTTP \(code))")
        case let .http(code): String(localized: "сервис ответил HTTP \(code)")
        case .network: String(localized: "нет связи")
        case .unreadable: String(localized: "не удалось разобрать ответ — формат мог измениться")
        case .missing: String(localized: "нет данных")
        case let .failed(message): message
        }
    }
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
    /// The first reading of each window since its last reset, for the forecast.
    private var firstReadings: [String: HubForecast.Reading] = [:]

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
            if let path = AgentKind.codex.detect(), let data = await HubFetch.codexRPC(path: path), let windows = HubParse.codexRPC(data) {
                return done(windows)
            }
            return done(HubFetch.codexSessions(), .missing)
        case .openRouter:
            guard let key = await APIKeyStore.read(account: "hub-openrouter") else { return done(nil, .missing) }
            return fromHTTP(await HubFetch.get(URL(string: "https://openrouter.ai/api/v1/key")!, headers: ["Authorization": "Bearer \(key)"]), HubParse.openRouter)
        case .copilot:
            guard let gh = HubFetch.tool("gh"),
                  let result = try? await ProcessRunner.run(gh, ["api", "/copilot_internal/user"], timeout: .seconds(20)) else { return done(nil, .missing) }
            guard result.exitCode == 0 else {
                return done(nil, .failed(result.stderrText.split(separator: "\n").first.map(String.init) ?? "gh"))
            }
            return done(HubParse.copilot(result.stdout))
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

    private func forecast(_ limits: [HubLimit], now: Date = .now) -> [HubLimit] {
        limits.map { limit in
            var limit = limit
            for index in limit.windows.indices {
                let window = limit.windows[index]
                guard let percent = window.percent else { continue }
                let key = "\(limit.source.rawValue)|\(window.title)|\(window.resetsAt.map { Int($0.timeIntervalSince1970 / 600) } ?? 0)"
                let latest = HubForecast.Reading(at: now, percent: percent)
                // A drop means a reset the window's date didn't show: start over.
                if let first = firstReadings[key], first.percent <= percent {
                    limit.windows[index].runsOutAt = HubForecast.runsOut(first: first, latest: latest, resetsAt: window.resetsAt)
                } else {
                    firstReadings[key] = latest
                }
            }
            return limit
        }
    }

    /// `other-ai.json` for the «Лимиты» widget: the sandboxed widget only reads Application Support/ClaudePult.
    private func writeWidgetFile() {
        struct Entry: Encodable { var name: String; var percent: Double }
        let entries = limits.compactMap { limit in limit.fullest.map { Entry(name: limit.source.shortTitle, percent: $0) } }
        try? FileManager.default.createDirectory(at: Self.widgetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: Self.widgetURL, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudePultUsage")
    }

    /// The same thresholds as the Claude limits, once per window and reset.
    private func announce(_ limits: [HubLimit]) {
        let thresholds = settings.limitThresholds.sorted()
        for limit in limits {
            for window in limit.windows {
                guard let percent = window.percent, let threshold = thresholds.last(where: { Double($0) <= percent }) else { continue }
                let key = "\(limit.source.rawValue)|\(window.title)|\(window.resetsAt.map { Int($0.timeIntervalSince1970 / 600) } ?? 0)|\(threshold)"
                guard !notified.contains(key) else { continue }
                notified.insert(key)
                let title = String(localized: "\(limit.source.title): использовано \(Int(percent.rounded())) %")
                let body = [window.title, window.detail, window.resetsAt.map { String(localized: "сброс \($0.formatted(date: .abbreviated, time: .shortened))") }]
                    .compactMap { $0 }.joined(separator: " · ")
                Notifier.post(id: "hub-\(key)", title: title, body: body)
                if settings.limitAlertsToTelegram, let credentials = Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) {
                    let html = "⚠️ <b>\(RunMessage.escape(title))</b>\n\(RunMessage.escape(body))"
                    Task { _ = await Telegram.send(html: html, with: credentials) }
                }
            }
        }
    }
}
