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
        #expect(items.first?.afterReset == false)
    }

    private func window(_ key: String, _ percent: Double, resets: Date?) -> UsageWindow {
        UsageWindow(key: key, title: UsageWindow.title(forKey: key), utilization: percent, resetsAt: resets)
    }

    @Test func guardHoldsUntilTheWindowResets() {
        let now = date(30, 12)
        let session = window("five_hour", 96, resets: date(30, 14))
        let week = window("seven_day", 40, resets: date(33, 9))
        let snapshot = UsageSnapshot(fetchedAt: now, windows: [session, week], extra: nil)
        let hold = RunGuard.hold(snapshot, threshold: 95, now: now)
        #expect(hold?.resetsAt == date(30, 14))
        #expect(hold?.retryAt(now: now) == date(30, 14, 2))
        // Off, below the threshold, or a reset already passed (the figures are stale): nothing holds.
        #expect(RunGuard.hold(snapshot, threshold: 0, now: now) == nil)
        #expect(RunGuard.hold(snapshot, threshold: 98, now: now) == nil)
        #expect(RunGuard.hold(snapshot, threshold: 95, now: date(30, 15)) == nil)
        // Both full: the week, which resets later, holds.
        let both = UsageSnapshot(fetchedAt: now, windows: [session, window("seven_day", 99, resets: date(33, 9))], extra: nil)
        #expect(RunGuard.hold(both, threshold: 95, now: now)?.resetsAt == date(33, 9))
    }

    @Test func pausedTimeDoesNotCountTowardTheLimit() {
        var run = BackgroundRun(
            id: "r", project: "Ambo", projectPath: "/p", folder: "/p", worktreeBranch: nil, commandTitle: "Шаг", task: "t",
            startedAt: date(30, 10), timeLimitMinutes: 90, pid: nil, state: .running, notified: false, resultFile: nil
        )
        #expect(run.deadline(now: date(30, 11)) == date(30, 11, 30))
        run.pausedAt = date(30, 11)
        #expect(run.isPaused)
        #expect(run.deadline(now: date(30, 13)) == date(30, 13, 30))
        run.pausedAt = nil
        run.pausedSeconds = 7200
        #expect(run.deadline(now: date(30, 14)) == date(30, 13, 30))
    }
}
