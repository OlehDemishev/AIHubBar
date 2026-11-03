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
        #expect(!reloaded.shows(.commands), "the look's reset leaves old block flags alone: profiles decide the panel")
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

/// `PanelGlass` on a stand-in of the `MenuBarExtra` window seen on macOS 27: the hosting view holds a full-size
/// `CABackdropLayer` (the system background) next to the portal SwiftUI draws the content through.
@MainActor
struct PanelGlassTests {
    private func standIn() throws -> (NSWindow, holder: CALayer, backdrop: CALayer, card: CALayer) {
        let backdropType = try #require(NSClassFromString("CABackdropLayer") as? CALayer.Type)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        let hosting = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        window.contentView = hosting
        let graphics = NSView(frame: hosting.bounds)
        graphics.wantsLayer = true
        hosting.addSubview(graphics)
        let holder = CALayer(), backdrop = backdropType.init(), card = backdropType.init()
        holder.frame = hosting.bounds
        backdrop.frame = hosting.bounds
        backdrop.cornerRadius = 18
        card.frame = NSRect(x: 8, y: 8, width: 384, height: 120)
        holder.addSublayer(backdrop)
        holder.addSublayer(CALayer())
        holder.addSublayer(card)
        graphics.layer?.addSublayer(holder)
        return (window, holder, backdrop, card)
    }

    @Test func hidesSystemBackdropAndRestores() throws {
        guard #available(macOS 26.0, *) else { return }
        let (window, holder, backdrop, card) = try standIn()
        defer { PanelGlass.restore() }
        #expect(PanelGlass.apply(true, to: window))
        #expect(backdrop.isHidden, "the system background")
        #expect(!holder.isHidden, "the holder also carries the content's portal")
        #expect(!card.isHidden, "a card's glass is not the window's")
        let glass = try #require(window.contentView?.superview?.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .clear && glass.cornerRadius == 18)
        #expect(PanelGlass.apply(true, to: window), "applied again on reopen")
        #expect(window.contentView?.superview?.subviews.filter { $0 is NSGlassEffectView }.count == 1)

        #expect(!PanelGlass.apply(false, to: window))
        #expect(!backdrop.isHidden)
        #expect(window.contentView?.superview?.subviews.contains { $0 is NSGlassEffectView } == false)
    }

    @Test func unknownWindowKeepsItsBackground() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(!PanelGlass.apply(true, to: window))
        #expect(window.contentView?.superview?.subviews.contains { $0.className.contains("Glass") } != true)
        #expect(!PanelGlass.apply(true, to: nil))
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

/// SPEC-refactor §6: one way to read each kind of setting, the stored meaning unchanged.
@MainActor
struct SettingsStorageTests {
    @Test func zeroMeansWhatItMeantBefore() throws {
        let name = "claudepult-storage-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.nightStartHour == 1 && fresh.backgroundTimeLimitMinutes == 90 && fresh.telegramForBackground)

        // Midnight is a real hour; a time limit of 0 is «not set».
        defaults.set(0, forKey: "nightStartHour")
        defaults.set(0, forKey: "backgroundTimeLimitMinutes")
        defaults.set(false, forKey: "telegramForBackground")
        let read = AppSettings(defaults: defaults)
        #expect(read.nightStartHour == 0 && read.backgroundTimeLimitMinutes == 90 && !read.telegramForBackground)

        read.notch.hotKeys = true
        read.panelTheme = .dark
        let again = AppSettings(defaults: defaults)
        #expect(again.notch.hotKeys && again.panelTheme == .dark)
    }
}
