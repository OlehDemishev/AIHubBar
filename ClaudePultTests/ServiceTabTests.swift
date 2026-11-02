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
    private var modulePanes: [SettingsPane] { ModuleKind.allCases.map(SettingsPane.module) }

    @Test func paneAndStoredTabRoundTrip() {
        for pane in SettingsPane.areas + SettingsPane.services + modulePanes {
            let service: ServiceTab = if case let .service(chosen) = pane { chosen } else { .claude }
            let module: ModuleKind = if case let .module(chosen) = pane { chosen } else { .limits }
            #expect(SettingsPane(tab: pane.tab, service: service, module: module) == pane)
        }
        #expect(SettingsPane(tab: .services, service: .gemini, module: .notes) == .service(.gemini))
        #expect(SettingsPane(tab: .module, service: .gemini, module: .notes) == .module(.notes))
        #expect(SettingsPane(tab: .appearance, service: .gemini, module: .notes) == .appearance, "the service and module matter only on their pages")
    }

    @Test func searchFindsByTitleAndSettingNames() {
        let all = SettingsPane.areas + SettingsPane.services + modulePanes
        #expect(all.allSatisfy { $0.matches("") && $0.matches("  ") })
        let codex = all.filter { $0.matches("codex") }
        #expect(codex.contains(.service(.codex)) && !codex.contains(.service(.claude)))
        let telegram = all.filter { $0.matches("telegram") }
        #expect(telegram.contains(.general) && telegram.contains(.module(.sessions)))
        #expect(all.filter { $0.matches("zzz-nothing") }.isEmpty)
    }

    /// «Бета-версии» is found in General, «Раскладка»'s switches on its own page.
    @Test func searchFindsBetaAndTheLayoutModule() {
        #expect(SettingsPane.general.matches("бета"))
        #expect(SettingsPane.module(.layout).matches("Раскладка"))
        #expect(SettingsPane.module(.layout).matches("Shift"))
    }

    /// Every module sits in exactly one sidebar section.
    @Test func everyModuleHasOneSection() {
        let listed = ModuleGroup.allCases.flatMap(\.modules)
        #expect(listed.count == ModuleKind.allCases.count)
        #expect(Set(listed) == Set(ModuleKind.allCases))
        #expect(listed.allSatisfy { kind in ModuleGroup.allCases.first { $0.modules.contains(kind) } == kind.group })
    }
}
