import Foundation
import Testing
@testable import ClaudePult

struct ServiceTabTests {
    private func freshDefaults() -> UserDefaults {
        let name = "claudepult-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func everyServiceHasOneTab() {
        #expect(ServiceTab.allCases.flatMap(\.agents).sorted { $0.rawValue < $1.rawValue } == AgentKind.allCases.sorted { $0.rawValue < $1.rawValue })
        #expect(Set(ServiceTab.allCases.flatMap(\.providers)) == Set(APIProvider.allCases))
        #expect(Set(ServiceTab.allCases.flatMap(\.hubSources)) == Set(HubLimit.Source.allCases))
        #expect(ServiceTab.claude.agents == [.claudeCode])
        #expect(ServiceTab.claude.providers == [.anthropic])
        #expect(ServiceTab.codex.hubSources == [.codex, .openAICosts])
        #expect(ServiceTab.gemini.agents == [.gemini, .antigravity])
    }

    @Test func oldClaudeTabOpensServicesClaudeCode() {
        let defaults = freshDefaults()
        defaults.set("claude", forKey: SettingsRoute.tabKey)
        defaults.set("codex", forKey: SettingsRoute.serviceKey)
        SettingsRoute.migrate(defaults)
        #expect(defaults.string(forKey: SettingsRoute.tabKey) == SettingsView.Tab.services.rawValue)
        #expect(defaults.string(forKey: SettingsRoute.serviceKey) == ServiceTab.claude.rawValue)
        #expect(SettingsView.Tab(rawValue: "claude") == nil)
    }

    @Test func otherTabsAreLeftAlone() {
        let defaults = freshDefaults()
        defaults.set("appearance", forKey: SettingsRoute.tabKey)
        defaults.set("gemini", forKey: SettingsRoute.serviceKey)
        SettingsRoute.migrate(defaults)
        #expect(defaults.string(forKey: SettingsRoute.tabKey) == "appearance")
        #expect(defaults.string(forKey: SettingsRoute.serviceKey) == "gemini")

        SettingsRoute.open(service: .copilot, defaults: defaults)
        #expect(defaults.string(forKey: SettingsRoute.tabKey) == "services")
        #expect(defaults.string(forKey: SettingsRoute.serviceKey) == "copilot")
    }
}
