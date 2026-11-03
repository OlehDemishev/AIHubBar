import Foundation
import Testing
@testable import ClaudePult

/// SPEC-refactor §0: files on people's Macs must read and write the same through the refactor. These pin the keys of
/// a profile file, `state.json` and a `.claudepult` export; a change here is a format change and needs a migration.
@MainActor
struct FileFormatTests {
    private func keys(_ value: some Encodable) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        return Set((try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys)
    }

    @Test func profileFileKeys() throws {
        var mode = Mode(name: "Видео", source: .folders("~/Videos"), calendar: .dates)
        mode.modules = mode.normalizedModules(hiddenBlocks: [])
        mode.menuBar = .make(.limits)
        let keys = try keys(mode)
        // The keys every profile file has had since profiles (SPEC-profiles §7); new optional ones may be added.
        for key in ["id", "name", "icon", "source", "calendar", "showProjects", "commonCommands", "showCommonCommands", "commands", "modules", "menuBar"] {
            #expect(keys.contains(key), "profile file has \(key)")
        }
        let module = try self.keys(ProfileModule(.resources))
        #expect(module.isSuperset(of: ["kind", "shown"]))
    }

    @Test func stateFileKeys() throws {
        let state = ModeStore.State(order: ["a"], enabled: ["a"], current: "a", installed: ["limits"], off: ["sessions"])
        #expect(try keys(state) == ["order", "enabled", "current", "installed", "off"])
    }

    @Test func exportKeys() throws {
        let name = "claudepult-format-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: AppSettings(defaults: defaults), directory: dir)
        let bundle = store.exportBundle()
        let keys = try keys(bundle)
        for key in ["format", "version", "exportedAt", "general", "appearance", "modes"] {
            #expect(keys.contains(key), "export has \(key)")
        }
        #expect(bundle.format == "claudepult-settings")
        #expect(SettingsBundle.currentVersion == 2)
        // Older versions read the legacy menu bar and block fields: keep writing them.
        let appearance = try self.keys(try #require(bundle.appearance))
        #expect(appearance.isSuperset(of: ["showLimits", "showSessions", "menuBar", "menuBarConfig"]))
    }

    @Test func menuBarConfigKeys() throws {
        // Without dividers and in the plain look the file is exactly what versions before them wrote.
        #expect(try keys(MenuBarConfig.make(.limits)) == ["elements", "separator", "smallText", "colored", "preset"])
    }
}
