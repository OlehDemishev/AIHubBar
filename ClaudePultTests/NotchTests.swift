import Foundation
import Testing
@testable import ClaudePult

/// SPEC-notch stage 1: where the notch is and how the island sits around it.
struct NotchTests {
    /// What a 13.6" MacBook Air reports at its default resolution (1470 × 956 points).
    private let air = CGRect(x: 0, y: 0, width: 1470, height: 956)

    @Test func notchFromScreenAreas() throws {
        let geometry = try #require(NotchGeometry(
            screen: air, safeAreaTop: 32,
            topLeftArea: CGRect(x: 0, y: 924, width: 640, height: 32),
            topRightArea: CGRect(x: 830, y: 924, width: 640, height: 32)
        ))
        #expect(geometry.notch == CGRect(x: 640, y: 924, width: 190, height: 32))
        #expect(geometry.restFrame.width == 190 + 2 * NotchGeometry.earWidth)
        #expect(geometry.restFrame.maxY == air.maxY, "the island hangs from the top edge")
    }

    @Test func noNotch() {
        #expect(NotchGeometry(screen: air, safeAreaTop: 0, topLeftArea: nil, topRightArea: nil) == nil)
        #expect(NotchGeometry(screen: air, safeAreaTop: 32, topLeftArea: nil, topRightArea: nil) == nil)
        #expect(NotchGeometry(screen: air, safeAreaTop: 32,
                              topLeftArea: CGRect(x: 0, y: 924, width: 800, height: 32),
                              topRightArea: CGRect(x: 700, y: 924, width: 770, height: 32)) == nil, "areas that overlap")
    }

    @Test func windowCentredUnderNotch() {
        let geometry = NotchGeometry(notch: CGRect(x: 640, y: 924, width: 190, height: 32), screen: air)
        let window = geometry.windowFrame
        #expect(window.width == NotchGeometry.cardWidth)
        #expect(window.maxY == air.maxY)
        #expect(abs(window.midX - geometry.notch.midX) < 0.5)
        #expect(geometry.notchOffsetInWindow == geometry.notch.minX - window.minX)
    }

    @Test func windowStaysOnScreen() {
        // A second screen to the right, and a notch that would push the card past an edge.
        let screen = CGRect(x: 1470, y: 0, width: 300, height: 900)
        let geometry = NotchGeometry(notch: CGRect(x: 1480, y: 868, width: 100, height: 32), screen: screen)
        #expect(geometry.windowFrame.minX >= screen.minX)
        #expect(geometry.windowFrame.maxX <= screen.maxX)
    }
}

/// The island is a module of the screen, not of the panel (SPEC-notch §6).
struct NotchModuleTests {
    @Test func developersGetItOnlyWithANotch() throws {
        var draft = AssistantDraft(firstLaunch: false, menuBar: .make(.limits), hiddenBlocks: [], reminderHours: [24])
        let developer = try #require(ModeTemplate.loadAll(language: .ru).first { $0.id == "developer" })
        draft.choose(developer, hasNotch: true)
        #expect(draft.hasModule(.notch))
        draft.choose(developer, hasNotch: false)
        #expect(!draft.hasModule(.notch), "no notch, no island")
        draft.choose(nil, hasNotch: true)
        #expect(!draft.hasModule(.notch), "other templates leave it to the person")
    }

    @MainActor
    @Test func installingDoesNotTouchThePanel() throws {
        let name = "claudepult-notch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.dailyReportDirectory = "/nonexistent"
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        let template = try #require(ModeTemplate.loadAll(language: .ru).first { $0.id == "utilities" })
        _ = store.add(template, folder: "")
        let panel = store.panelModules

        store.install(.notch)
        #expect(store.installedModules.contains(.notch))
        #expect(store.panelModules == panel, "the island is not a block of the panel")
        #expect(store.current?.modules?.contains { $0.kind == .notch } != true)

        store.uninstall(.notch)
        #expect(!store.installedModules.contains(.notch))
    }

    @Test func settingsDecode() throws {
        let old = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"rightEar": "background", "future": 1}"#.utf8))
        #expect(old.rightEar == .background && old.leftEar == .sessionLimit && old.openOnHover)
        let unknown = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"leftEar": "weather"}"#.utf8))
        #expect(unknown.leftEar == .sessionLimit, "an ear from a newer version falls back to the default")
    }
}
