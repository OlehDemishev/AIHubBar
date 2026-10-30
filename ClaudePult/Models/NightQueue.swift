import Foundation

/// «На ночь»: background runs queued for the night start hour, run while the Mac is free (and kept awake by the
/// «пока работает Claude» rule), then one morning summary of the whole batch.
enum NightQueue {
    static let hours = [22, 23, 0, 1, 2, 3, 4]

    /// The next time it is `hour` o'clock; tonight if still ahead, else tomorrow.
    static func nextStart(hour: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
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
