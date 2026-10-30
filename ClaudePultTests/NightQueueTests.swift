import Foundation
import Testing
@testable import ClaudePult

/// «На ночь»: when the batch starts and what the morning summary says.
struct NightQueueTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func nextStart() {
        // 20:00 → 01:00 the next calendar day; 00:30 → 01:00 the same day; 01:00 sharp → the next night.
        #expect(NightQueue.nextStart(hour: 1, now: date(30, 20), calendar: calendar) == date(31, 1))
        #expect(NightQueue.nextStart(hour: 1, now: date(31, 0, 30), calendar: calendar) == date(31, 1))
        #expect(NightQueue.nextStart(hour: 1, now: date(31, 1), calendar: calendar) == date(32, 1)) // 1 November
        #expect(NightQueue.nextStart(hour: 23, now: date(30, 20), calendar: calendar) == date(30, 23))
    }

    @Test func oldQueueFilesStillLoad() throws {
        // Saved before «на ночь» existed: no `night` key.
        let json = #"[{"id":"q","command":{"nextStep":{}},"target":{"name":"Ambo","path":"/p/Ambo","nextItems":[],"baseRef":"main"},"launchAt":"2026-10-30T20:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([LaunchController.QueuedLaunch].self, from: Data(json.utf8))
        #expect(items.first?.night == false)
    }
}
