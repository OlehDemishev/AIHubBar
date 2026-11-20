import Foundation

/// The sample data of the demo copy (`DemoMode`): invented projects, sessions and numbers, built from the same types
/// the live app fills, so a change to those types breaks the build here instead of the recording.
///
/// Texts are English and not translated: they stand in for a person's own content (project names, requests), which
/// the app never translates either. Everything is counted from `now`, so the copy looks current whenever it starts.
struct DemoData {
    /// The release this data was last brought up to date for; the same value as `WhatsNew.version`, and a test keeps
    /// the two equal. A release with news changes `WhatsNew.version`, the test fails, and whoever makes the release
    /// adds what the new version should show here (docs/RELEASE.md → «Demo») before raising this.
    static let version = "0.12"

    var snapshot: UsageSnapshot?
    var history: [UsagePoint] = []
    var week: WeekUsage?
    var days: [UsageDay] = []
    var breakdowns: [UsageStore.Period: TokenBreakdown] = [:]
    var hubLimits: [HubLimit] = []
    var sessions: [SessionStore.Item] = []
    var approvals: [String: ApprovalRequest] = [:]
    var runs: [BackgroundRun] = []
    var report: ProjectsReport?
    /// `~/.claude.json` of the copy's home: the name and plan in the panel's header. nil — no Claude on this Mac.
    var claudeIdentity: Data?

    static var projectsDirectory: String { NSHomeDirectory() + "/Projects" }
    static let projects = ["atlas-api", "atlas-web", "notes-app", "landing"]

    static func make(scene: DemoMode.Scene, now: Date, calendar: Calendar = .current) -> DemoData {
        var data = DemoData()
        let hasClaude = scene != .codexMain
        if hasClaude { data.addClaudeLimits(now: now, calendar: calendar) }
        data.hubLimits = hubLimits(scene: scene, now: now)
        data.addSessions(mainAgent: hasClaude ? .claudeCode : .codex, now: now)
        data.runs = runs(now: now)
        data.report = report(now: now)
        return data
    }

    // MARK: - Claude's limits

    private mutating func addClaudeLimits(now: Date, calendar: Calendar) {
        let sessionReset = now.addingTimeInterval(2 * 3600 + 10 * 60)
        let weekReset = now.addingTimeInterval(3 * 86_400 + 5 * 3600)
        let sessionPercent = 62.0, weekPercent = 48.0
        snapshot = UsageSnapshot(fetchedAt: now, windows: [
            UsageWindow(key: "five_hour", title: UsageWindow.title(forKey: "five_hour"), utilization: sessionPercent, resetsAt: sessionReset),
            UsageWindow(key: "seven_day", title: UsageWindow.title(forKey: "seven_day"), utilization: weekPercent, resetsAt: weekReset),
            UsageWindow(key: "seven_day_opus", title: UsageWindow.title(forKey: "seven_day_opus"), utilization: 21, resetsAt: weekReset),
        ], extra: nil)
        // The last 25 minutes of the session, growing evenly: a pace of 12 % an hour that lasts until the reset.
        history = (0...5).map { step in
            UsagePoint(date: now.addingTimeInterval(Double(step - 5) * 300), session: sessionPercent - Double(5 - step), sessionResetsAt: sessionReset)
        }
        let records = Self.records(now: now, calendar: calendar)
        week = WeekUsage.make(records, utilization: weekPercent, resetsAt: weekReset, now: now, calendar: calendar)
        let starts: [UsageStore.Period: Date] = [
            .session: sessionReset.addingTimeInterval(-5 * 3600),
            .today: calendar.startOfDay(for: now),
            .week: weekReset.addingTimeInterval(-7 * 86_400),
        ]
        breakdowns = starts.mapValues { TokenBreakdown.make(records, since: $0, projectsDirectory: Self.projectsDirectory) }
        var random = Generator(seed: 7)
        days = UsageDays.merging([], records: records, now: now).map { day in
            var day = day
            day.sessionPeak = Double(random.next(35...96))
            day.weekPeak = Double(random.next(8...74))
            return day
        }
        claudeIdentity = try? JSONSerialization.data(withJSONObject: ["oauthAccount": [
            "displayName": "Alex", "organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_5x",
        ]])
    }

    /// A month of messages in the sample projects, the same on every start: the week by day, «Куда ушли токены» and
    /// the usage history are all counted from them, as from the real journals.
    static func records(now: Date, calendar: Calendar) -> [TokenRecord] {
        var random = Generator(seed: 11)
        var records: [TokenRecord] = []
        let today = calendar.startOfDay(for: now)
        for daysAgo in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            for (index, project) in projects.enumerated() {
                // The first projects are the busy ones; weekends are quiet.
                let weekend = calendar.isDateInWeekend(day)
                let messages = max(0, random.next(2...9) - index * 2 - (weekend ? 4 : 0))
                for message in 0..<messages {
                    let date = day.addingTimeInterval(Double(9 * 3600 + random.next(0...11 * 3600)))
                    guard date <= now else { continue }
                    records.append(TokenRecord(
                        date: date, sessionID: "demo-\(daysAgo)-\(index)-\(message % 3)", cwd: "\(projectsDirectory)/\(project)",
                        model: "claude-opus", input: random.next(2_000...40_000), output: random.next(1_000...18_000),
                        cacheCreation: random.next(5_000...120_000), cacheRead: random.next(200_000...2_500_000)
                    ))
                }
            }
        }
        return records.sorted { $0.date < $1.date }
    }

    // MARK: - The other services

    static func hubLimits(scene: DemoMode.Scene, now: Date) -> [HubLimit] {
        let fiveHours = HubParse.windowTitle(minutes: 300), week = HubParse.windowTitle(minutes: 10_080)
        let leads = scene == .codexMain
        var codex = HubLimit(source: .codex, windows: [
            .init(title: fiveHours, percent: leads ? 57 : 34, resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60)),
            .init(title: week, percent: leads ? 44 : 58, resetsAt: now.addingTimeInterval(4 * 86_400 + 2 * 3600)),
        ])
        codex.notes = [ServiceNote(text: String(localized: "План: \("Plus")"), symbol: "person.crop.circle")]
        codex.projects = [
            ProjectTokens(path: "\(projectsDirectory)/notes-app", name: "notes-app", tokens: 1_840_000),
            ProjectTokens(path: "\(projectsDirectory)/atlas-api", name: "atlas-api", tokens: 610_000),
        ]
        let copilot = HubLimit(source: .copilot, windows: [
            .init(title: HubParse.windowTitle(minutes: 30 * 1440), percent: 41, resetsAt: now.addingTimeInterval(12 * 86_400)),
        ])
        // Antigravity's quota, new in 0.11: Gemini and the other models, with the plan.
        var antigravity = HubLimit(source: .antigravity, windows: [
            .init(title: HubParse.antigravityTitle("gemini-weekly"), percent: 27, resetsAt: now.addingTimeInterval(5 * 86_400)),
            .init(title: HubParse.antigravityTitle("3p-weekly"), percent: 12, resetsAt: now.addingTimeInterval(5 * 86_400)),
        ])
        antigravity.notes = [ServiceNote(text: String(localized: "План: \("Pro")"), symbol: "person.crop.circle")]
        return [codex, copilot, antigravity]
    }

    // MARK: - Sessions

    private mutating func addSessions(mainAgent: AgentKind, now: Date) {
        func path(_ project: String) -> String { "\(Self.projectsDirectory)/\(project)" }
        func iso(_ secondsAgo: Double) -> String {
            now.addingTimeInterval(-secondsAgo).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        let waiting = Self.session([
            "session_id": "demo-session-1", "cwd": path("atlas-api"), "project": "atlas-api", "project_path": path("atlas-api"),
            "state": "waiting", "agent": mainAgent.rawValue, "term_program": "Apple_Terminal",
            "started_at": iso(38 * 60), "updated_at": iso(20), "prompt_at": iso(6 * 60),
            "first_prompt": "Add rate limiting to the public API", "last_prompt": "Run the migration on staging and check the logs",
            "message": "Claude needs your permission to use Bash",
            "last_tool": "Read", "last_target": "migrations/0042_rate_limits.sql", "last_tool_at": iso(40),
        ])
        let working = Self.session([
            "session_id": "demo-session-2", "cwd": path("atlas-web"), "project": "atlas-web", "project_path": path("atlas-web"),
            "state": "running", "agent": mainAgent.rawValue, "term_program": "Apple_Terminal",
            "started_at": iso(72 * 60), "updated_at": iso(4), "prompt_at": iso(9 * 60),
            "first_prompt": "Redesign the pricing page", "last_prompt": "Make the pricing table work on phones",
            "last_tool": "Edit", "last_target": "src/components/PricingTable.tsx", "last_tool_at": iso(4),
            "todos": [
                ["content": "Read the current table", "status": "completed"],
                ["content": "Stack the plans on narrow screens", "status": "in_progress", "active_form": "Stacking the plans on narrow screens"],
                ["content": "Run the tests", "status": "pending"],
            ],
        ])
        let other = Self.session([
            "session_id": "demo-session-3", "cwd": path("notes-app"), "project": "notes-app", "project_path": path("notes-app"),
            "state": "running", "agent": AgentKind.codex.rawValue, "term_program": "Apple_Terminal",
            "started_at": iso(15 * 60), "updated_at": iso(9), "prompt_at": iso(3 * 60),
            "first_prompt": "Find why search is slow with many notes", "last_prompt": "Find why search is slow with many notes",
            "last_tool": "Bash", "last_target": "swift test --filter SearchTests", "last_tool_at": iso(9),
        ])
        let finished = Self.session([
            "session_id": "demo-session-4", "cwd": path("landing"), "project": "landing", "project_path": path("landing"),
            "state": "done", "agent": mainAgent.rawValue, "term_program": "Apple_Terminal",
            "started_at": iso(55 * 60), "updated_at": iso(14 * 60), "prompt_at": iso(21 * 60),
            "first_prompt": "Add the FAQ section", "last_prompt": "Add the FAQ section",
        ])
        let contexts: [Double?] = [0.64, 0.42, 0.18, 0.71]
        sessions = zip([waiting, working, other, finished], contexts).compactMap { session, context in
            session.map { SessionStore.Item(session: $0, state: $0.state, context: context) }
        }
        if let waiting {
            approvals[waiting.id] = ApprovalRequest(
                id: "demo-approval-1", sessionID: waiting.id, project: waiting.project, tool: "Bash",
                summary: "npm run migrate -- --env staging", created: now.timeIntervalSince1970 - 20, pid: nil
            )
        }
    }

    /// A session as the hook writes it: `Session` only decodes, so the sample goes the same way as a real file.
    private static func session(_ fields: [String: Any]) -> Session? {
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    // MARK: - Background runs

    static func runs(now: Date) -> [BackgroundRun] {
        func path(_ project: String) -> String { "\(projectsDirectory)/\(project)" }
        return [
            BackgroundRun(
                id: "demo-run-1", project: "atlas-api", projectPath: path("atlas-api"), folder: path("atlas-api"),
                worktreeBranch: "chore/update-dependencies", commandTitle: "Task",
                task: "Update the dependencies and fix what breaks", startedAt: now.addingTimeInterval(-12 * 60),
                timeLimitMinutes: 60, pid: nil, state: .running, finishedAt: nil, summary: nil, pullRequestURL: nil,
                notified: false, resultFile: nil
            ),
            BackgroundRun(
                id: "demo-run-2", project: "landing", projectPath: path("landing"), folder: path("landing"),
                worktreeBranch: "test/contact-form", commandTitle: "Task",
                task: "Write tests for the contact form", startedAt: now.addingTimeInterval(-64 * 60),
                timeLimitMinutes: 60, pid: nil, state: .succeeded, finishedAt: now.addingTimeInterval(-41 * 60),
                summary: "Added 9 tests for the contact form; all pass.",
                pullRequestURL: "https://github.com/example/landing/pull/42", notified: true, resultFile: nil
            ),
            // 0.12: one task given to Claude and Codex at once; «Compare with…» in either row opens both answers.
            BackgroundRun(
                id: "demo-run-3", project: "atlas-api", projectPath: path("atlas-api"),
                folder: path("atlas-api") + "/.claude/worktrees/cb-claude-csv-export",
                worktreeBranch: "cb/claude-csv-export", commandTitle: "Task",
                task: "Add CSV export to the reports endpoint", startedAt: now.addingTimeInterval(-38 * 60),
                timeLimitMinutes: 60, pid: nil, state: .succeeded, finishedAt: now.addingTimeInterval(-27 * 60),
                summary: "Added GET /reports/export.csv with streaming and 6 tests; all pass.",
                pullRequestURL: nil, notified: true, resultFile: nil, pair: "demo-pair-1"
            ),
            BackgroundRun(
                id: "demo-run-4", project: "atlas-api", projectPath: path("atlas-api"),
                folder: path("atlas-api") + "/.claude/worktrees/cb-codex-csv-export",
                worktreeBranch: "cb/codex-csv-export", commandTitle: "Task",
                task: "Add CSV export to the reports endpoint", startedAt: now.addingTimeInterval(-38 * 60),
                timeLimitMinutes: 60, pid: nil, state: .succeeded, finishedAt: now.addingTimeInterval(-24 * 60),
                summary: "Added a CSV serializer and the export route; 4 tests pass.",
                pullRequestURL: nil, notified: true, resultFile: nil, agent: CodexExec.agent, pair: "demo-pair-1"
            ),
        ]
    }

    static func log(of run: BackgroundRun) -> String {
        let lines = run.state == .running
            ? ["Reading package.json", "npm outdated: 7 packages behind", "Updating express 4.19 → 5.1", "Running the tests…"]
            : ["Reading src/contact/form.ts", "Writing tests/contact-form.test.ts", "9 tests passed", run.summary ?? ""]
        return (["Task: \(run.task)", ""] + lines).joined(separator: "\n") + "\n"
    }

    // MARK: - Projects

    /// The projects as `report.py --json` and the built-in git scanner give them.
    static func report(now: Date) -> ProjectsReport? {
        func iso(_ hoursAgo: Double) -> String {
            now.addingTimeInterval(-hoursAgo * 3600).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        func project(_ name: String, branch: String, health: String, hoursAgo: Double, dirty: Int = 0,
                     pullRequests: [[String: Any]] = [], attention: [[String: Any]] = [], stage: String, next: [String]) -> [String: Any] {
            [
                "name": name, "path": "\(projectsDirectory)/\(name)", "branch": branch, "default_branch": "main",
                "remote": "https://github.com/example/\(name)", "health": health, "last_activity": iso(hoursAgo),
                "dirty": dirty, "stashes": 0, "open_prs": pullRequests, "worktrees": [], "attention": attention,
                "status": ["path": "docs/STATUS.md", "summary": ["stage": stage, "now": [], "next": next, "needs": []]],
            ]
        }
        let projects: [[String: Any]] = [
            project("atlas-api", branch: "feat/rate-limits", health: "yellow", hoursAgo: 0.1, dirty: 3,
                    pullRequests: [["number": 128, "title": "Add rate limiting to the public API",
                                    "url": "https://github.com/example/atlas-api/pull/128", "isDraft": false, "ci": "pending"]],
                    attention: [["level": "mid", "text": "3 uncommitted files"]],
                    stage: "Rate limits before the public launch", next: ["Run the migration on staging", "Load test"]),
            project("atlas-web", branch: "feat/pricing-page", health: "green", hoursAgo: 0.2, dirty: 1,
                    stage: "New pricing page", next: ["Phone layout", "Copy review"]),
            project("notes-app", branch: "fix/slow-search", health: "red", hoursAgo: 3,
                    pullRequests: [["number": 57, "title": "Index notes for search",
                                    "url": "https://github.com/example/notes-app/pull/57", "isDraft": false, "ci": "fail"]],
                    attention: [["level": "high", "text": "CI failed on #57"]],
                    stage: "1.4: search", next: ["Fix the failing test", "Release 1.4"]),
            project("landing", branch: "main", health: "green", hoursAgo: 26,
                    pullRequests: [["number": 42, "title": "Tests for the contact form",
                                    "url": "https://github.com/example/landing/pull/42", "isDraft": false, "ci": "ok"]],
                    stage: "Live", next: ["FAQ section"]),
        ]
        let object: [String: Any] = ["version": 1, "generated": iso(0), "projects": projects]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ProjectsReport.self, from: data)
    }

    /// The same «random» numbers on every start, so two takes of one recording match.
    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next(_ range: ClosedRange<Int>) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return range.lowerBound + Int((state >> 33) % UInt64(range.count))
        }
    }
}
