import Foundation
import Testing
@testable import ClaudePult

/// The common per-service model (SPEC-ai-services stage 2): Claude and the other services become the same
/// `ServiceUsage`, and `LimitHistory` gives the others a forecast and a week by day.
struct ServiceUsageTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func claudeFromStoredAnswer() throws {
        let answer = """
        {"five_hour":{"utilization":42,"resets_at":"2026-11-02T15:00:00Z"},
         "seven_day":{"utilization":18,"resets_at":"2026-11-09T09:00:00Z"},
         "seven_day_opus":{"utilization":7,"resets_at":"2026-11-09T09:00:00Z"},
         "seven_day_sonnet":{"utilization":0,"resets_at":"2026-11-09T09:00:00Z"},
         "extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}
        """
        let snapshot = try #require(UsageSnapshot.decode(Data(answer.utf8), fetchedAt: now))
        let usage = ServiceUsage.claude(snapshot, forecast: .lastsUntilReset, week: nil, error: nil)
        #expect(usage.service == .claude)
        #expect(usage.rings.map(\.id) == ["five_hour", "seven_day"])
        #expect(usage.rings.map(\.percent) == [42, 18])
        #expect(usage.bars.map(\.id) == ["seven_day_opus"], "an unused model week takes no room")
        #expect(usage.bars.first?.showsReset == false, "resets with the week")
        #expect(usage.notes.count == 1 && usage.notes[0].text.contains("Extra usage"))
        #expect(!usage.isStale)
        #expect(ServiceUsage.claude(snapshot, forecast: .unknown, week: nil, error: "HTTP 500").isStale)
    }

    @Test func codexBecomesTheSameCard() throws {
        let answer = """
        {"result":{"rateLimits":{"primary":{"usedPercent":42.5,"windowDurationMins":300,"resetsAt":1793010000},\
        "secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1793500000}}}}
        """
        var windows = try #require(HubParse.codexRPC(Data(answer.utf8)))
        windows.append(HubLimit.Window(title: "API", percent: nil, detail: "$3.20"))
        let usage = ServiceUsage.hub(HubLimit(source: .codex, windows: windows), history: LimitHistory(), now: now)
        #expect(usage.service == .hub(.codex) && usage.title == "Codex")
        #expect(usage.rings.map(\.percent) == [42.5, 12])
        #expect(usage.bars.map(\.detail) == ["$3.20"], "spend is a bar, not a ring")
        #expect(usage.forecast == .unknown && usage.week == nil, "no readings yet")
    }

    @Test func errorWithoutFigures() {
        let usage = ServiceUsage.hub(HubLimit(source: .cursor, windows: [], error: "нет входа"), history: LimitHistory(), now: now)
        #expect(usage.rings.isEmpty && usage.bars.isEmpty)
        #expect(usage.error == "нет входа")
    }

    @Test func historyGivesForecastAndWeek() {
        let resets = now.addingTimeInterval(10 * 86_400)
        var history = LimitHistory()
        let key = LimitHistory.key(.copilot, "месяц")
        // 10 % a day for two days.
        for hour in stride(from: 0, through: 48, by: 6) {
            history.record(key, percent: 20 + Double(hour) * 10 / 24, resetsAt: resets, at: now.addingTimeInterval(Double(hour - 48) * 3600))
        }
        let limit = HubLimit(source: .copilot, windows: [HubLimit.Window(title: "месяц", percent: 40, resetsAt: resets)])
        let usage = ServiceUsage.hub(limit, history: history, now: now)
        guard case let .runsOutAt(date) = usage.forecast else { Issue.record("expected a forecast"); return }
        #expect(abs(date.timeIntervalSince(now.addingTimeInterval(6 * 86_400))) < 60, "60 % left at 10 % a day")
        let week = usage.week
        #expect(week?.days.count == 7)
        #expect(week?.days.last?.isToday == true)
        #expect(week?.forecast == .unknown, "one ring: its pace is already the forecast line")
        let total = week?.days.reduce(0) { $0 + $1.percent } ?? 0
        #expect(abs(total - 20) < 0.001, "growth from 20 % to 40 %")
    }

    @Test func historyPeriodsAndStorage() throws {
        var history = LimitHistory()
        let key = LimitHistory.key(.codex, "5 ч")
        let reset1 = now.addingTimeInterval(3600), reset2 = now.addingTimeInterval(6 * 3600)
        history.record(key, percent: 10, resetsAt: reset1, at: now)
        history.record(key, percent: 10, resetsAt: reset1, at: now.addingTimeInterval(600))
        #expect(history.readings[key]?.count == 1, "unchanged within 30 minutes")
        history.record(key, percent: 30, resetsAt: reset1, at: now.addingTimeInterval(1200))
        history.record(key, percent: 5, resetsAt: reset2, at: now.addingTimeInterval(1800))
        #expect(history.currentPeriod(key, resetsAt: reset2).map(\.percent) == [5], "a new reset starts over")
        history.record(key, percent: 2, resetsAt: reset2, at: now.addingTimeInterval(2400))
        #expect(history.currentPeriod(key, resetsAt: reset2).map(\.percent) == [2], "a drop is a reset too")
        history.record(key, percent: 3, resetsAt: reset2, at: now.addingTimeInterval(Self.keep + 3000))
        #expect(history.readings[key]?.count == 1, "older than 8 days dropped")

        let url = FileManager.default.temporaryDirectory.appending(path: "limit-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        history.save(to: url)
        #expect(LimitHistory.load(from: url) == history)
        #expect(LimitHistory.load(from: url.appending(path: "missing")) == LimitHistory())
    }

    @Test func weekWaitsForHalfADay() {
        var history = LimitHistory()
        let key = LimitHistory.key(.codex, "неделя")
        history.record(key, percent: 1, resetsAt: nil, at: now.addingTimeInterval(-3600))
        history.record(key, percent: 2, resetsAt: nil, at: now)
        #expect(history.week(key, resetsAt: nil, now: now) == nil)
        #expect(history.forecast(key, resetsAt: nil, now: now) != .unknown)
    }

    private static let keep = LimitHistory.keep
}

struct ResetTextTests {
    @Test func shortResetNamesTheDateBeyondAWeek() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let soon = try #require(UsageText.resetText(now.addingTimeInterval(3 * 86_400), now: now, short: true))
        let far = try #require(UsageText.resetText(now.addingTimeInterval(20 * 86_400), now: now, short: true))
        let day = now.addingTimeInterval(20 * 86_400).formatted(.dateTime.day())
        #expect(!soon.contains(now.addingTimeInterval(3 * 86_400).formatted(.dateTime.month(.abbreviated))))
        #expect(far.contains(day))
    }
}
