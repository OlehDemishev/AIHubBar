import Foundation
import Testing
@testable import ClaudePult

/// SPEC-settings §1: every module, built-in ones too, has a main switch; off keeps its place in the profiles.
@MainActor
struct ModuleSwitchTests {
    private func store() throws -> (ModeStore, AppSettings, URL) {
        let name = "claudepult-switch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"id": "m1", "name": "Видео", "source": {"folders": {"_0": "~/Videos"}}, "calendar": "dates"}"#.utf8)
            .write(to: dir.appending(path: "m1.json"))
        try Data(#"{"order": ["m1"], "enabled": ["m1"], "current": "m1"}"#.utf8).write(to: dir.appending(path: "state.json"))
        return (ModeStore(settings: settings, directory: dir), settings, dir)
    }

    @Test func builtInModuleSwitchesOffAndBack() throws {
        let (modes, settings, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(modes.isOn(.limits))
        #expect(modes.panelModules == [.limits, .sessions, .upcoming, .projects])

        modes.setOn(.limits, false)
        #expect(!modes.isOn(.limits))
        #expect(modes.panelModules == [.sessions, .upcoming, .projects])
        #expect(modes.current?.modules?.first?.kind == .limits, "keeps its place in the profile")
        #expect(!settings.shows(.limits))

        // Read back from disk.
        let reloaded = ModeStore(settings: settings, directory: dir)
        #expect(reloaded.switchedOff == [.limits])
        #expect(!reloaded.isOn(.limits))

        reloaded.setOn(.limits, true)
        #expect(reloaded.isOn(.limits))
        #expect(reloaded.panelModules.first == .limits)
        #expect(settings.shows(.limits))
    }

    @Test func optionalModuleInstallsWithItsSwitch() throws {
        let (modes, _, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!modes.isOn(.resources))
        modes.setOn(.resources, true)
        #expect(modes.isOn(.resources))
        #expect(modes.panelModules.last == .resources)
        modes.setOn(.resources, false)
        #expect(!modes.isOn(.resources))
        #expect(modes.installedModules.contains(.resources), "stays installed, with its settings and place")
        #expect(!modes.panelModules.contains(.resources))
    }

    @Test func betaModuleWorksOnlyWithBetaBuilds() throws {
        let (modes, settings, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        settings.betaUpdates = true
        modes.setOn(.layout, true)
        #expect(modes.isOn(.layout))
        settings.betaUpdates = false
        #expect(!modes.isOn(.layout))
    }

    @Test func switchedOffModulesDrawNothingInTheMenuBar() {
        var config = MenuBarConfig.make(.everything)
        config.colored = false
        let data = MenuBarData.sample.without([.limits, .sessions, .resources, .keepAwake, .upcoming, .projects])
        let groups = MenuBarComposer.groups(config, data)
        #expect(!groups.flatMap { $0 }.contains(.text("34%", .label)))
        #expect(!groups.flatMap { $0 }.contains(.dot))
        #expect(data.waiting == 0 && data.session == nil && data.cpu == nil && data.deadline == nil)
        #expect(MenuBarElement.Kind.allCases.filter { $0.module == .limits } == [.session, .week, .modelWeek, .resetCountdown, .forecast, .otherAI])
    }

    @Test func notificationsBelongToModules() {
        #expect(NotificationKind.waiting.module == .sessions)
        #expect(NotificationKind.limits.module == .limits)
        #expect(NotificationKind.commands.module == nil)
    }
}
