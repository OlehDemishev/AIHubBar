import Foundation

/// One limit window: how much is used (percent) and when it resets.
struct UsageWindow: Codable, Equatable, Sendable {
    var key: String
    var title: String
    var utilization: Double
    var resetsAt: Date?

    static func title(forKey key: String) -> String {
        switch key {
        case "five_hour": String(localized: "Сессия (5 ч)")
        case "seven_day": String(localized: "Неделя")
        case "seven_day_opus": String(localized: "Неделя · Opus")
        case "seven_day_sonnet": String(localized: "Неделя · Sonnet")
        default:
            String(localized: "Неделя · ") + key.replacingOccurrences(of: "seven_day_", with: "")
                .split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
    }
}

/// Extra usage (pay-as-you-go beyond the plan).
struct ExtraUsage: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var usedCredits: Double?
    var monthlyLimit: Double?
    var currency: String?
    var decimalPlaces: Int
}

/// A decoded `/api/oauth/usage` response. The endpoint is undocumented (checked live on 2026-10-29): it has
/// `five_hour`, `seven_day`, optional `seven_day_<model>` windows (`{"utilization", "resets_at"}`), a `limits`
/// list with per-model weekly limits (`kind: weekly_scoped`) and many code-named objects that are ignored —
/// one of them looked like a window at 100 % but is not a plan limit.
struct UsageSnapshot: Codable, Equatable, Sendable {
    var fetchedAt: Date
    var windows: [UsageWindow]
    var extra: ExtraUsage?

    var session: UsageWindow? { windows.first { $0.key == "five_hour" } }
    var week: UsageWindow? { windows.first { $0.key == "seven_day" } }
    var otherWindows: [UsageWindow] { windows.filter { $0.key != "five_hour" && $0.key != "seven_day" } }

    static func decode(_ data: Data, fetchedAt: Date) -> UsageSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var windows: [UsageWindow] = []

        func window(_ key: String, title: String, _ value: Any?) {
            guard let raw = value as? [String: Any], let utilization = number(raw["utilization"] ?? raw["percent"]) else { return }
            windows.append(UsageWindow(
                key: key, title: title, utilization: utilization,
                resetsAt: (raw["resets_at"] as? String).flatMap(ISODate.parse)
            ))
        }

        window("five_hour", title: UsageWindow.title(forKey: "five_hour"), object["five_hour"])
        window("seven_day", title: UsageWindow.title(forKey: "seven_day"), object["seven_day"])
        for key in object.keys.sorted() where key.hasPrefix("seven_day_") && key != "seven_day_breakdown" {
            window(key, title: UsageWindow.title(forKey: key), object[key])
        }
        // Per-model weekly limits from the `limits` list, unless already present as `seven_day_<model>`.
        for limit in object["limits"] as? [[String: Any]] ?? [] where limit["kind"] as? String == "weekly_scoped" {
            let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            guard let model, !model.isEmpty else { continue }
            let key = "seven_day_" + model.lowercased().replacingOccurrences(of: " ", with: "_")
            guard !windows.contains(where: { $0.key == key }) else { continue }
            window(key, title: String(localized: "Неделя · \(model)"), limit)
        }

        guard windows.contains(where: { $0.key == "five_hour" }) else { return nil }

        var extra: ExtraUsage?
        if let raw = object["extra_usage"] as? [String: Any] {
            extra = ExtraUsage(
                isEnabled: raw["is_enabled"] as? Bool ?? false,
                usedCredits: number(raw["used_credits"]),
                monthlyLimit: number(raw["monthly_limit"]),
                currency: raw["currency"] as? String,
                decimalPlaces: (raw["decimal_places"] as? Int) ?? 2
            )
        }
        return UsageSnapshot(fetchedAt: fetchedAt, windows: windows, extra: extra)
    }

    private static func number(_ value: Any?) -> Double? {
        if value is NSNull { return nil }
        return (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }
}

enum UsageLevel: Equatable, Sendable {
    case low, medium, high

    /// Green < 50 %, orange 50–80 %, red > 80 % (spec §2.8).
    init(_ percent: Double) {
        self = percent > 80 ? .high : percent >= 50 ? .medium : .low
    }
}

/// A point of the session/week history used for the forecast.
struct UsagePoint: Codable, Equatable, Sendable {
    var date: Date
    var session: Double
    var sessionResetsAt: Date?
}

enum UsageForecast: Equatable, Sendable {
    /// At the current pace the session limit is reached at this time, before the reset.
    case runsOutAt(Date)
    /// At the current pace the session lasts until the reset.
    case lastsUntilReset
    /// Not enough data, or usage is not growing.
    case unknown

    /// Pace over the last `window` seconds of the current session window (same `resets_at`).
    static func make(history: [UsagePoint], current: UsageWindow?, now: Date = .now, window: TimeInterval = 30 * 60) -> UsageForecast {
        guard let current, let resets = current.resetsAt else { return .unknown }
        let points = history.filter { $0.sessionResetsAt.map { abs($0.timeIntervalSince(resets)) < 60 } ?? false && now.timeIntervalSince($0.date) <= window }
        guard let first = points.min(by: { $0.date < $1.date }) else { return .unknown }
        let elapsed = now.timeIntervalSince(first.date)
        let grown = current.utilization - first.session
        guard elapsed >= 5 * 60, grown > 0 else { return grown <= 0 && elapsed >= 5 * 60 ? .lastsUntilReset : .unknown }
        let perSecond = grown / elapsed
        let runsOut = now.addingTimeInterval((100 - current.utilization) / perSecond)
        return runsOut < resets ? .runsOutAt(runsOut) : .lastsUntilReset
    }
}

/// Threshold notifications «once per window» and «limit restored» (spec §2.8).
enum UsageAlerts {
    enum Alert: Equatable, Sendable {
        case crossed(windowKey: String, title: String, threshold: Int, utilization: Double, resetsAt: Date?)
        case restored(windowKey: String, title: String)
    }

    /// Returns alerts for the new snapshot and updates `notified` (keys `<window>|<resets_at>|<threshold>`).
    /// Only the highest newly crossed threshold of a window alerts, so starting at 85 % gives one alert, not two.
    static func evaluate(
        previous: UsageSnapshot?, current: UsageSnapshot, thresholds: [Int], notified: inout Set<String>
    ) -> [Alert] {
        var alerts: [Alert] = []
        for window in current.windows where window.key == "five_hour" || window.key == "seven_day" {
            let period = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "none"
            let crossed = thresholds.filter { Double($0) <= window.utilization }.sorted()
            let fresh = crossed.filter { !notified.contains("\(window.key)|\(period)|\($0)") }
            if let highest = fresh.last {
                alerts.append(.crossed(windowKey: window.key, title: window.title, threshold: highest, utilization: window.utilization, resetsAt: window.resetsAt))
            }
            for threshold in crossed { notified.insert("\(window.key)|\(period)|\(threshold)") }

            if let before = previous?.windows.first(where: { $0.key == window.key }), before.utilization > 80,
               window.utilization < before.utilization - 30 || (before.resetsAt != nil && window.resetsAt != before.resetsAt && window.utilization < 50) {
                alerts.append(.restored(windowKey: window.key, title: window.title))
            }
        }
        return alerts
    }
}

/// `usage.json` for report.py / the bot (spec §2.8): current values, readable without the app.
enum UsageFile {
    static var url: URL { SessionFiles.supportDirectory.appending(path: "usage.json") }

    static func payload(_ snapshot: UsageSnapshot) -> [String: Any] {
        func window(_ w: UsageWindow?) -> Any {
            guard let w else { return NSNull() }
            return ["utilization": w.utilization, "resets_at": w.resetsAt.map { $0.ISO8601Format() } ?? NSNull()] as [String: Any]
        }
        return [
            "five_hour": window(snapshot.session),
            "seven_day": window(snapshot.week),
            "updated": snapshot.fetchedAt.ISO8601Format(),
        ]
    }

    static func write(_ snapshot: UsageSnapshot) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload(snapshot), options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Human texts for the limits block.
enum UsageText {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded())) %" }

    /// «через 2 ч 14 мин», «через 35 мин», «меньше минуты».
    static func countdown(to date: Date, now: Date = .now) -> String {
        let minutes = Int(max(0, date.timeIntervalSince(now)) / 60)
        if minutes < 1 { return String(localized: "меньше чем через минуту") }
        if minutes < 60 { return String(localized: "через \(minutes) мин") }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return rest == 0 ? String(localized: "через \(hours) ч") : String(localized: "через \(hours) ч \(rest) мин") }
        return String(localized: "через \(hours / 24) дн \(hours % 24) ч")
    }

    static func resetText(_ window: UsageWindow, now: Date = .now) -> String? {
        guard let resets = window.resetsAt else { return nil }
        if resets.timeIntervalSince(now) < 24 * 3600 { return String(localized: "сброс \(countdown(to: resets, now: now))") }
        return String(localized: "сброс \(resets.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
    }

    static func forecast(_ forecast: UsageForecast) -> String? {
        switch forecast {
        case let .runsOutAt(date): String(localized: "при текущем темпе хватит до ~\(date.formatted(date: .omitted, time: .shortened))")
        case .lastsUntilReset: String(localized: "до сброса хватит")
        case .unknown: nil
        }
    }

    static func money(_ amount: Double, decimals: Int, currency: String?) -> String {
        let value = amount / pow(10, Double(decimals))
        return value.formatted(.currency(code: currency ?? "USD"))
    }
}
