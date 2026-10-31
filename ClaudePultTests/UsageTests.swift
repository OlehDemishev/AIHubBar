import Foundation
import Testing
@testable import ClaudePult

struct UsageSnapshotTests {
    /// Abridged real response (2026-10-29): code-named objects, null model windows, `limits` list.
    static let response = #"""
    {
      "amber_cistern": null,
      "extra_usage": {"currency": "EUR", "decimal_places": 2, "disabled_reason": "out_of_credits", "is_enabled": false,
                      "monthly_limit": 2000, "used_credits": 0, "utilization": 0},
      "five_hour": {"limit_dollars": null, "resets_at": "2026-10-30T00:49:59.883026+00:00", "utilization": 13},
      "iguana_necktie": {"limit_dollars": 250, "resets_at": "2026-11-05T07:59:00+00:00", "used_dollars": 250.0, "utilization": 100},
      "limits": [
        {"group": "session", "kind": "session", "percent": 13, "resets_at": "2026-10-30T00:49:59.883026+00:00"},
        {"group": "weekly", "kind": "weekly_all", "percent": 57, "resets_at": "2026-11-02T09:00:00.883047+00:00"},
        {"group": "weekly", "kind": "weekly_scoped", "percent": 4, "resets_at": "2026-11-02T09:00:00+00:00",
         "scope": {"model": {"display_name": "Fable", "id": null}, "surface": null}}
      ],
      "seven_day": {"resets_at": "2026-11-02T09:00:00.261797+00:00", "utilization": 57},
      "seven_day_breakdown": {"rows": [{"key": "claude_code", "percent": 96}]},
      "seven_day_opus": null,
      "seven_day_sonnet": {"resets_at": "2026-11-02T09:00:00+00:00", "utilization": 21}
    }
    """#

    @Test func decodesRealShape() throws {
        let snapshot = try #require(UsageSnapshot.decode(Data(Self.response.utf8), fetchedAt: .now))
        #expect(snapshot.windows.map(\.key) == ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_fable"])
        #expect(snapshot.session?.utilization == 13)
        #expect(snapshot.week?.utilization == 57)
        let resets = try #require(snapshot.session?.resetsAt)
        #expect(abs(resets.timeIntervalSince(try #require(ISODate.parse("2026-10-30T00:50:00Z")))) < 1)
        #expect(snapshot.otherWindows.map(\.title) == ["Неделя · Sonnet", "Неделя · Fable"])
        var unused = snapshot
        unused.windows = unused.windows.map { var w = $0; if w.key == "seven_day_fable" { w.utilization = 0 }; return w }
        #expect(unused.shownOtherWindows.map(\.key) == ["seven_day_sonnet"], "a model week at 0 % takes no room in the panel")
        #expect(!snapshot.windows.contains { $0.key.contains("iguana") }, "code-named objects are not plan limits")
        #expect(snapshot.extra?.isEnabled == false)
        #expect(snapshot.extra?.monthlyLimit == 2000)
    }

    @Test func rejectsUnexpectedResponses() {
        #expect(UsageSnapshot.decode(Data(#"{"seven_day": {"utilization": 5}}"#.utf8), fetchedAt: .now) == nil)
        #expect(UsageSnapshot.decode(Data("garbage".utf8), fetchedAt: .now) == nil)
        #expect(UsageSnapshot.decode(Data(#"{"five_hour": null}"#.utf8), fetchedAt: .now) == nil)
    }

    @Test(arguments: [(0.0, UsageLevel.low), (49.9, .low), (50, .medium), (80, .medium), (80.1, .high), (100, .high)] as [(Double, UsageLevel)])
    func levels(percent: Double, level: UsageLevel) {
        #expect(UsageLevel(percent) == level)
    }

    @Test func usageFilePayload() throws {
        let snapshot = try #require(UsageSnapshot.decode(Data(Self.response.utf8), fetchedAt: Date(timeIntervalSince1970: 0)))
        let payload = UsageFile.payload(snapshot)
        #expect(Set(payload.keys) == ["five_hour", "seven_day", "updated"])
        #expect((payload["five_hour"] as? [String: Any])?["utilization"] as? Double == 13)
        #expect(payload["updated"] as? String == "1970-01-01T00:00:00Z")
    }

    @Test func credentials() {
        let json = #"{"claudeAiOauth": {"accessToken": "sk-test", "refreshToken": "r", "expiresAt": 1893456000000}}"#
        let credentials = UsageService.parseCredentials(Data(json.utf8))
        #expect(credentials?.accessToken == "sk-test")
        #expect(credentials?.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
        #expect(UsageService.parseCredentials(Data(#"{"other": 1}"#.utf8)) == nil)
        #expect(UsageService.parseCredentials(Data("not json".utf8)) == nil)
    }
}

struct UsageForecastTests {
    private let resets = Date(timeIntervalSince1970: 100_000)
    private var now: Date { resets.addingTimeInterval(-3 * 3600) }

    private func window(_ utilization: Double) -> UsageWindow {
        UsageWindow(key: "five_hour", title: "Сессия", utilization: utilization, resetsAt: resets)
    }

    @Test func runsOutBeforeReset() {
        // 20 % in 20 min → 1 %/min; 40 % left → 40 min, reset is in 3 h.
        let history = [UsagePoint(date: now.addingTimeInterval(-20 * 60), session: 40, sessionResetsAt: resets)]
        #expect(UsageForecast.make(history: history, current: window(60), now: now) == .runsOutAt(now.addingTimeInterval(40 * 60)))
    }

    @Test func lastsUntilReset() {
        let slow = [UsagePoint(date: now.addingTimeInterval(-30 * 60), session: 59, sessionResetsAt: resets)]
        #expect(UsageForecast.make(history: slow, current: window(60), now: now) == .lastsUntilReset)
        let flat = [UsagePoint(date: now.addingTimeInterval(-10 * 60), session: 60, sessionResetsAt: resets)]
        #expect(UsageForecast.make(history: flat, current: window(60), now: now) == .lastsUntilReset)
    }

    @Test func unknownWithoutEnoughData() {
        let recent = [UsagePoint(date: now.addingTimeInterval(-60), session: 50, sessionResetsAt: resets)]
        #expect(UsageForecast.make(history: recent, current: window(60), now: now) == .unknown)
        let otherWindow = [UsagePoint(date: now.addingTimeInterval(-20 * 60), session: 10, sessionResetsAt: resets.addingTimeInterval(-5 * 3600))]
        #expect(UsageForecast.make(history: otherWindow, current: window(60), now: now) == .unknown)
        #expect(UsageForecast.make(history: [], current: nil, now: now) == .unknown)
    }

    @Test func texts() {
        let base = Date(timeIntervalSince1970: 0)
        #expect(UsageText.countdown(to: base.addingTimeInterval(2 * 3600 + 14 * 60), now: base) == "через 2 ч 14 мин")
        #expect(UsageText.countdown(to: base.addingTimeInterval(35 * 60 + 30), now: base) == "через 35 мин")
        #expect(UsageText.countdown(to: base.addingTimeInterval(20), now: base) == "меньше чем через минуту")
        #expect(UsageText.countdown(to: base.addingTimeInterval(3 * 86_400 + 5 * 3600), now: base) == "через 3 дн 5 ч")
        #expect(UsageText.forecast(.lastsUntilReset) == "до сброса хватит")
        #expect(UsageText.forecast(.unknown) == nil)
    }
}

struct UsageAlertsTests {
    private let reset1 = Date(timeIntervalSince1970: 1_000_000)
    private let reset2 = Date(timeIntervalSince1970: 1_018_000)

    private func snapshot(session: Double, week: Double = 10, resets: Date) -> UsageSnapshot {
        UsageSnapshot(fetchedAt: .now, windows: [
            UsageWindow(key: "five_hour", title: "Сессия (5 ч)", utilization: session, resetsAt: resets),
            UsageWindow(key: "seven_day", title: "Неделя", utilization: week, resetsAt: reset2.addingTimeInterval(86_400)),
        ], extra: nil)
    }

    @Test func onlyHighestCrossedThresholdOncePerWindow() {
        var notified: Set<String> = []
        let first = UsageAlerts.evaluate(previous: nil, current: snapshot(session: 85, resets: reset1), thresholds: [50, 80, 95], notified: &notified)
        #expect(first == [.crossed(windowKey: "five_hour", title: "Сессия (5 ч)", threshold: 80, utilization: 85, resetsAt: reset1)])

        let again = UsageAlerts.evaluate(previous: snapshot(session: 85, resets: reset1), current: snapshot(session: 90, resets: reset1), thresholds: [50, 80, 95], notified: &notified)
        #expect(again.isEmpty)

        let higher = UsageAlerts.evaluate(previous: snapshot(session: 90, resets: reset1), current: snapshot(session: 96, resets: reset1), thresholds: [50, 80, 95], notified: &notified)
        #expect(higher.count == 1)
    }

    /// The API sends the same reset with a different fraction of a second each time: still the same window.
    @Test func jitteryResetIsTheSameWindow() {
        var notified: Set<String> = []
        let exact = Date(timeIntervalSince1970: 1_793_610_000)
        _ = UsageAlerts.evaluate(previous: nil, current: snapshot(session: 85, resets: exact.addingTimeInterval(0.048)), thresholds: [80], notified: &notified)
        let jitter = UsageAlerts.evaluate(previous: snapshot(session: 85, resets: exact.addingTimeInterval(0.048)),
                                          current: snapshot(session: 86, resets: exact.addingTimeInterval(-0.02)), thresholds: [80], notified: &notified)
        #expect(jitter.isEmpty)
        #expect(UsageWindow.sameReset(exact.addingTimeInterval(0.048), exact.addingTimeInterval(-0.02)))
        #expect(!UsageWindow.sameReset(exact, exact.addingTimeInterval(5 * 3600)))
    }

    @Test func restoredAfterReset() {
        var notified: Set<String> = []
        _ = UsageAlerts.evaluate(previous: nil, current: snapshot(session: 92, resets: reset1), thresholds: [80], notified: &notified)
        let after = UsageAlerts.evaluate(previous: snapshot(session: 92, resets: reset1), current: snapshot(session: 3, resets: reset2), thresholds: [80], notified: &notified)
        #expect(after == [.restored(windowKey: "five_hour", title: "Сессия (5 ч)")])
        // A new window can alert again at the same threshold.
        let newWindow = UsageAlerts.evaluate(previous: snapshot(session: 3, resets: reset2), current: snapshot(session: 81, resets: reset2), thresholds: [80], notified: &notified)
        #expect(newWindow.count == 1)
    }

    @Test func thresholdsParsing() {
        #expect(SettingsParsing.thresholds("50, 80, 95") == [50, 80, 95])
        #expect(SettingsParsing.thresholds("95 50 50 abc 0 120 80") == [50, 80, 95])
        #expect(SettingsParsing.thresholds("") == [])
    }
}

struct TokenUsageTests {
    private func line(id: String, session: String = "s1", cwd: String = "/P/Ambo", time: String = "2026-10-29T18:00:00Z",
                      input: Int = 10, output: Int = 100, create: Int = 1000, read: Int = 10000) -> String {
        #"{"type":"assistant","sessionId":"\#(session)","cwd":"\#(cwd)","timestamp":"\#(time)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(create),"cache_read_input_tokens":\#(read)}}}"#
    }

    @Test func parsesAssistantUsage() throws {
        let (id, record) = try #require(TokenLog.parse(line: Substring(line(id: "m1"))))
        #expect(id == "m1")
        #expect(record.total == 1110)
        #expect(record.weight == 10 + 500 + 1250 + 1000)
        #expect(TokenLog.parse(line: #"{"type":"user","message":{"content":"usage"}}"#) == nil)
        #expect(TokenLog.parse(line: "garbage \"usage\" \"assistant\"") == nil)
    }

    @Test func projectNames() {
        #expect(TokenLog.project(of: "/P/Ambo", projectsDirectory: "/P") == "Ambo")
        #expect(TokenLog.project(of: "/P/Ambo/.claude/worktrees/cb-x", projectsDirectory: "/P/") == "Ambo")
        #expect(TokenLog.project(of: "/P", projectsDirectory: "/P") == "Другое")
        #expect(TokenLog.project(of: "/tmp/x", projectsDirectory: "/P") == "Другое")
    }

    @Test func scannerIsIncrementalAndDeduplicates() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claudepult-tokens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "proj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "proj/s1.jsonl")
        let now = Date.now.ISO8601Format()
        // The same message twice (streaming) + a half-written last line.
        try (line(id: "m1", time: now) + "\n" + line(id: "m1", time: now) + "\n" + #"{"type":"assist"#).write(to: file, atomically: true, encoding: .utf8)

        let scanner = TokenScanner()
        let first = await scanner.scan(directory: dir, since: .distantPast)
        #expect(first.count == 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("ant\"}\n" + line(id: "m2", cwd: "/P/Cantero", time: now) + "\n").utf8))
        try handle.close()
        let second = await scanner.scan(directory: dir, since: .distantPast)
        #expect(second.count == 2)
    }

    @Test func breakdownShares() throws {
        let now = Date.now
        func record(_ cwd: String, _ session: String, output: Int) -> TokenRecord {
            TokenRecord(date: now, sessionID: session, cwd: cwd, model: nil, input: 0, output: output, cacheCreation: 0, cacheRead: 0)
        }
        let records = [record("/P/Ambo", "a", output: 300), record("/P/Ambo", "b", output: 100), record("/P/Cantero", "c", output: 100),
                       TokenRecord(date: now.addingTimeInterval(-86_400), sessionID: "old", cwd: "/P/Old", model: nil, input: 0, output: 999, cacheCreation: 0, cacheRead: 0)]
        let breakdown = TokenBreakdown.make(records, since: now.addingTimeInterval(-3600), projectsDirectory: "/P")
        #expect(breakdown.projects.map(\.name) == ["Ambo", "Cantero"])
        #expect(breakdown.projects.first?.share == 0.8)
        #expect(breakdown.topSession?.sessionID == "a")
        #expect(breakdown.topSession?.share == 0.6)
        #expect(breakdown.totalTokens == 500)
        #expect(TokenBreakdown.tokensText(12_340_000).hasPrefix("12"))
        #expect(TokenBreakdown.tokensText(850_000) == "850 тыс.")
    }
}

struct MenuBarStateTests {
    @Test func queuedLaunchRoundTrip() throws {
        let item = LaunchController.QueuedLaunch(
            id: "q", command: .customTask("Сделай"),
            target: .init(path: "/P/A", name: "A", nextItems: ["x"], baseRef: "origin/main"), launchAt: Date(timeIntervalSince1970: 1000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(LaunchController.QueuedLaunch.self, from: encoder.encode(item)) == item)
    }
}

struct UsageBackoffTests {
    @Test func retryAfterHeader() {
        let now = Date(timeIntervalSince1970: 1_793_300_000)
        #expect(UsageService.retryAfter("120", now: now) == 120)
        #expect(UsageService.retryAfter(" 0 ", now: now) == 0)
        #expect(UsageService.retryAfter(nil, now: now) == nil)
        #expect(UsageService.retryAfter("soon", now: now) == nil)
        let date = Date(timeIntervalSince1970: 1_793_300_000 + 300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        #expect(UsageService.retryAfter(formatter.string(from: date), now: now) == 300)
    }

    @MainActor
    @Test func backoffGrowsAndIsCapped() {
        #expect(UsageStore.backoff(strike: 1, retryAfter: nil) == 300)
        #expect(UsageStore.backoff(strike: 2, retryAfter: nil) == 600)
        #expect(UsageStore.backoff(strike: 4, retryAfter: nil) == 2400)
        #expect(UsageStore.backoff(strike: 9, retryAfter: nil) == 3600)
        #expect(UsageStore.backoff(strike: 1, retryAfter: 0) == 300, "Retry-After: 0 is not trusted")
        #expect(UsageStore.backoff(strike: 1, retryAfter: 900) == 900)
        #expect(UsageStore.backoff(strike: 3, retryAfter: 600) == 1200)
        #expect(UsageStore.backoff(strike: 1, retryAfter: 99_999) == 3600)
    }
}

struct UsageErrorTextTests {
    @Test func expiredTokenIsNotALoginProblem() {
        #expect(UsageError.expired.errorDescription?.contains("обновится при следующем запуске claude") == true)
        #expect(UsageError.noCredentials.errorDescription == "Войдите в Claude Code: claude → /login")
    }
}

struct LoginRenewalTests {
    @Test func atMostOnceAnHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(LoginRenewal.shouldTry(lastAttempt: nil, now: now))
        #expect(!LoginRenewal.shouldTry(lastAttempt: now.addingTimeInterval(-30 * 60), now: now))
        #expect(LoginRenewal.shouldTry(lastAttempt: now.addingTimeInterval(-61 * 60), now: now))
    }

    @Test func requestDoesNothingButSignIn() {
        let args = LoginRenewal.arguments
        #expect(args.starts(with: ["-p", "OK"]))
        #expect(args.contains("--no-session-persistence"), "no session left in the history")
        #expect(zip(args, args.dropFirst()).contains { $0 == "--tools" && $1.isEmpty }, "no tools")
        #expect(zip(args, args.dropFirst()).contains { $0 == "--setting-sources" && $1.isEmpty }, "no settings, so no hooks")
        #expect(!args.contains("--bare"), "--bare skips the keychain, so it would not sign in")
    }
}
