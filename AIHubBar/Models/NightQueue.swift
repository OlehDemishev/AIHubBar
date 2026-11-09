import Foundation

/// «На ночь»: background runs queued for the night start hour, run while the Mac is free (and kept awake by the
/// «пока работает Claude» rule), then one morning summary of the whole batch.
enum NightQueue {
    static let hours = [22, 23, 0, 1, 2, 3, 4]

    /// The night lasts from the start hour to this one.
    static let endHour = 6

    /// When a run queued now starts: at the next `hour` o'clock, or at once if the night has already begun
    /// (queued at 23:30 with a 22:00 start, it must not wait for tomorrow's night).
    static func nextStart(hour: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        let lastStart = today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        // The first 06:00 after that start: the same morning for a start after midnight, the next one otherwise.
        if let end = calendar.nextDate(after: lastStart, matching: DateComponents(hour: endHour, minute: 0, second: 0),
                                       matchingPolicy: .nextTime), now < end {
            return now
        }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// «Ночью: 3 задачи — ✅ 2, ❌ 1» and a line per run.
    static func summary(_ runs: [BackgroundRun]) -> (title: String, body: String) {
        let done = runs.filter { $0.state == .succeeded }.count
        let failed = runs.count - done
        let title = String(localized: "Ночью: \(runs.count) задач — ✅ \(done), ❌ \(failed)")
        let body = runs.map { "\(RunMessage.icon($0.state)) \($0.project): \(RunMessage.taskStart($0.task))" }.joined(separator: "\n")
        return (title, body)
    }
}

/// «Стоп-кран»: near a limit, background runs are paused and queued ones wait, until that window resets.
enum RunGuard {
    struct Hold: Equatable, Sendable {
        var title: String
        var utilization: Double
        var resetsAt: Date?

        /// When to try again: two minutes after the reset, or in half an hour if the reset is unknown.
        func retryAt(now: Date = .now) -> Date {
            (resetsAt ?? now.addingTimeInterval(1800)).addingTimeInterval(120)
        }
    }

    /// The window over the threshold that resets last; a window whose reset has already passed is stale, not full.
    static func hold(_ snapshot: UsageSnapshot?, threshold: Int, now: Date = .now) -> Hold? {
        guard threshold > 0, let snapshot else { return nil }
        return [snapshot.session, snapshot.week].compactMap { $0 }
            .filter { $0.utilization >= Double(threshold) && ($0.resetsAt.map { $0 > now } ?? true) }
            .max { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
            .map { Hold(title: $0.title, utilization: $0.utilization, resetsAt: $0.resetsAt) }
    }

    static let thresholds = [0, 80, 90, 95, 98]
}
