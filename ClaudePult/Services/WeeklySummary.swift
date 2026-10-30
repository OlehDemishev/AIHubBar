import Foundation
import Observation

/// When a Claude limit reached 100 %: kept 30 days for the weekly summary.
enum LimitHits {
    private static let key = "limitHits"

    static func record(_ window: String, at date: Date = .now, defaults: UserDefaults = .standard) {
        var hits = all(defaults: defaults).filter { date.timeIntervalSince($0.date) < 30 * 86_400 }
        hits.append((window, date))
        defaults.set(hits.map { "\($0.window)|\($0.date.timeIntervalSince1970)" }, forKey: key)
    }

    static func all(defaults: UserDefaults = .standard) -> [(window: String, date: Date)] {
        (defaults.stringArray(forKey: key) ?? []).compactMap { item in
            let parts = item.split(separator: "|")
            guard parts.count == 2, let seconds = Double(parts[1]) else { return nil }
            return (String(parts[0]), Date(timeIntervalSince1970: seconds))
        }
    }
}

/// «Неделя Claude» in Telegram (own message, not the daily report): the week's limit, spend by project, the heaviest
/// sessions, limit hits and background runs.
enum WeeklySummary {
    struct Input: Sendable {
        var weekPercent: Double?
        var weekResetsAt: Date?
        var breakdown: TokenBreakdown?
        var sessionHits: Int
        var weekHits: Int
        var runs: [BackgroundRun]
        var now: Date
    }

    static func html(_ input: Input) -> String {
        var lines = ["📊 <b>\(RunMessage.escape(String(localized: "Неделя Claude")))</b>"]
        if let percent = input.weekPercent {
            var line = String(localized: "Неделя: \(UsageText.percent(percent))")
            if let reset = input.weekResetsAt {
                line += String(localized: ", сброс \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
            }
            lines.append(RunMessage.escape(line))
        }
        if let breakdown = input.breakdown, !breakdown.projects.isEmpty {
            lines.append("")
            lines.append("<b>\(RunMessage.escape(String(localized: "По проектам")))</b>")
            for row in breakdown.projects.prefix(5) {
                lines.append(RunMessage.escape("• \(row.name) — \(Int((row.share * 100).rounded())) % (\(TokenBreakdown.tokensText(row.tokens)))"))
            }
            if breakdown.projects.count > 5 {
                lines.append(RunMessage.escape(String(localized: "и ещё \(breakdown.projects.count - 5)")))
            }
        }
        if let breakdown = input.breakdown, !breakdown.topSessions.isEmpty {
            lines.append("")
            lines.append("<b>\(RunMessage.escape(String(localized: "Самые тяжёлые сессии")))</b>")
            for session in breakdown.topSessions.prefix(3) {
                lines.append(RunMessage.escape("• \(session.project) — \(Int((session.share * 100).rounded())) % (\(TokenBreakdown.tokensText(session.tokens)))"))
            }
        }
        lines.append("")
        if input.sessionHits + input.weekHits == 0 {
            lines.append(RunMessage.escape(String(localized: "В лимит не упирался")))
        } else {
            lines.append(RunMessage.escape(String(localized: "Упирался в лимит: сессия — \(input.sessionHits), неделя — \(input.weekHits)")))
        }
        if !input.runs.isEmpty {
            let done = input.runs.filter { $0.state == .succeeded }.count
            lines.append(RunMessage.escape(String(localized: "Фоновые задачи: \(input.runs.count) — ✅ \(done), ❌ \(input.runs.count - done)")))
        }
        return lines.joined(separator: "\n")
    }

    /// This week's send time: the chosen weekday (1 = Sunday … 7 = Saturday, like `Calendar`) at the chosen hour.
    static func due(weekday: Int, hour: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        let shift = (weekday - calendar.component(.weekday, from: now) + 7) % 7
        let thisWeek = calendar.date(byAdding: .day, value: shift, to: today) ?? today
        return thisWeek > now ? calendar.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek : thisWeek
    }
}

/// Sends the summary once a week (checked every 10 minutes), only with the daily-report bot configured.
@MainActor
@Observable
final class WeeklySummarySender {
    private let settings: AppSettings
    private let usage: UsageStore
    private let runs: RunStore
    private var loop: Task<Void, Never>?
    private static let sentKey = "weeklySummarySent"

    init(settings: AppSettings, usage: UsageStore, runs: RunStore) {
        self.settings = settings
        self.usage = usage
        self.runs = runs
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.sendIfDue()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    private func sendIfDue(now: Date = .now) async {
        guard settings.weeklySummary else { return }
        let due = WeeklySummary.due(weekday: settings.weeklySummaryWeekday, hour: settings.weeklySummaryHour, now: now)
        let sent = UserDefaults.standard.double(forKey: Self.sentKey)
        // Sent this week already, or the app was off for days: no late summary of a week long gone.
        guard sent < due.timeIntervalSince1970, now.timeIntervalSince(due) < 86_400 else { return }
        if await send(now: now) { UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.sentKey) }
    }

    /// Also «Отправить сейчас» in Settings.
    @discardableResult
    func send(now: Date = .now) async -> Bool {
        guard let credentials = Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) else { return false }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let hits = LimitHits.all().filter { $0.date >= weekAgo }
        let input = WeeklySummary.Input(
            weekPercent: usage.snapshot?.week?.utilization, weekResetsAt: usage.snapshot?.week?.resetsAt,
            breakdown: usage.breakdowns[.week],
            sessionHits: hits.filter { $0.window == "five_hour" }.count, weekHits: hits.filter { $0.window == "seven_day" }.count,
            runs: runs.runs.filter { $0.startedAt >= weekAgo && $0.state.isFinished }, now: now
        )
        let ok = await Telegram.send(html: WeeklySummary.html(input), with: credentials)
        AppLog.info("Weekly summary sent: \(ok)")
        return ok
    }
}
