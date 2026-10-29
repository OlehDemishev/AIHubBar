import Foundation
import SwiftUI
import Testing
@testable import ClaudePult

@MainActor
struct AppearanceTests {
    private func freshDefaults() -> UserDefaults {
        let name = "claudepult-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsAndPersistence() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.panelTextSize == .normal)
        #expect(settings.panelWidth == .normal)
        #expect(settings.panelTheme == .system)
        #expect(settings.panelAnimations)
        #expect(PanelBlock.allCases.allSatisfy(settings.shows))

        settings.panelTextSize = .extraLarge
        settings.panelDensity = .compact
        settings.panelTheme = .dark
        settings.setShows(.commands, false)
        settings.panelAnimations = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.panelTextSize == .extraLarge)
        #expect(reloaded.panelDensity == .compact)
        #expect(reloaded.panelTheme == .dark)
        #expect(!reloaded.shows(.commands))
        #expect(reloaded.shows(.limits))
        #expect(!reloaded.panelAnimations)

        reloaded.resetAppearance()
        #expect(reloaded.panelTextSize == .normal)
        #expect(reloaded.hiddenBlocks.isEmpty)
        #expect(AppSettings(defaults: defaults).panelTheme == .system)
    }

    @Test func unknownStoredValuesFallBack() {
        let defaults = freshDefaults()
        defaults.set("gigantic", forKey: "panelTextSize")
        defaults.set(["limits", "nonsense"], forKey: "hiddenBlocks")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.panelTextSize == .normal)
        #expect(settings.hiddenBlocks == [.limits])
    }

    @Test func scales() {
        #expect(PanelTextSize.allCases.map(\.scale) == [0.9, 1, 1.15, 1.3])
        #expect(ScaledFont.baseSize(.caption) == 10)
        #expect(ScaledFont.baseSize(.body) == 13)
        #expect(PanelWidth.wide.points > PanelWidth.normal.points)
        #expect(PanelTheme.system.colorScheme == nil)
        #expect(PanelTheme.dark.colorScheme == .dark)
    }
}
