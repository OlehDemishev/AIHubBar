import Foundation
import Testing
@testable import ClaudePult

@MainActor
struct ModeStoreTests {
    private func environment() -> (AppSettings, URL) {
        let name = "claudepult-modes-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)
        settings.projectsDirectory = NSHomeDirectory() + "/Projects"
        settings.dailyReportDirectory = NSHomeDirectory() + "/Projects/_daily-report"
        settings.defaultLaunchMode = .background
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        return (settings, dir)
    }

    @Test func firstStartMigratesExistingSettings() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        settings.setShows(.commands, false)

        let store = ModeStore(settings: settings, directory: dir)
        #expect(store.modes.count == 1)
        let mode = try #require(store.current)
        #expect(mode.source == .gitReport(projects: "~/Projects", dailyReport: "~/Projects/_daily-report"))
        #expect(mode.launchMode == .background)
        #expect(mode.commonCommands == .dailyReport)
        #expect(!mode.showCommonCommands)
        #expect(mode.name.hasPrefix("Разработчик"))
        // Applying it changes nothing for the user.
        #expect(settings.projectsDirectory == NSHomeDirectory() + "/Projects")
        #expect(settings.defaultLaunchMode == .background)
        #expect(!settings.shows(.commands))
        #expect(settings.shows(.projects))

        let reloaded = ModeStore(settings: settings, directory: dir)
        #expect(reloaded.modes == store.modes)
        #expect(reloaded.currentID == store.currentID)
    }

    @Test func duplicateSelectEnableDelete() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        let first = try #require(store.current)

        var copy = try #require(store.duplicate(first.id))
        #expect(copy.name == first.name + " (копия)")
        copy.source = .gitReport(projects: "~/Work", dailyReport: "~/Work/_daily-report")
        copy.launchMode = .terminal
        store.update(copy)
        store.setEnabled(copy.id, true)
        #expect(store.enabledModes.count == 2)

        var applied = 0
        store.didApply = { applied += 1 }
        store.select(copy.id)
        #expect(applied == 1)
        #expect(settings.projectsDirectory == NSHomeDirectory() + "/Work")
        #expect(settings.defaultLaunchMode == .terminal)

        store.move(copy.id, by: -1)
        #expect(store.modes.first?.id == copy.id)

        store.setEnabled(first.id, false)
        #expect(store.enabledIDs == [copy.id])
        store.setEnabled(copy.id, false) // the last enabled mode stays on
        #expect(store.enabledIDs == [copy.id])

        store.delete(copy.id)
        #expect(store.modes.map(\.id) == [first.id])
        #expect(store.currentID == first.id)
        #expect(settings.projectsDirectory == NSHomeDirectory() + "/Projects")
        store.delete(first.id) // the last mode cannot be deleted
        #expect(store.modes.count == 1)
    }

    @Test func exportAndReplaceOnAnotherMac() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        settings.panelTextSize = .large
        settings.limitThresholds = [70, 90]
        settings.claudePath = NSHomeDirectory() + "/bin/claude"
        settings.menuBarConfig = .make(.everything)
        settings.menuBarConfig.set(.session) { $0.style = .bar }
        settings.aiServices.models["openai"] = "gpt-x"
        settings.aiServices.compatibleName = "Ollama"
        _ = store.duplicate(store.currentID)
        let data = try ModeStore.encode(store.exportBundle())
        #expect(!String(decoding: data, as: UTF8.self).contains(NSHomeDirectory()), "home folder is written as ~")

        let (otherSettings, otherDir) = environment()
        defer { try? FileManager.default.removeItem(at: otherDir) }
        let other = ModeStore(settings: otherSettings, directory: otherDir)
        let bundle = try #require(ModeStore.decodeBundle(data))
        other.importBundle(bundle, style: .replace)
        #expect(other.modes == store.modes)
        #expect(other.currentID == store.currentID)
        #expect(otherSettings.panelTextSize == .large)
        #expect(otherSettings.limitThresholds == [70, 90])
        #expect(otherSettings.claudePath == NSHomeDirectory() + "/bin/claude")
        #expect(otherSettings.menuBarConfig == settings.menuBarConfig)
        #expect(otherSettings.aiServices == settings.aiServices)
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: otherDir.lastPathComponent)))
        #expect(reloaded.menuBarConfig == settings.menuBarConfig, "stored as JSON in defaults")
        #expect(ModeStore(settings: otherSettings, directory: otherDir).modes.count == 2)
    }

    @Test func oldExportsWithoutBuilderConfigMigrate() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        var bundle = store.exportBundle()
        bundle.appearance?.menuBarConfig = nil
        bundle.appearance?.menuBar = "ring"
        store.importBundle(bundle, style: .replace)
        #expect(settings.menuBarConfig == .migrated(from: .ring))
        #expect(store.exportBundle().appearance?.menuBar == "ring")
    }

    @Test func addImportedModesWithFreshIdsAndNames() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        let mode = try #require(store.current)
        let bundle = try #require(store.exportMode(mode.id))
        #expect(bundle.format == SettingsBundle.modeFormat)
        #expect(bundle.general == nil)

        store.importBundle(bundle, style: .add)
        #expect(store.modes.count == 2)
        #expect(Set(store.modes.map(\.id)).count == 2)
        #expect(store.modes.last?.name == mode.name + " 2")
        #expect(store.currentID == mode.id)
    }

    @Test func rejectsForeignFilesAndToleratesUnknownBlocks() throws {
        #expect(ModeStore.decodeBundle(Data(#"{"format": "other", "version": 1, "exportedAt": "2026-10-30T00:00:00Z", "modes": []}"#.utf8)) == nil)
        #expect(ModeStore.decodeBundle(Data("garbage".utf8)) == nil)
        let json = #"""
        {"format": "claudepult-mode", "version": 3, "exportedAt": "2026-10-30T00:00:00Z",
         "modes": [{"id": "x", "name": "Видео", "source": {"hologram": {}}, "calendar": "quantum", "futureBlock": 42}]}
        """#
        let bundle = try #require(ModeStore.decodeBundle(Data(json.utf8)))
        let mode = try #require(bundle.modes.first)
        #expect(mode.name == "Видео")
        #expect(mode.source == .none)
        #expect(mode.calendar == .off)
        #expect(mode.showProjects)
    }

    @Test func missingFolders() {
        let mode = Mode(name: "X", source: .gitReport(projects: "~", dailyReport: "~/no-such-folder-\(UUID().uuidString)"))
        #expect(ModeStore.missingFolders(mode).count == 1)
        #expect(PathText.tilde(NSHomeDirectory() + "/Projects") == "~/Projects")
        #expect(PathText.expand("~/Projects") == NSHomeDirectory() + "/Projects")
    }
}
