import Foundation
import Testing
@testable import ClaudePult

/// The week by day and its forecast (split of the plan's percentage by the journals' weights).
struct WeekUsageTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func record(_ date: Date, weight input: Int) -> TokenRecord {
        TokenRecord(date: date, sessionID: "s", cwd: "/p", model: nil, input: input, output: 0, cacheCreation: 0, cacheRead: 0)
    }

    /// Week from Monday 10:00 to the next Monday 10:00; «now» is Thursday 12:00.
    private var resets: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 10))! }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))! }

    @Test func splitsTheWeekByDay() {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
        let records = [record(monday, weight: 100), record(now.addingTimeInterval(-3600), weight: 300)]
        let week = WeekUsage.make(records, utilization: 40, resetsAt: resets, now: now, calendar: calendar)
        // Monday 10:00 → next Monday 10:00 touches 8 calendar days.
        #expect(week.days.count == 8)
        #expect(abs(week.days[0].percent - 10) < 0.01)
        #expect(abs(week.days[3].percent - 30) < 0.01)
        #expect(week.days[3].isToday && !week.days[0].isToday)
        #expect(abs(week.days.reduce(0) { $0 + $1.percent } - 40) < 0.01)
    }

    @Test func forecastFromTheLastDay() {
        // 30 of the 40 % in the last 24 h: 30 %/day → the remaining 60 % last two more days, Saturday ~12:00.
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
        let records = [record(monday, weight: 100), record(now.addingTimeInterval(-3600), weight: 300)]
        let week = WeekUsage.make(records, utilization: 40, resetsAt: resets, now: now, calendar: calendar)
        guard case let .runsOutAt(date) = week.forecast else { Issue.record("expected runsOutAt"); return }
        #expect(abs(date.timeIntervalSince(now.addingTimeInterval(2 * 86_400))) < 60)

        // Nothing in the last 24 h: the week lasts.
        let quiet = WeekUsage.make([record(monday, weight: 100)], utilization: 40, resetsAt: resets, now: now, calendar: calendar)
        #expect(quiet.forecast == .lastsUntilReset)
        // No journals at all: no forecast, days at zero.
        let empty = WeekUsage.make([], utilization: 40, resetsAt: resets, now: now, calendar: calendar)
        #expect(empty.forecast == .unknown && empty.days.allSatisfy { $0.percent == 0 })
    }
}
