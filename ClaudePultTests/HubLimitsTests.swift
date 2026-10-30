import Foundation
import Testing
@testable import ClaudePult

/// The other services' answers, from anonymised samples of the formats in docs/SPEC-hub.md.
struct HubLimitsTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func codexAppServer() throws {
        let answer = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":42.5,"windowDurationMins":300,"resetsAt":1793000000},\
        "secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1793500000}}}}
        """
        let windows = try #require(HubParse.codexRPC(data(answer)))
        #expect(windows.count == 2)
        #expect(windows[0].percent == 42.5)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_793_000_000))
        #expect(windows[1].title == HubParse.windowTitle(minutes: 10080))
    }

    @Test func codexSessionLineWithSecondsToReset() throws {
        let line = """
        {"timestamp":"2026-10-30T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,\
        "rate_limits":{"primary":{"used_percent":80,"window_minutes":300,"resets_in_seconds":3600},\
        "secondary":{"used_percent":30,"window_minutes":10080,"resets_at":1793500000}}}}
        """
        let windows = try #require(HubParse.codexSessionLine(data(line)))
        #expect(windows[0].percent == 80)
        #expect(windows[0].resetsAt == ISODate.parse("2026-10-30T11:00:00.000Z"))
        #expect(windows[1].resetsAt == Date(timeIntervalSince1970: 1_793_500_000))
        #expect(HubParse.codexSessionLine(data(#"{"type":"event_msg","payload":{"type":"agent_message"}}"#)) == nil)
    }

    @Test func openRouterKey() throws {
        let answer = #"{"data":{"label":"sk-or-v1-abc","limit":20,"limit_remaining":15,"usage":7.5,"usage_monthly":5}}"#
        let windows = try #require(HubParse.openRouter(data(answer)))
        #expect(windows[0].percent == 25)
        #expect(windows[1].percent == nil)
        #expect(windows[1].detail == HubParse.money(5))
        // No credit limit on the key: only the spend.
        let unlimited = try #require(HubParse.openRouter(data(#"{"data":{"limit":null,"usage":3}}"#)))
        #expect(unlimited.count == 1 && unlimited[0].percent == nil)
    }

    @Test func copilotPremiumRequests() throws {
        let answer = """
        {"copilot_plan":"individual","quota_reset_date":"2026-11-01","quota_snapshots":{\
        "chat":{"entitlement":0,"remaining":0,"unlimited":true},\
        "completions":{"entitlement":0,"remaining":0,"unlimited":true},\
        "premium_interactions":{"entitlement":300,"remaining":225,"unlimited":false,"overage_count":0}}}
        """
        let windows = try #require(HubParse.copilot(data(answer)))
        #expect(windows.count == 1)
        #expect(windows[0].percent == 25)
        #expect(windows[0].resetsAt != nil)
    }

    /// The free plan as gh returned it: no premium requests at all, chat and completions with a monthly allowance.
    @Test func copilotFreePlan() throws {
        let answer = """
        {"access_type_sku":"free_limited_copilot","quota_reset_date":"2026-11-01","quota_reset_date_utc":"2026-11-01T00:00:00.000Z",        "quota_snapshots":{"chat":{"entitlement":200,"remaining":150,"unlimited":false,"quota_reset_at":0},        "completions":{"entitlement":2000,"remaining":2000,"unlimited":false},        "premium_interactions":{"entitlement":0,"remaining":0,"unlimited":false,"has_quota":false}}}
        """
        let windows = try #require(HubParse.copilot(data(answer)))
        #expect(windows.map(\.percent) == [25, 0])
        #expect(windows[0].resetsAt == ISODate.parse("2026-11-01T00:00:00.000Z"))
    }

    @Test func geminiQuotaAndLogs() throws {
        let answer = #"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.4,"resetTime":"2026-10-31T07:00:00Z"}]}"#
        let windows = try #require(HubParse.geminiQuota(data(answer)))
        #expect(abs((windows[0].percent ?? 0) - 60) < 0.001)
        #expect(windows[0].title == "2.5-pro")

        let start = try #require(ISODate.parse("2026-10-30T07:00:00Z"))
        let session = """
        {"messages":[{"type":"user","timestamp":"2026-10-30T08:00:00Z"},{"type":"gemini","timestamp":"2026-10-30T08:00:05Z"},\
        {"type":"user","timestamp":"2026-10-30T09:00:00Z"},{"type":"user","timestamp":"2026-10-29T09:00:00Z"}]}
        """
        #expect(HubParse.geminiUserTurns(data(session), since: start) == 2)
        let window = HubParse.geminiRequests(today: 250, dailyLimit: 1000, now: start.addingTimeInterval(3600))
        #expect(window.percent == 25)
        #expect(window.resetsAt == ISODate.parse("2026-10-31T07:00:00Z"))
    }

    @Test func apiCosts() throws {
        let openAI = """
        {"object":"page","data":[{"results":[{"amount":{"value":1.25,"currency":"usd"}}]},\
        {"results":[{"amount":{"value":2.5,"currency":"usd"}},{"amount":{"value":0.25,"currency":"usd"}}]}]}
        """
        #expect(try #require(HubParse.openAICosts(data(openAI)))[0].detail == HubParse.money(4))
        let anthropic = #"{"data":[{"results":[{"amount":"150.5","currency":"USD"}]},{"results":[{"amount":"49.5","currency":"USD"}]}]}"#
        #expect(try #require(HubParse.anthropicCosts(data(anthropic)))[0].detail == HubParse.money(2))
        #expect(HubParse.openAICosts(data(#"{"error":{"message":"bad key"}}"#)) == nil)
    }

    @Test func cursorPeriod() throws {
        let answer = #"{"billingCycleEnd":"1793000000000","planUsage":{"totalSpend":1250,"limit":2000,"totalPercentUsed":62.5}}"#
        let window = try #require(HubParse.cursor(data(answer))?.first)
        #expect(window.percent == 62.5)
        #expect(window.detail == "\(HubParse.money(12.5)) из \(HubParse.money(20))" || window.detail?.contains(HubParse.money(12.5)) == true)
        #expect(window.resetsAt == Date(timeIntervalSince1970: 1_793_000_000))
    }

    @Test func windowTitles() {
        #expect(HubParse.windowTitle(minutes: 300) == String(localized: "\(5) ч"))
        #expect(HubParse.windowTitle(minutes: 10080) == String(localized: "неделя"))
    }

    @MainActor @Test func switchedOffAndConsent() {
        let defaults = UserDefaults(suiteName: "hub-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.hubEnabled(.codex))
        #expect(!settings.hubEnabled(.cursor), "Cursor waits for consent")
        settings.hubCursor = true
        #expect(settings.hubEnabled(.cursor))
        settings.setHubEnabled(.codex, false)
        #expect(!AppSettings(defaults: defaults).hubEnabled(.codex))
        #expect(settings.hubGeminiDailyLimit == 1000)
    }

    @Test func forecastOnlyWhenItRunsOutBeforeTheReset() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = HubForecast.Reading(at: start, percent: 20)
        let latest = HubForecast.Reading(at: start.addingTimeInterval(3600), percent: 40)
        // 20 % an hour from 40 %: out in 3 hours.
        #expect(HubForecast.runsOut(first: first, latest: latest, resetsAt: start.addingTimeInterval(10 * 3600)) == start.addingTimeInterval(4 * 3600))
        #expect(HubForecast.runsOut(first: first, latest: latest, resetsAt: start.addingTimeInterval(2 * 3600)) == nil)
        #expect(HubForecast.runsOut(first: first, latest: HubForecast.Reading(at: start.addingTimeInterval(600), percent: 30), resetsAt: nil) == nil)
        #expect(HubForecast.runsOut(first: first, latest: HubForecast.Reading(at: start.addingTimeInterval(3600), percent: 20), resetsAt: nil) == nil)
    }

    @Test func menuBarShowsTheFullestOrTheChosenService() {
        var config = MenuBarConfig.make(.minimum)
        config.set(.otherAI) { $0.enabled = true }
        var data = MenuBarData()
        data.otherAI = ["codex": 42, "copilot": 70]
        #expect(MenuBarComposer.groups(config, data).contains([.text("Copilot 70%", .level(70))]))
        config.set(.otherAI) { $0.model = "codex" }
        #expect(MenuBarComposer.groups(config, data).contains([.text("Codex 42%", .level(42))]))
        // The chosen one has no limit now: nothing, not another service.
        config.set(.otherAI) { $0.model = "gemini" }
        #expect(!MenuBarComposer.groups(config, data).contains { $0.contains { if case .text = $0 { true } else { false } } })
        #expect(MenuBarComposer.accessibilityText(config, data) == "AI Hub Bar")
    }
}
