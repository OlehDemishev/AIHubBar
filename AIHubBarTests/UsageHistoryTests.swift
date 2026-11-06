import Foundation
import Testing
@testable import AIHubBar

struct UsageHistoryTests {
    let now = UsageDays.formatter.date(from: "2026-11-06")!.addingTimeInterval(12 * 3600)

    func record(_ day: String, input: Int = 0, output: Int = 0, write: Int = 0, read: Int = 0) -> TokenRecord {
        TokenRecord(date: UsageDays.formatter.date(from: day)!.addingTimeInterval(3600), sessionID: "s", cwd: "/", model: nil,
                    input: input, output: output, cacheCreation: write, cacheRead: read)
    }

    @Test func journalsAddUpByDay() {
        let days = UsageDays.merging([], records: [record("2026-11-05", input: 10), record("2026-11-05", output: 5), record("2026-11-06", write: 7)], now: now)
        #expect(days.map(\.day) == ["2026-11-05", "2026-11-06"], "oldest first")
        #expect(days[0].tokens == 15 && days[1].cacheWrite == 7)
    }

    @Test func aDayNeverGoesDown() {
        var days = UsageDays.merging([], records: [record("2026-11-05", input: 100)], now: now)
        days = UsageDays.merging(days, records: [record("2026-11-05", input: 40)], now: now)
        #expect(days[0].input == 100, "the scanner holds only part of its oldest day")
    }

    @Test func peaksKeepTheHighest() {
        var days = UsageDays.noting([], session: 40, week: 10, now: now)
        days = UsageDays.noting(days, session: 5, week: 12, now: now)
        #expect(days[0].sessionPeak == 40 && days[0].weekPeak == 12)
        days = UsageDays.noting(days, session: nil, week: nil, now: now)
        #expect(days[0].sessionPeak == 40, "a missing figure changes nothing")
    }

    @Test func oldDaysAreDropped() {
        let days = UsageDays.merging([UsageDay(day: "2024-01-01", input: 1)], records: [record("2026-11-06", input: 1)], now: now)
        #expect(days.map(\.day) == ["2026-11-06"])
    }

    @Test func recentCountsToday() {
        let days = [UsageDay(day: "2026-10-30"), UsageDay(day: "2026-10-31"), UsageDay(day: "2026-11-06")]
        #expect(UsageDays.recent(days, count: 7, now: now).map(\.day) == ["2026-10-31", "2026-11-06"])
    }

    @Test func costUsesTheGivenPrice() {
        let day = UsageDay(day: "2026-11-06", input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(day.cost(APIPrice(input: 2, output: 10)) - (2 * (1 + 1.25 + 0.1) + 10)) < 0.0001)
    }

    @Test func csvHasAHeaderAndEmptyPeaks() {
        let csv = UsageDays.csv([UsageDay(day: "2026-11-06", input: 1, output: 2, cacheWrite: 3, cacheRead: 4, sessionPeak: 12.34)])
        #expect(csv == "date,input,output,cache_write,cache_read,session_peak_percent,week_peak_percent\n2026-11-06,1,2,3,4,12.3,\n")
    }
}
