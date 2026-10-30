import Foundation
import Testing
@testable import ClaudePult

/// What a session changed (git) and the weekly Telegram summary.
struct SessionChangesTests {
    @Test func parsesNumstatAndNewFiles() {
        let changes = SessionChanges.parse(
            numstat: "12\t3\tClaudePult/App.swift\n-\t-\tlogo.png\n0\t7\tdocs/OLD.md\n",
            untracked: "ClaudePult/New.swift\nClaudePult/App.swift\n"
        )
        #expect(changes.files.count == 4)
        #expect(changes.added == 12)
        #expect(changes.removed == 10)
        #expect(changes.files.last == SessionChanges.File(path: "ClaudePult/New.swift", added: nil, removed: nil, isNew: true))
        #expect(changes.summary.contains("+12") && changes.summary.contains("−10"))
        #expect(SessionChanges.parse(numstat: "", untracked: "").isEmpty)
    }

    /// A real repository: a commit made during the session and an uncommitted edit both count; earlier work doesn't.
    @Test func readsARepository() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "changes-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        func git(_ args: String...) async throws { try await GitService.run(["-c", "user.name=t", "-c", "user.email=t@t"] + args, in: folder) }
        try await GitService.run(["init", "-q"], in: folder)
        try "old\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try await git("add", ".")
        // rev-list goes by the committer date.
        _ = try await ProcessRunner.run(GitService.git, ["-C", folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "before"],
                                        environment: ["GIT_COMMITTER_DATE": "2020-01-01T00:00:00", "GIT_AUTHOR_DATE": "2020-01-01T00:00:00"], timeout: .seconds(20))
        let start = Date.now.addingTimeInterval(-1)
        try "old\nnew\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try await git("commit", "-qam", "during")
        try "x\n".write(toFile: folder + "/b.txt", atomically: true, encoding: .utf8)
        let changes = try #require(await SessionChangesStore.read(folder: folder, since: start))
        #expect(changes.files.map(\.path).sorted() == ["a.txt", "b.txt"])
        #expect(changes.added == 1)
    }

    @Test func weeklySendTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func date(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }
        // 1 November 2026 is a Sunday.
        #expect(WeeklySummary.due(weekday: 1, hour: 19, now: date(1, 20), calendar: calendar) == date(1, 19))
        #expect(WeeklySummary.due(weekday: 1, hour: 19, now: date(1, 18), calendar: calendar) == calendar.date(byAdding: .day, value: -7, to: date(1, 19)))
        #expect(WeeklySummary.due(weekday: 1, hour: 19, now: date(4, 10), calendar: calendar) == date(1, 19))
    }

    @Test func summaryText() {
        let breakdown = TokenBreakdown(
            projects: [.init(name: "ClaudePult", tokens: 2_000_000, share: 0.6), .init(name: "<Ambo>", tokens: 500_000, share: 0.4)],
            topSession: nil, totalTokens: 2_500_000,
            topSessions: [.init(sessionID: "s", project: "ClaudePult", tokens: 900_000, share: 0.3)]
        )
        let html = WeeklySummary.html(.init(weekPercent: 89, weekResetsAt: nil, breakdown: breakdown, sessionHits: 2, weekHits: 0, runs: [], now: .now))
        #expect(html.hasPrefix("📊 <b>"))
        #expect(html.contains("ClaudePult — 60 %"))
        #expect(html.contains("&lt;Ambo&gt;"))
        #expect(html.contains("2"))
    }

    @Test func limitHitsAreKeptAMonth() {
        let defaults = UserDefaults(suiteName: "hits-\(UUID())")!
        LimitHits.record("five_hour", at: .now.addingTimeInterval(-40 * 86_400), defaults: defaults)
        LimitHits.record("seven_day", at: .now, defaults: defaults)
        #expect(LimitHits.all(defaults: defaults).map(\.window) == ["seven_day"])
    }
}
