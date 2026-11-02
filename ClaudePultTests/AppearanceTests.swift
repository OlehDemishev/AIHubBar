import AppKit
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
        #expect(settings.panelBackground == .standard)
        #expect(PanelBlock.allCases.allSatisfy(settings.shows))

        settings.panelTextSize = .extraLarge
        settings.panelDensity = .compact
        settings.panelTheme = .dark
        settings.setShows(.commands, false)
        settings.panelAnimations = false
        settings.panelBackground = .glass

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.panelTextSize == .extraLarge)
        #expect(reloaded.panelDensity == .compact)
        #expect(reloaded.panelTheme == .dark)
        #expect(!reloaded.shows(.commands))
        #expect(reloaded.shows(.limits))
        #expect(!reloaded.panelAnimations)
        #expect(reloaded.panelBackground == .glass)

        reloaded.resetAppearance()
        #expect(reloaded.panelTextSize == .normal)
        #expect(reloaded.hiddenBlocks.isEmpty)
        #expect(AppSettings(defaults: defaults).panelTheme == .system)
        #expect(AppSettings(defaults: defaults).panelBackground == .standard)
    }

    @Test func unknownStoredValuesFallBack() {
        let defaults = freshDefaults()
        defaults.set("gigantic", forKey: "panelTextSize")
        defaults.set(["limits", "nonsense"], forKey: "hiddenBlocks")
        defaults.set("frosted", forKey: "panelBackground")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.panelTextSize == .normal)
        #expect(settings.panelBackground == .standard)
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

/// `PanelGlass` on stand-in windows: the real `MenuBarExtra` window can't be opened from a test.
@MainActor
struct PanelGlassTests {
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: true)
    }

    @Test func hidesMaterialBehindContentAndRestores() throws {
        let window = window()
        let content = try #require(window.contentView)
        let frame = try #require(content.superview)
        let material = NSVisualEffectView(frame: frame.bounds)
        material.wantsLayer = true
        material.layer?.cornerRadius = 18
        frame.addSubview(material, positioned: .below, relativeTo: content)

        #expect(PanelGlass.apply(true, to: window) == 18)
        #expect(material.isHidden)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)

        material.isHidden = false
        #expect(PanelGlass.apply(true, to: window) == 18, "applied again on reopen")
        #expect(material.isHidden)

        #expect(PanelGlass.apply(false, to: window) == nil)
        #expect(!material.isHidden)
        #expect(window.isOpaque)
    }

    @Test func materialAroundContentHidesOnlyItsOwnLayers() throws {
        let window = window()
        let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        material.wantsLayer = true
        let content = NSView(frame: material.bounds)
        content.wantsLayer = true
        material.addSubview(content)
        window.contentView = material
        let own = CALayer()
        material.layer?.insertSublayer(own, at: 0)

        #expect(PanelGlass.apply(true, to: window) == PanelGlass.defaultCornerRadius)
        #expect(own.isHidden)
        #expect(content.layer?.isHidden == false)
        #expect(!material.isHidden)
        PanelGlass.restore()
        #expect(!own.isHidden)
    }

    @Test func unknownWindowKeepsItsBackground() {
        let window = window()
        let opaque = window.isOpaque
        #expect(PanelGlass.apply(true, to: window) == nil)
        #expect(window.isOpaque == opaque)
        #expect(PanelGlass.apply(true, to: nil) == nil)
    }

    @Test func reduceTransparencyMeansStandard() {
        #expect(!PanelGlass.isAvailable(reduceTransparency: true))
    }
}

struct CollapsedBlocksTests {
    @Test func togglesAndKeepsOrder() {
        var raw = ""
        raw = PanelBlock.toggling(.projects, in: raw)
        raw = PanelBlock.toggling(.limits, in: raw)
        #expect(raw == "limits,projects", "stored in the panel's order")
        #expect(PanelBlock.collapsed(in: raw) == [.limits, .projects])
        raw = PanelBlock.toggling(.limits, in: raw)
        #expect(PanelBlock.collapsed(in: raw) == [.projects])
        #expect(PanelBlock.collapsed(in: "projects,unknown,,") == [.projects], "unknown names are ignored")
    }
}
