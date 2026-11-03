import Foundation
import Testing
@testable import AIHubBar

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

    /// A page saved in the new key is left alone by the migration; opening a service writes its page.
    @Test func newPageKeyIsLeftAlone() {
        let defaults = freshDefaults()
        defaults.set("module.notes", forKey: StorageKey.settingsPage)
        defaults.set("services", forKey: "settingsTab")
        SettingsRoute.migrate(defaults)
        #expect(defaults.string(forKey: StorageKey.settingsPage) == "module.notes")
        SettingsRoute.open(service: .copilot, defaults: defaults)
        #expect(defaults.string(forKey: StorageKey.settingsPage) == "service.copilot")
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

    /// SPEC-refactor §5: one key holds the whole page.
    @Test func paneRawValueRoundTrip() {
        for pane in SettingsPane.areas + SettingsPane.services + modulePanes {
            #expect(SettingsPane(rawValue: pane.rawValue) == pane, "\(pane.rawValue)")
        }
        #expect(SettingsPane.module(.limits).rawValue == "module.limits")
        #expect(SettingsPane.service(.gemini).rawValue == "service.gemini")
        #expect(SettingsPane(rawValue: "module.nonsense") == nil && SettingsPane(rawValue: "") == nil)
    }

    /// The three keys from before (`settingsTab` + `servicesTab` / `settingsModule`, and the older «claude») still
    /// open the page they named, once.
    @Test func oldPageKeysMigrate() throws {
        let cases: [([String: String], SettingsPane)] = [
            (["settingsTab": "services", "servicesTab": "gemini"], .service(.gemini)),
            (["settingsTab": "module", "settingsModule": "notes"], .module(.notes)),
            (["settingsTab": "claude"], .service(.claude)),
            (["settingsTab": "menuBar"], .menuBar),
        ]
        for (old, pane) in cases {
            let name = "claudepult-route-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            for (key, value) in old { defaults.set(value, forKey: key) }
            SettingsRoute.migrate(defaults)
            #expect(defaults.string(forKey: StorageKey.settingsPage) == pane.rawValue)
            #expect(defaults.string(forKey: "settingsTab") == nil, "old keys go")
        }
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
