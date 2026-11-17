import Foundation
import Testing
@testable import AIHubBar

/// «Итог дня» (`DaySummary`): the window's lines and the Telegram message.
struct DaySummaryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func run(_ id: String, _ state: BackgroundRun.State, at: Date, agent: String? = nil, reviewOf: String? = nil) -> BackgroundRun {
        BackgroundRun(
            id: id, project: "Ambo", projectPath: "/P/Ambo", folder: "/P/Ambo", worktreeBranch: nil, commandTitle: "Своя задача",
            task: "Task <\(id)>", startedAt: at, timeLimitMinutes: 90, pid: 1, state: state, notified: false, agent: agent, reviewOf: reviewOf
        )
    }

    @Test func theDayIsItsRunsSinceMidnight() {
        let now = date(17, 20)
        let runs = [run("a", .succeeded, at: date(17, 9)), run("b", .failed, at: date(16, 23)), run("r", .succeeded, at: date(17, 10), reviewOf: "a")]
        #expect(DaySummary.today(runs, now: now, calendar: calendar).map(\.id) == ["a"], "yesterday's run and a review are left out")
    }

    @Test func linesAndTelegram() {
        let breakdown = TokenBreakdown(projects: [.init(name: "Ambo", tokens: 1_200_000, share: 0.75), .init(name: "Site", tokens: 400_000, share: 0.25)],
                                       topSession: nil, totalTokens: 1_600_000)
        let input = DaySummary.Input(
            sessionPercent: 42, weekPercent: 18, breakdown: breakdown, hits: 1,
            runs: [run("a", .succeeded, at: date(17, 9)), run("b", .failed, at: date(17, 10), agent: CodexExec.agent)]
        )
        let lines = DaySummary.lines(input)
        #expect(lines.first?.text.hasPrefix("Claude — ") == true)
        #expect(lines.contains { $0.text == "• Ambo — 75 % (\(TokenBreakdown.tokensText(1_200_000)))" })
        #expect(lines.contains { $0.text == "✅ Ambo: Task <a>" })
        #expect(lines.contains { $0.text == "❌ Ambo · \(AgentKind.codex.title): Task <b>" }, "another service's run names it")
        #expect(lines.filter(\.isHeading).count == 2)

        let html = DaySummary.html(input)
        #expect(html.contains("Task &lt;a&gt;"), "a task's text is escaped")
        #expect(!DaySummary.isEmpty(input))
        #expect(DaySummary.isEmpty(.init(sessionPercent: 42, weekPercent: 18, breakdown: nil, hits: 0, runs: [])), "limits alone are not a day's work")
    }

    @Test func theDayHasItsCostWhenThePriceIsKnown() {
        var input = DaySummary.Input(sessionPercent: nil, weekPercent: nil, breakdown: nil, hits: 0, runs: [], cost: 4.2)
        #expect(DaySummary.lines(input).count == 1)
        input.cost = 0.001
        #expect(DaySummary.lines(input).isEmpty, "a cent or less is not worth a line")
        input.cost = nil
        #expect(DaySummary.lines(input).isEmpty)
    }

    /// «Окупается ли подписка» (`SubscriptionValue`).
    @Test func thePlanAgainstTheAPI() throws {
        #expect(SubscriptionValue.monthly(cost: 70, periodDays: 7) == 300)
        #expect(SubscriptionValue.monthly(cost: 70, periodDays: 0) == 0)
        let pays = try #require(SubscriptionValue.ratio(monthlyCost: 300, plan: 100))
        #expect(pays == 3)
        #expect(SubscriptionValue.ratio(monthlyCost: 300, plan: 0) == nil, "the plan's price is not said")
        #expect(SubscriptionValue.ratio(monthlyCost: 0, plan: 100) == nil)
        #expect(SubscriptionValue.verdict(3) != SubscriptionValue.verdict(1.0 / 3), "which side is cheaper is said")
        // A week of 12 M input and 1 M output tokens at 3 / 15 dollars per million.
        let day = UsageDay(day: "2026-11-17", input: 12_000_000, output: 1_000_000)
        #expect(day.cost(APIPrice(input: 3, output: 15)) == 51)
    }

    @Test func sentOnceADayAtItsHour() {
        #expect(DaySummary.due(hour: 21, now: date(17, 22), calendar: calendar) == date(17, 21))
        #expect(DaySummary.due(hour: 21, now: date(17, 20), calendar: calendar) == date(16, 21), "before the hour: yesterday's")
    }
}
