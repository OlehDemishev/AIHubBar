import Foundation

/// «Цель по словам» of a folder profile (SPEC-content stage 5): how many words were added today to the projects'
/// main files. A day's start is what each file had when it was last seen the day before; a file first seen today
/// starts from what it has, so an old text dropped into the folder is not today's work. Cut text never counts
/// below zero for its file. Kept in `word-goals.json` per profile: numbers only, no text.
struct WordProgress: Codable, Equatable, Sendable {
    /// `2026-11-23` in the Mac's own calendar.
    var day: String
    /// Words in each project's main file when the day began, by project path.
    var baselines: [String: Int]
    /// The same at the last look.
    var latest: [String: Int]

    func written(_ counts: [String: Int]) -> Int {
        counts.reduce(0) { $0 + max(0, $1.value - (baselines[$1.key] ?? $1.value)) }
    }
}

enum WordGoal {
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The record after a look at the folder. A new day starts from yesterday's last look; after a longer break —
    /// from what is there now, since nobody knows on which day those words were written.
    static func advanced(_ previous: WordProgress?, counts: [String: Int], now: Date, calendar: Calendar = .current) -> WordProgress {
        let today = day(now, calendar: calendar)
        guard let previous else { return WordProgress(day: today, baselines: counts, latest: counts) }
        if previous.day == today {
            var baselines = previous.baselines
            for (path, count) in counts where baselines[path] == nil { baselines[path] = count }
            return WordProgress(day: today, baselines: baselines, latest: counts)
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { day($0, calendar: calendar) }
        guard previous.day == yesterday else { return WordProgress(day: today, baselines: counts, latest: counts) }
        var baselines: [String: Int] = [:]
        for (path, count) in counts { baselines[path] = previous.latest[path] ?? count }
        return WordProgress(day: today, baselines: baselines, latest: counts)
    }

    static var fileURL: URL { SessionFiles.supportDirectory.appending(path: "word-goals.json") }

    static func load(from url: URL = fileURL) -> [String: WordProgress] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: WordProgress].self, from: $0) } ?? [:]
    }

    static func save(_ records: [String: WordProgress], to url: URL = fileURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(records).write(to: url, options: .atomic)
    }
}
