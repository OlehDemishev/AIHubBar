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

    @Test func setUpWhenAnythingOfTheServiceWorks() {
        #expect(!ServiceTab.codex.isSetUp(agents: [], keys: [], limits: []))
        #expect(ServiceTab.codex.isSetUp(agents: [.codex], keys: [], limits: []))
        #expect(ServiceTab.codex.isSetUp(agents: [], keys: [.openai], limits: []))
        #expect(ServiceTab.codex.isSetUp(agents: [], keys: [], limits: [.openAICosts]))
        #expect(!ServiceTab.codex.isSetUp(agents: [.claudeCode], keys: [.anthropic], limits: [.gemini]), "another service's parts")
        #expect(ServiceTab.other.isSetUp(agents: [], keys: [.mistral], limits: []))
        #expect(Set(ServiceTab.allCases.map(\.icon)).count == ServiceTab.allCases.count)
    }
}

struct SettingsPaneTests {
    @Test func paneAndStoredTabRoundTrip() {
        for pane in SettingsPane.areas + SettingsPane.services {
            let service: ServiceTab = if case let .service(chosen) = pane { chosen } else { .claude }
            #expect(SettingsPane(tab: pane.tab, service: service) == pane)
        }
        #expect(SettingsPane(tab: .services, service: .gemini) == .service(.gemini))
        #expect(SettingsPane(tab: .appearance, service: .gemini) == .appearance, "the service matters only under «Сервисы AI»")
    }

    @Test func searchFindsByTitleAndSettingNames() {
        let all = SettingsPane.areas + SettingsPane.services
        #expect(all.allSatisfy { $0.matches("") && $0.matches("  ") })
        let codex = all.filter { $0.matches("codex") }
        #expect(codex.contains(.service(.codex)) && !codex.contains(.service(.claude)))
        let telegram = all.filter { $0.matches("telegram") }
        #expect(telegram.contains(.general) && telegram.contains(.service(.claude)))
        #expect(all.filter { $0.matches("zzz-nothing") }.isEmpty)
        #expect(Set(all.map(\.subtitle)).count == all.count - 1, "Copilot and Cursor share «Агент и лимиты»")
    }

    /// «Бета-версии» is found in General; «Раскладка» only once beta builds show it in Modules.
    @MainActor
    @Test func searchFindsBetaAndTheLayoutModule() {
        let saved = UserDefaults.standard.object(forKey: "betaUpdates")
        defer { UserDefaults.standard.set(saved, forKey: "betaUpdates") }
        #expect(SettingsPane.general.matches("бета"))
        UserDefaults.standard.set(false, forKey: "betaUpdates")
        #expect(!SettingsPane.modules.matches("Раскладка"))
        UserDefaults.standard.set(true, forKey: "betaUpdates")
        #expect(SettingsPane.modules.matches("Раскладка"))
        #expect(SettingsPane.modules.matches("Shift"))
    }
}
