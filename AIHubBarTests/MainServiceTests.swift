import Foundation
import Testing
@testable import AIHubBar

/// Which service leads the panel, the menu bar item and the island (`MainService`): Claude as before, another
/// service for whoever has no Claude or chose one.
struct MainServiceTests {
    private let now = Date(timeIntervalSince1970: 1_794_400_000)

    private var claude: ServiceUsage {
        let answer = #"{"five_hour":{"utilization":42,"resets_at":"2026-11-12T15:00:00Z"},"seven_day":{"utilization":18,"resets_at":"2026-11-16T09:00:00Z"}}"#
        return ServiceUsage.claude(UsageSnapshot.decode(Data(answer.utf8), fetchedAt: now)!, forecast: .unknown, week: nil, error: nil)
    }

    private func other(_ source: HubLimit.Source, _ percents: [Double?]) -> ServiceUsage {
        let windows = percents.enumerated().map { HubLimit.Window(title: "w\($0.offset)", percent: $0.element, detail: nil, resetsAt: nil) }
        return ServiceUsage.hub(HubLimit(source: source, windows: windows), history: LimitHistory(), now: now)
    }

    @Test func claudeLeadsWhileItHasLimits() {
        let codex = other(.codex, [30, 60])
        #expect(MainService.pick(choice: MainService.auto, claude: claude, others: [codex])?.service == .claude)
        #expect(MainService.pick(choice: MainService.claude, claude: claude, others: [codex])?.service == .claude)
    }

    @Test func withoutClaudeTheFirstServiceWithLimitsLeads() {
        // Spend alone (no percent) is not a limit to lead with.
        let spend = other(.openRouter, [nil])
        let codex = other(.codex, [30, 60])
        let main = MainService.pick(choice: MainService.auto, claude: nil, others: [spend, codex])
        #expect(main?.service == .hub(.codex))
        #expect(main?.firstLimit?.percent == 30)
        #expect(main?.secondLimit?.percent == 60)
        #expect(MainService.pick(choice: MainService.auto, claude: nil, others: [spend]) == nil)
        // Asking for Claude when it has nothing still shows what there is.
        #expect(MainService.pick(choice: MainService.claude, claude: nil, others: [codex])?.service == .hub(.codex))
    }

    @Test func aChosenServiceLeadsOverClaude() {
        let codex = other(.codex, [30, 60])
        let antigravity = other(.antigravity, [25])
        let main = MainService.pick(choice: HubLimit.Source.antigravity.rawValue, claude: claude, others: [codex, antigravity])
        #expect(main?.service == .hub(.antigravity))
        #expect(main?.secondLimit == nil, "one limit: the second number stays empty")
        // The chosen one has nothing now: back to the automatic choice, not to blank numbers.
        #expect(MainService.pick(choice: HubLimit.Source.copilot.rawValue, claude: claude, others: [codex])?.service == .claude)
        #expect(MainService.pick(choice: "no-such-service", claude: nil, others: [codex])?.service == .hub(.codex))
    }

    @Test func theSettingOffersServicesWithLimitsAndKeepsTheSavedOne() {
        let others = [other(.openRouter, [nil]), other(.codex, [30])]
        #expect(MainService.choices(saved: MainService.auto, others: others) == [.codex])
        #expect(MainService.choices(saved: HubLimit.Source.copilot.rawValue, others: others) == [.codex, .copilot],
                "a saved choice stays in the list while its service is away")
        #expect(MainService.choices(saved: HubLimit.Source.codex.rawValue, others: others) == [.codex])
    }

    @Test func theIslandNamesAnotherServicesLimit() {
        let codex = other(.codex, [30, 60])
        #expect(NotchText.earSummary(.sessionLimit, main: codex, sessions: [], background: 0) == "Codex · w0: \(UsageText.percent(30))")
        #expect(NotchText.earSummary(.weekLimit, main: other(.codex, [30]), sessions: [], background: 0) == NotchEar.weekLimit.title)
        let session = NotchText.earSummary(.sessionLimit, main: claude, sessions: [], background: 0)
        #expect(session.hasSuffix(UsageText.percent(42)) && !session.contains("Claude"), "Claude's own limits are named as before")
    }
}
