import Foundation

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
        // Only a seven-day window is «неделя»: Codex's free plan has a 30-day one (it was called a week).
        return abs(minutes - 7 * 24 * 60) <= 60 ? String(localized: "неделя") : String(localized: "\(Int((minutes / 1440).rounded())) дн")
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
