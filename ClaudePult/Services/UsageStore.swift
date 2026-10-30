import Foundation
import Observation
import WidgetKit

/// Subscription limits: fetching on a smart schedule, forecast, threshold notifications, `usage.json` (spec §2.8).
@MainActor
@Observable
final class UsageStore {
    private(set) var snapshot: UsageSnapshot?
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var history: [UsagePoint] = []
    /// While set, no request is made: the server answered 429 (or kept failing).
    private(set) var pausedUntil: Date?
    private var rateLimitStrikes = 0

    var forecast: UsageForecast { UsageForecast.make(history: history, current: snapshot?.session) }

    /// Periods of the per-project breakdown.
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case session, today, week
        var id: String { rawValue }
        var title: String {
            switch self {
            case .session: "Сессия"
            case .today: "Сегодня"
            case .week: "Неделя"
            }
        }
    }

    private(set) var breakdowns: [Period: TokenBreakdown] = [:]
    private(set) var breakdownUpdated: Date?
    private let scanner = TokenScanner()
    private var isScanning = false

    /// Refresh every 2 minutes while Claude is working or the session percentage grows, otherwise every 5 min;
    /// right after a reset as well. The spec said 1 minute; the endpoint answered 429 at that pace.
    static let activeInterval: TimeInterval = 120
    static let idleInterval: TimeInterval = 5 * 60

    private let settings: AppSettings
    private let sessions: SessionStore
    private var loop: Task<Void, Never>?
    private var notified: Set<String>
    private var lastGrowth: Date?

    private static let notifiedKey = "usageNotified"
    private static var historyURL: URL { SessionFiles.supportDirectory.appending(path: "usage-history.json") }
    private static var snapshotURL: URL { SessionFiles.supportDirectory.appending(path: "usage-snapshot.json") }

    /// Pause after a 429: 5, 10, 20, 40, then 60 minutes, or longer if `Retry-After` says so. A shorter
    /// `Retry-After` is not trusted — the server answered «Retry-After: 0» and went on refusing.
    static func backoff(strike: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exponential = 300 * pow(2, Double(max(strike, 1) - 1))
        return min(max(exponential, retryAfter ?? 0), 3600)
    }

    init(settings: AppSettings, sessions: SessionStore) {
        self.settings = settings
        self.sessions = sessions
        notified = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? [])
        history = Self.loadHistory()
        // The last values are shown right away after a restart, without a request.
        snapshot = Self.loadSnapshot()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // A restart right after a fetch does not ask again (restarts were part of the 429s).
            if let fetched = self?.snapshot?.fetchedAt, Date.now.timeIntervalSince(fetched) < Self.activeInterval {
                try? await Task.sleep(for: .seconds(Self.activeInterval - Date.now.timeIntervalSince(fetched)))
            }
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                if breakdownUpdated.map({ Date.now.timeIntervalSince($0) > 10 * 60 }) ?? true {
                    await refreshBreakdown()
                }
                try? await Task.sleep(for: .seconds(nextDelay()))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        if let pausedUntil, pausedUntil > .now { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await UsageService.fetch()
            apply(fresh)
            error = nil
            pausedUntil = nil
            rateLimitStrikes = 0
        } catch let UsageError.rateLimited(retryAfter) {
            rateLimitStrikes += 1
            let pause = Self.backoff(strike: rateLimitStrikes, retryAfter: retryAfter)
            let until = Date.now.addingTimeInterval(pause)
            pausedUntil = until
            error = "Сервер лимитов просит запрашивать реже — следующая попытка в \(until.formatted(date: .omitted, time: .shortened))"
            AppLog.error("Usage: HTTP 429, pause \(Int(pause / 60)) min (strike \(rateLimitStrikes), Retry-After \(retryAfter.map { "\(Int($0)) s" } ?? "none"))")
        } catch {
            // The same failure repeats every few minutes; log it once.
            if self.error != error.localizedDescription { AppLog.error("Usage refresh failed: \(error.localizedDescription)") }
            self.error = error.localizedDescription
        }
    }

    /// Start of each breakdown period: the current 5-hour window, today, the current week window.
    func periodStart(_ period: Period, now: Date = .now) -> Date {
        switch period {
        case .session:
            return snapshot?.session?.resetsAt.map { $0.addingTimeInterval(-5 * 3600) } ?? now.addingTimeInterval(-5 * 3600)
        case .today:
            return Calendar.current.startOfDay(for: now)
        case .week:
            return snapshot?.week?.resetsAt.map { $0.addingTimeInterval(-7 * 86_400) } ?? now.addingTimeInterval(-7 * 86_400)
        }
    }

    /// Re-reads new transcript lines (incrementally) and recomputes the three breakdowns.
    func refreshBreakdown() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let starts = Dictionary(uniqueKeysWithValues: Period.allCases.map { ($0, periodStart($0)) })
        let earliest = starts.values.min() ?? .now
        let projectsDirectory = settings.projectsDirectory
        let started = ContinuousClock.now
        let records = await scanner.scan(since: earliest)
        let result = await Task.detached(priority: .utility) {
            starts.mapValues { TokenBreakdown.make(records, since: $0, projectsDirectory: projectsDirectory) }
        }.value
        breakdowns = result
        breakdownUpdated = .now
        AppLog.info("Token breakdown: \(records.count) messages in \((ContinuousClock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
    }

    /// Seconds until the next fetch.
    func nextDelay(now: Date = .now) -> TimeInterval {
        let working = sessions.items.contains { $0.state == .running || $0.state == .waiting }
        let growing = lastGrowth.map { now.timeIntervalSince($0) < 10 * 60 } ?? false
        var delay = working || growing ? Self.activeInterval : Self.idleInterval
        if let pausedUntil, pausedUntil > now {
            return max(pausedUntil.timeIntervalSince(now) + 1, 15)
        }
        // Fetch again shortly after the session window resets.
        if let resets = snapshot?.session?.resetsAt, resets > now {
            delay = min(delay, resets.timeIntervalSince(now) + 5)
        }
        return max(delay, 15)
    }

    private func apply(_ fresh: UsageSnapshot) {
        let previous = snapshot
        if let before = previous?.session?.utilization, let now = fresh.session?.utilization, now > before {
            lastGrowth = .now
        }
        snapshot = fresh
        UsageFile.write(fresh)
        saveSnapshot(fresh)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudePultUsage")

        if let session = fresh.session {
            history.append(UsagePoint(date: fresh.fetchedAt, session: session.utilization, sessionResetsAt: session.resetsAt))
            history.removeAll { fresh.fetchedAt.timeIntervalSince($0.date) > 3 * 3600 }
            saveHistory()
        }

        let alerts = UsageAlerts.evaluate(previous: previous, current: fresh, thresholds: settings.limitThresholds, notified: &notified)
        // Forget keys of windows that have reset long ago.
        notified = notified.filter { key in
            guard let minutes = key.split(separator: "|").dropFirst().first.flatMap({ Double($0) }) else { return true }
            return Date(timeIntervalSince1970: minutes * 60) > .now.addingTimeInterval(-86_400)
        }
        UserDefaults.standard.set(Array(notified), forKey: Self.notifiedKey)
        alerts.forEach(announce)
    }

    private func announce(_ alert: UsageAlerts.Alert) {
        let (id, title, body): (String, String, String)
        switch alert {
        case let .crossed(key, name, threshold, utilization, resetsAt):
            id = "limit-\(key)-\(threshold)"
            title = "Лимит Claude: \(name.lowercased()) — \(UsageText.percent(utilization))"
            body = "Порог \(threshold) %" + (resetsAt.map { ", сброс \(UsageText.countdown(to: $0))" } ?? "")
        case let .restored(key, name):
            id = "limit-\(key)-restored"
            title = "Лимит Claude восстановлен"
            body = "\(name) снова доступна"
        }
        AppLog.info("Usage alert: \(title)")
        Notifier.post(id: id, title: title, body: body)
        guard settings.limitAlertsToTelegram,
              let credentials = Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) else { return }
        let html = "⚠️ <b>\(RunMessage.escape(title))</b>\n\(RunMessage.escape(body))"
        Task { _ = await Telegram.send(html: html, with: credentials) }
    }

    // MARK: - History file (survives restarts so the forecast is available right away)

    private static func loadHistory() -> [UsagePoint] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: historyURL),
              let points = try? decoder.decode([UsagePoint].self, from: data) else { return [] }
        return points.filter { Date.now.timeIntervalSince($0.date) < 3 * 3600 }
    }

    private static func loadSnapshot() -> UsageSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? decoder.decode(UsageSnapshot.self, from: data),
              Date.now.timeIntervalSince(snapshot.fetchedAt) < 24 * 3600 else { return nil }
        return snapshot
    }

    private func saveSnapshot(_ snapshot: UsageSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(snapshot).write(to: Self.snapshotURL, options: .atomic)
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(history).write(to: Self.historyURL, options: .atomic)
    }
}
