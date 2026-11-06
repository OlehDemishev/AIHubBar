import Foundation

/// One day of Claude Code use, kept after the journals' week has moved on: tokens from the journals, and the highest
/// limit percentages seen that day. `usage-days.json`, about a year.
struct UsageDay: Codable, Equatable, Identifiable, Sendable {
    /// `yyyy-MM-dd` in the Mac's time zone.
    var day: String
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var sessionPeak: Double?
    var weekPeak: Double?

    var id: String { day }
    /// As shown elsewhere in the app: without cache reads, which dwarf everything else.
    var tokens: Int { input + output + cacheWrite }
    var date: Date { UsageDays.formatter.date(from: day) ?? .distantPast }

    /// What these tokens would cost through the API at `price` (dollars per million tokens); cache writes cost
    /// a quarter more than input and cache reads a tenth of it, as in `TokenRecord.weight`.
    func cost(_ price: APIPrice) -> Double {
        let inputLike = Double(input) + Double(cacheWrite) * 1.25 + Double(cacheRead) * 0.1
        return (inputLike * price.input + Double(output) * price.output) / 1_000_000
    }
}

enum UsageDays {
    static let keptDays = 400

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func key(_ date: Date) -> String { formatter.string(from: date) }

    /// Adds what the journals say. The scanner holds only part of the oldest day it returns, so a day's counters
    /// never go down.
    static func merging(_ days: [UsageDay], records: [TokenRecord], now: Date = .now) -> [UsageDay] {
        var fresh: [String: UsageDay] = [:]
        for record in records {
            let key = key(record.date)
            var day = fresh[key] ?? UsageDay(day: key)
            day.input += record.input
            day.output += record.output
            day.cacheWrite += record.cacheCreation
            day.cacheRead += record.cacheRead
            fresh[key] = day
        }
        var byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, new) in fresh {
            var day = byDay[key] ?? UsageDay(day: key)
            day.input = max(day.input, new.input)
            day.output = max(day.output, new.output)
            day.cacheWrite = max(day.cacheWrite, new.cacheWrite)
            day.cacheRead = max(day.cacheRead, new.cacheRead)
            byDay[key] = day
        }
        return trimmed(Array(byDay.values), now: now)
    }

    /// The limits as they stand now; a day keeps its highest figures.
    static func noting(_ days: [UsageDay], session: Double?, week: Double?, now: Date = .now) -> [UsageDay] {
        var byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        let key = key(now)
        var day = byDay[key] ?? UsageDay(day: key)
        if let session { day.sessionPeak = max(day.sessionPeak ?? 0, session) }
        if let week { day.weekPeak = max(day.weekPeak ?? 0, week) }
        byDay[key] = day
        return trimmed(Array(byDay.values), now: now)
    }

    private static func trimmed(_ days: [UsageDay], now: Date) -> [UsageDay] {
        let oldest = key(now.addingTimeInterval(-Double(keptDays) * 86_400))
        return days.filter { $0.day >= oldest }.sorted { $0.day < $1.day }
    }

    /// The last `count` days, today included.
    static func recent(_ days: [UsageDay], count: Int, now: Date = .now) -> [UsageDay] {
        let first = key(now.addingTimeInterval(-Double(count - 1) * 86_400))
        return days.filter { $0.day >= first }
    }

    static func csv(_ days: [UsageDay]) -> String {
        let header = "date,input,output,cache_write,cache_read,session_peak_percent,week_peak_percent"
        func percent(_ value: Double?) -> String { value.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "" }
        let rows = days.map {
            "\($0.day),\($0.input),\($0.output),\($0.cacheWrite),\($0.cacheRead),\(percent($0.sessionPeak)),\(percent($0.weekPeak))"
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}
