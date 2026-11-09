import Foundation
import Testing
@testable import AIHubBar

/// SPEC-profiles stage 6: «Быстрые команды», «Быстрые переключатели», the «Утилиты Mac» template.
struct QuickToolsTests {
    @Test func whatACommandRuns() {
        #expect(QuickCommand(title: "x", kind: .script, value: " brew upgrade ").invocation == .process(executable: "/bin/zsh", arguments: ["-lc", "brew upgrade"]))
        #expect(QuickCommand(title: "x", kind: .terminal, value: "htop").invocation == .terminal("htop"))
        #expect(QuickCommand(title: "x", kind: .shortcut, value: "Фокус").invocation == .process(executable: "/usr/bin/shortcuts", arguments: ["run", "Фокус"]))
        #expect(QuickCommand(title: "x", kind: .open, value: "https://claude.ai").invocation == .open(URL(string: "https://claude.ai")!))
        #expect(QuickCommand(title: "x", kind: .open, value: "~/Downloads").invocation == .open(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")))
        #expect(QuickCommand(title: "x", kind: .script, value: "  ").invocation == .invalid)
        #expect(QuickCommand.examples.allSatisfy { $0.invocation != .invalid })
    }

    @Test func notificationText() {
        #expect(QuickToolsController.summary(stdout: "a\nb\n\n192.168.1.5\n", stderr: "") == "192.168.1.5")
        #expect(QuickToolsController.summary(stdout: "", stderr: "zsh: command not found: x") == "zsh: command not found: x")
        #expect(QuickToolsController.summary(stdout: String(repeating: "x", count: 300), stderr: "").count == 140)
    }

    @Test func onlyTheTrashAsksFirst() {
        #expect(QuickToggle.allCases.filter(\.needsConfirmation) == [.emptyTrash])
    }

    @Test func onlyDesktopIconsWarnWhileOff() {
        #expect(QuickToggle.allCases.filter { $0.offNote != nil } == [.desktopIcons])
    }

    @Test func islandToggleOnlyWithTheIsland() {
        #expect(!QuickToggle.available(installed: [.toggles]).contains(.notchIsland))
        #expect(QuickToggle.available(installed: [.toggles, .notch]).contains(.notchIsland))
        #expect(QuickToggle.available(installed: []).count == QuickToggle.allCases.count - 1)
    }

    @MainActor @Test func islandToggleHidesTheIsland() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "quick-island-\(UUID().uuidString)")!)
        let tools = QuickToolsController(settings: settings)
        #expect(tools.isOn(.notchIsland) == true)
        tools.perform(.notchIsland)
        #expect(settings.notch.hidden && tools.isOn(.notchIsland) == false)
        tools.perform(.notchIsland)
        #expect(!settings.notch.hidden)
    }

    @Test func storedLibraryDecodes() throws {
        let commands = [QuickCommand(title: "Сборка", symbol: "hammer", kind: .terminal, value: "make", confirm: true)]
        let decoded = try JSONDecoder().decode([QuickCommand].self, from: JSONEncoder().encode(commands))
        #expect(decoded == commands)
    }
}

@MainActor
struct UtilitiesTemplateTests {
    @Test func theTemplateIsAllMacTools() throws {
        for language in ContentLanguage.allCases {
            let template = try #require(ProfileTemplate.loadAll(language: language).first { $0.id == "utilities" }, "\(language)")
            #expect(template.mode.source == .none)
            #expect(template.mode.modules?.filter(\.shown).map(\.kind) == [.resources, .keepAwake, .quickCommands, .toggles])
        }
        let ids = ProfileTemplate.loadAll(language: .ru).map(\.id)
        #expect(ids.last == "custom" && ids.contains("utilities"), "«Свой» stays last")
    }

    @Test func theAssistantTakesItsModules() throws {
        let template = try #require(ProfileTemplate.loadAll(language: .ru).first { $0.id == "utilities" })
        var draft = AssistantDraft(firstLaunch: false, menuBar: .make(.limits), reminderHours: [24])
        draft.choose(template)
        #expect(draft.extraModules == [.resources, .keepAwake, .quickCommands, .toggles])
        #expect(draft.hiddenModules == [.limits, .sessions])
        #expect(draft.steps == [.template, .modules, .menuBar, .name], "no project questions")
        draft.choose(nil)
        #expect(draft.extraModules.isEmpty && draft.hiddenModules.isEmpty, "another template starts clean")
    }

    @Test func addingItFromSettingsInstallsItsModules() throws {
        let name = "claudepult-utilities-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.dailyReportDirectory = "/nonexistent"
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(settings: settings, directory: dir)
        let template = try #require(ProfileTemplate.loadAll(language: .ru).first { $0.id == "utilities" })
        let profile = store.add(template, folder: "")
        #expect(profile.source == .none)
        #expect(store.panelModules == [.resources, .keepAwake, .quickCommands, .toggles])
        #expect(Set(store.installedModules).isSuperset(of: [.resources, .keepAwake, .quickCommands, .toggles]))
    }
}

/// The order of `ScreenLock`'s steps. Nothing here calls the real ones: that would lock this Mac.
@MainActor
struct ScreenLockTests {
    final class Log {
        var ran: [String] = []
        var lockedBy: String?
        var isLocked: Bool { lockedBy != nil && ran.contains(lockedBy!) }
    }

    private func steps(_ log: Log) -> [ScreenLock.Step] {
        ["first", "second", "third"].map { name in ScreenLock.Step(name: name) { log.ran.append(name) } }
    }

    @Test func stopsAtTheStepThatLocked() async {
        let log = Log()
        log.lockedBy = "second"
        let locked = await ScreenLock.run(steps(log), isLocked: { log.isLocked }, settle: .milliseconds(1))
        #expect(locked)
        #expect(log.ran == ["first", "second"])
    }

    /// A private call that is still there but does nothing must not read as success.
    @Test func noStepLockedIsAFailure() async {
        let log = Log()
        let locked = await ScreenLock.run(steps(log), isLocked: { log.isLocked }, settle: .milliseconds(1))
        #expect(!locked)
        #expect(log.ran == ["first", "second", "third"])
    }

    /// Fails on the first macOS that drops the private call. Only looks it up.
    @Test func thePrivateCallIsStillThere() {
        #expect(ScreenLock.privateLock() != nil)
    }
}
