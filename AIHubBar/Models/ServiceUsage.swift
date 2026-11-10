import Foundation

/// One limit of a service as the panel draws it (SPEC-ai-services §3): Claude's windows and the other services'
/// (`HubLimit.Window`) both become this.
struct LimitWindow: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    /// 0…100 when the service says how much of a limit is used; nil for plain spend (then `detail` says it).
    var percent: Double?
    var detail: String?
    var resetsAt: Date?
    /// At the current pace the limit runs out before the reset at this time.
    var runsOutAt: Date?
    /// False when the reset is already said elsewhere (a model week that resets with the week).
    var showsReset = true
    /// How long the window lasts, when it is known (Claude's week): then the panel can say how the spend compares
    /// with an even one.
    var length: TimeInterval?

    /// The percent an even spend would have reached by now.
    func evenSpend(now: Date = .now) -> Double? {
        guard let length, let resetsAt else { return nil }
        return EvenSpend.expected(resetsAt: resetsAt, length: length, now: now)
    }
}

/// «Ahead or behind an even spend» for a limit that lasts days: people asked trackers like this one for exactly it
/// (2026-11-10) — at 40 % on Wednesday morning, is that a lot?
enum EvenSpend {
    static let week: TimeInterval = 7 * 24 * 3600
    /// The first hours of a window say nothing: one long session is far above an even spend.
    static let quietStart: TimeInterval = 12 * 3600
    /// Differences smaller than this are «on track» and not worth a line.
    static let worthSaying = 5.0

    /// 0…100: how much of the window has passed. Nil outside the window or at its very start.
    static func expected(resetsAt: Date, length: TimeInterval, now: Date) -> Double? {
        let elapsed = length - resetsAt.timeIntervalSince(now)
        guard length > 0, elapsed >= quietStart, elapsed <= length else { return nil }
        return elapsed / length * 100
    }

    /// Whole percent points above (+) or below (−) an even spend; nil when the difference is not worth a line.
    static func difference(percent: Double, expected: Double?) -> Int? {
        guard let expected else { return nil }
        let delta = percent - expected
        return abs(delta) >= worthSaying ? Int(delta.rounded()) : nil
    }
}

/// A line under a service's limits: credits, plan, how full the context is.
struct ServiceNote: Equatable, Hashable, Sendable {
    var text: String
    var symbol: String
}

/// Tokens a service spent in one project folder.
struct ProjectTokens: Equatable, Identifiable, Sendable {
    var path: String
    var name: String
    var tokens: Int
    var id: String { path }
}

/// Everything the panel shows about one AI service's limits, the same for every service (SPEC-ai-services §3, stage 2):
/// up to two windows as rings, the forecast, the week by day, the other windows as bars, notes (credits, spend) and
/// the error. Claude builds it from `UsageSnapshot`, the other services from `HubLimit` and `LimitHistory`.
struct ServiceUsage: Equatable, Identifiable, Sendable {
    enum Service: Hashable, Sendable {
        case claude
        case claudeAccount(String)
        case hub(HubLimit.Source)
    }

    var service: Service
    var title: String
    var rings: [LimitWindow]
    var bars: [LimitWindow]
    var forecast: UsageForecast
    /// Percent of the first limit used per hour, when known (Claude's session).
    var pace: Double? = nil
    var week: WeekUsage?
    var notes: [ServiceNote] = []
    /// Tokens per project this week, for services that keep them (Codex; Claude has its own breakdown).
    var projects: [ProjectTokens] = []
    var error: String?
    /// The figures could not be refreshed: shown dimmed, not passed off as current.
    var isStale = false

    var id: Service { service }

    static func claude(_ snapshot: UsageSnapshot, forecast: UsageForecast, pace: Double? = nil, week: WeekUsage?, error: String?) -> ServiceUsage {
        func window(_ window: UsageWindow, showsReset: Bool = true) -> LimitWindow {
            LimitWindow(id: window.key, title: window.title, percent: window.utilization, resetsAt: window.resetsAt, showsReset: showsReset,
                        length: window.key.hasPrefix("seven_day") ? EvenSpend.week : nil)
        }
        var notes: [ServiceNote] = []
        if let extra = snapshot.extra, extra.isEnabled { notes.append(ServiceNote(text: UsageText.extra(extra), symbol: "creditcard")) }
        return ServiceUsage(
            service: .claude,
            title: "Claude",
            rings: [snapshot.session, snapshot.week].compactMap { $0.map { window($0) } },
            // A model week usually resets with the week: no need to say it twice.
            bars: snapshot.shownOtherWindows.map { window($0, showsReset: !UsageWindow.sameReset($0.resetsAt, snapshot.week?.resetsAt)) },
            forecast: forecast,
            pace: pace,
            week: week,
            notes: notes,
            error: error,
            isStale: error != nil
        )
    }

    /// The first two limits with a percentage are rings (Codex: 5 h and week, Copilot: the month); spend and the rest
    /// are bars. The forecast is the first ring's pace; the week strip follows the ring that resets last.
    static func hub(_ limit: HubLimit, history: LimitHistory, now: Date = .now) -> ServiceUsage {
        let windows = limit.windows.enumerated().map { index, window in
            let key = LimitHistory.key(limit.source, window.title)
            return LimitWindow(
                id: "\(index)|\(window.title)", title: window.title, percent: window.percent, detail: window.detail,
                resetsAt: window.resetsAt,
                runsOutAt: window.percent == nil ? nil : history.runsOut(key, resetsAt: window.resetsAt, now: now)
            )
        }
        let rings = Array(windows.filter { $0.percent != nil }.prefix(2))
        let bars = windows.filter { window in !rings.contains { $0.id == window.id } }
        let forecast = rings.first.map { history.forecast(LimitHistory.key(limit.source, $0.title), resetsAt: $0.resetsAt, now: now) } ?? .unknown
        let longest = rings.max { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }
        var week = longest.flatMap { ring in
            history.week(LimitHistory.key(limit.source, ring.title), resetsAt: ring.resetsAt, now: now)
        }
        // With one ring its pace is already the forecast line; the strip's own line is for the longer window.
        if longest?.id == rings.first?.id { week?.forecast = .unknown }
        return ServiceUsage(
            service: .hub(limit.source), title: limit.source.title, rings: rings, bars: bars,
            forecast: forecast, week: week, notes: limit.notes, projects: limit.projects, error: limit.error
        )
    }
}

/// Readings of every service's limits over the last 8 days (`limit-history.json`), so the other services get the
/// forecast and the week by day that Claude has. Claude's own history stays in `UsageStore` (its week comes from
/// the journals, which is finer than readings).
struct LimitHistory: Codable, Equatable, Sendable {
    struct Reading: Codable, Equatable, Sendable {
        var at: Date
        var percent: Double
        var resetsAt: Date?
    }

    private(set) var readings: [String: [Reading]] = [:]

    static let keep: TimeInterval = 8 * 86_400

    static func key(_ source: HubLimit.Source, _ title: String) -> String { "\(source.rawValue)|\(title)" }

    /// Adds a reading; an unchanged value is stored again only every 30 minutes, and old readings are dropped.
    mutating func record(_ key: String, percent: Double, resetsAt: Date?, at now: Date) {
        var list = readings[key] ?? []
        if let last = list.last, last.percent == percent, UsageWindow.sameReset(last.resetsAt, resetsAt),
           now.timeIntervalSince(last.at) < 30 * 60 {
            return
        }
        list.append(Reading(at: now, percent: percent, resetsAt: resetsAt))
        list.removeAll { now.timeIntervalSince($0.at) > Self.keep }
        readings[key] = list
    }

    /// Readings since the window's last reset: same reset time and no drop (a drop is a reset the date didn't show).
    func currentPeriod(_ key: String, resetsAt: Date?) -> [Reading] {
        var period: [Reading] = []
        for reading in readings[key] ?? [] {
            if !UsageWindow.sameReset(reading.resetsAt, resetsAt) { period = []; continue }
            if let last = period.last, reading.percent < last.percent { period = [] }
            period.append(reading)
        }
        return period
    }

    /// When the limit runs out at the pace since the start of the current period, if before the reset.
    func runsOut(_ key: String, resetsAt: Date?, now: Date = .now) -> Date? {
        if case let .runsOutAt(date) = forecast(key, resetsAt: resetsAt, now: now) { return date }
        return nil
    }

    func forecast(_ key: String, resetsAt: Date?, now: Date = .now) -> UsageForecast {
        let period = currentPeriod(key, resetsAt: resetsAt)
        guard let first = period.first, let latest = period.last, latest.at.timeIntervalSince(first.at) >= 15 * 60 else { return .unknown }
        if let date = HubForecast.runsOut(first: .init(at: first.at, percent: first.percent), latest: .init(at: latest.at, percent: latest.percent), resetsAt: resetsAt) {
            return .runsOutAt(date)
        }
        return latest.percent >= 100 ? .unknown : .lastsUntilReset
    }

    /// The last seven days: how many percent of the limit each day took (growth within the day; after a reset the
    /// new value counts from zero). Nil until the readings cover 12 hours.
    func week(_ key: String, resetsAt: Date?, now: Date = .now, calendar: Calendar = .current) -> WeekUsage? {
        let list = readings[key] ?? []
        guard let first = list.first, now.timeIntervalSince(first.at) >= 12 * 3600 else { return nil }
        let today = calendar.startOfDay(for: now)
        var days: [WeekUsage.Day] = (0..<7).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { WeekUsage.Day(date: $0, percent: 0, isToday: back == 0) }
        }
        for (previous, reading) in zip(list, list.dropFirst()) {
            let grown = reading.percent >= previous.percent && UsageWindow.sameReset(previous.resetsAt, reading.resetsAt)
                ? reading.percent - previous.percent : reading.percent
            guard grown > 0, let index = days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: reading.at) }) else { continue }
            days[index].percent += grown
        }
        let pace: WeekUsage.Forecast = switch forecast(key, resetsAt: resetsAt, now: now) {
        case let .runsOutAt(date): .runsOutAt(date)
        case .lastsUntilReset: .lastsUntilReset
        case .unknown: .unknown
        }
        return WeekUsage(days: days, forecast: pace)
    }

    static var url: URL { SessionFiles.supportDirectory.appending(path: "limit-history.json") }

    static func load(from url: URL = url) -> LimitHistory {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(LimitHistory.self, from: $0) } ?? LimitHistory()
    }

    func save(to url: URL = Self.url) {
        AppLog.attempt("Limit history not saved") {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }
    }
}
