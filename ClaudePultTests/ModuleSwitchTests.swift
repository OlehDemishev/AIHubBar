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

    /// SPEC-refactor §2.1: switched-off modules travel in exports, and «Заменить всё» takes the file's, not the old ones.
    @Test func switchedOffModulesTravelWithExports() throws {
        let (source, _, sourceDir) = try store()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        source.setOn(.sessions, false)
        let bundle = source.exportBundle()
        #expect(bundle.off == ["sessions"])

        let (target, _, targetDir) = try store()
        defer { try? FileManager.default.removeItem(at: targetDir) }
        target.setOn(.limits, false)
        target.importBundle(bundle, style: .replace)
        #expect(target.switchedOff == [.sessions])
        #expect(target.isOn(.limits))

        var old = bundle
        old.off = nil
        target.importBundle(old, style: .replace)
        #expect(target.switchedOff.isEmpty, "a file from before the switch has everything on")
    }

    /// SPEC-refactor §2.7: `--modes` and friends look without writing — an old file stays as it was.
    @Test func readOnlyStoreWritesNothing() throws {
        let (_, settings, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"id": "m2", "name": "Тексты", "source": {"folders": {"_0": "~/Texts"}}}"#.utf8).write(to: dir.appending(path: "m2.json"))
        let before = try String(contentsOf: dir.appending(path: "m2.json"), encoding: .utf8)
        let looking = ModeStore(settings: settings, directory: dir, readOnly: true)
        #expect(looking.modes.first { $0.id == "m2" }?.modules != nil, "normalized in memory")
        #expect(try String(contentsOf: dir.appending(path: "m2.json"), encoding: .utf8) == before)
        #expect(looking.exportBundle().installed?.contains("limits") == true)
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
        // Every frequency is set on some module's page now that «Основные» has no list.
        #expect(Set(ModuleKind.allCases.flatMap(NotificationKind.of)) == Set(NotificationKind.allCases))
        #expect(NotificationKind.of(.reports) == [.commands])
        #expect(SettingsPane.module(.limits).matches("Лимиты: Claude"))
    }
}

/// SPEC-settings §2: long footnotes show their first sentence and «Подробнее».
@MainActor
struct FootnoteTests {
    @Test func firstSentenceOfLongTextsOnly() {
        #expect(Footnote.firstSentence("Коротко. Ещё.") == nil)
        let long = "Любое сработавшее правило не даёт Mac уснуть. " + String(repeating: "Дальше подробности про правила и экран. ", count: 4)
        #expect(Footnote.firstSentence(long) == "Любое сработавшее правило не даёт Mac уснуть.")
        let japanese = "ルールが有効な間はMacがスリープしません。ここから先は詳しい説明です。" + String(repeating: "詳しい説明が続きます。", count: 12)
        #expect(Footnote.firstSentence(japanese) == "ルールが有効な間はMacがスリープしません。")
        #expect(Footnote.firstSentence(String(repeating: "без точки ", count: 30)) == nil)
    }
}

/// SPEC-settings §3: a built-in module a profile doesn't call for has a button that brings it in.
@MainActor
struct ModuleEnableTests {
    @Test func calendarButtonBringsInUpcoming() throws {
        let name = "claudepult-enable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"id": "m1", "name": "Тексты", "source": {"folders": {"_0": "~/Texts"}}}"#.utf8).write(to: dir.appending(path: "m1.json"))
        try Data(#"{"order": ["m1"], "enabled": ["m1"], "current": "m1"}"#.utf8).write(to: dir.appending(path: "state.json"))
        let modes = ModeStore(settings: settings, directory: dir)
        #expect(!modes.isOn(.upcoming))
        let action = try #require(ModuleSwitch.enableAction(.upcoming, modes: modes))
        action.run()
        #expect(modes.isOn(.upcoming))
        #expect(ModuleSwitch.enableAction(.upcoming, modes: modes) == nil)
        #expect(ModuleSwitch.enableAction(.limits, modes: modes) == nil, "already there")
    }
}
