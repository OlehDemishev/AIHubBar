import Foundation
import Testing
@testable import AIHubBar

/// SPEC-ai-services stage 4: thresholds per service, the other-AI notch ear, other services in the weekly summary.
@MainActor
struct PerServiceTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func thresholdsPerService() {
        let defaults = UserDefaults(suiteName: "thresholds-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.limitThresholds = [50, 80]
        #expect(settings.thresholds(for: .codex) == [50, 80], "common by default")
        settings.serviceThresholds["codex"] = [90]
        settings.serviceThresholds["copilot"] = []
        #expect(settings.thresholds(for: .codex) == [90])
        #expect(settings.thresholds(for: .copilot).isEmpty, "off")
        #expect(settings.thresholds(for: .claude) == [50, 80])

        defaults.set(["gemini": [120, 70, 0, 30]], forKey: "serviceThresholds")
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.thresholds(for: .gemini) == [30, 70], "out-of-range values dropped, sorted")
        #expect(reloaded.thresholds(for: .codex) == reloaded.limitThresholds, "the stored dictionary replaced the old one")
    }

    @Test func otherAIEar() {
        #expect(NotchText.fullestOther([:]) == nil)
        let fullest = NotchText.fullestOther(["codex": 40, "copilot": 70, "gemini": 70])
        #expect(fullest?.name == "Copilot" && fullest?.percent == 70, "ties go to the first name")
        #expect(NotchText.earSummary(.otherAI, usage: nil, sessions: [], background: 0, otherAI: ["codex": 12]) == "Codex: 12 %")
        #expect(NotchText.earSummary(.otherAI, usage: nil, sessions: [], background: 0) == NotchEar.otherAI.title)
        #expect(NotchEar(rawValue: "otherAI") == .otherAI)
    }

    @Test func otherServicesInWeeklySummary() {
        var codex = ServiceUsage.hub(HubLimit(source: .codex, windows: [
            HubLimit.Window(title: "5 ч", percent: 12),
            HubLimit.Window(title: "неделя", percent: 30),
        ]), history: LimitHistory(), now: now)
        codex.week = WeekUsage(days: [WeekUsage.Day(date: now, percent: 18, isToday: true)], forecast: .unknown)
        codex.projects = [ProjectTokens(path: "/p/Alpha", name: "Alpha", tokens: 1_200_000)]
        let line = WeeklySummary.otherLine(codex)
        #expect(line?.hasPrefix("Codex — ") == true)
        #expect(line?.contains("5 ч 12 %") == true && line?.contains("неделя 30 %") == true)
        #expect(line?.contains("18 %") == true && line?.contains("Alpha") == true)

        let broken = ServiceUsage.hub(HubLimit(source: .cursor, windows: [], error: "нет входа"), history: LimitHistory(), now: now)
        #expect(WeeklySummary.otherLine(broken) == "Cursor — нет входа")
        let empty = ServiceUsage.hub(HubLimit(source: .gemini, windows: []), history: LimitHistory(), now: now)
        #expect(WeeklySummary.otherLine(empty) == nil)

        let input = WeeklySummary.Input(weekPercent: 40, weekResetsAt: nil, breakdown: nil, sessionHits: 0, weekHits: 0,
                                        runs: [], others: [codex, empty], now: now)
        let html = WeeklySummary.html(input)
        #expect(html.contains("<b>\(String(localized: "Другие AI"))</b>"))
        #expect(html.contains("• Codex — "))
        #expect(!html.contains("Gemini"), "a service with nothing to say is left out")
        #expect(!WeeklySummary.html(WeeklySummary.Input(weekPercent: 40, weekResetsAt: nil, breakdown: nil, sessionHits: 0,
                                                        weekHits: 0, runs: [], now: now)).contains(String(localized: "Другие AI")))
    }
}
