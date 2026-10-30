import Foundation
import Testing
@testable import ClaudePult

/// SPEC-profiles stage 1: modes become profiles with modules; nothing changes for the user.
@MainActor
struct ProfileModuleTests {
    private func environment() -> (AppSettings, URL) {
        let name = "claudepult-profiles-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)
        settings.projectsDirectory = NSHomeDirectory() + "/Projects"
        settings.dailyReportDirectory = NSHomeDirectory() + "/Projects/_daily-report"
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        return (settings, dir)
    }

    @Test func modulesFollowTheBlocks() {
        let oleh = Mode.developerWithReport(projectsDirectory: "~/Projects", dailyReportDirectory: "~/Projects/_daily-report",
                                            launchMode: nil, showProjects: true, showCommonCommands: false)
        #expect(oleh.normalizedModules(hiddenBlocks: []) == [
            ProfileModule(.limits), ProfileModule(.sessions), ProfileModule(.projects), ProfileModule(.reports, shown: false),
        ])

        var video = Mode(name: "Видео", source: .folders("~/Videos"), calendar: .dates)
        #expect(video.normalizedModules(hiddenBlocks: [.sessions]).map(\.kind) == [.limits, .sessions, .upcoming, .projects])
        #expect(video.normalizedModules(hiddenBlocks: [.sessions])[1].shown == false, "hidden blocks stay hidden")

        // A kind keeps its place; a newly used one goes after the kinds that come before it in the panel.
        video.modules = [ProfileModule(.projects), ProfileModule(.limits), ProfileModule(.sessions)]
        #expect(video.normalizedModules(hiddenBlocks: []).map(\.kind) == [.projects, .limits, .sessions, .upcoming])
        video.calendar = .off
        video.modules = video.normalizedModules(hiddenBlocks: [])
        #expect(video.modules?.map(\.kind) == [.projects, .limits, .sessions], "a block turned off drops its module")

        let empty = Mode(name: "Пусто")
        #expect(empty.normalizedModules(hiddenBlocks: []).map(\.kind) == [.limits, .sessions])
    }

    @Test func oldModeFilesBecomeProfiles() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A mode file and state from before profiles: no modules, no installed list.
        try Data(#"{"id": "m1", "name": "Видео", "source": {"folders": {"_0": "~/Videos"}}, "calendar": "dates"}"#.utf8)
            .write(to: dir.appending(path: "m1.json"))
        try Data(#"{"order": ["m1"], "enabled": ["m1"], "current": "m1"}"#.utf8).write(to: dir.appending(path: "state.json"))

        let store = ModeStore(settings: settings, directory: dir)
        let mode = try #require(store.current)
        #expect(mode.modules?.map(\.kind) == [.limits, .sessions, .upcoming, .projects])
        #expect(store.installedModules == [.limits, .sessions, .upcoming, .projects])

        // Rewritten on disk: the next start reads the same.
        let file = try String(contentsOf: dir.appending(path: "m1.json"), encoding: .utf8)
        #expect(file.contains("\"modules\""))
        let state = try String(contentsOf: dir.appending(path: "state.json"), encoding: .utf8)
        #expect(state.contains("\"installed\""))
        let reloaded = ModeStore(settings: settings, directory: dir)
        #expect(reloaded.modes == store.modes)
        #expect(reloaded.installedModules == store.installedModules)
    }

    @Test func unknownModulesFromNewerFilesAreSkipped() throws {
        let json = #"{"name": "X", "modules": [{"kind": "keepAwake"}, {"kind": "limits", "shown": false}, 7, {"kind": "limits"}, {"shown": true}]}"#
        let mode = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        #expect(mode.modules == [ProfileModule(.limits, shown: false)])
    }

    @Test func exportIsVersionTwoAndOldFilesStillImport() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        let bundle = store.exportBundle()
        #expect(bundle.version == 2)
        #expect(bundle.installed == store.installedModules.map(\.rawValue))
        #expect(bundle.modes.allSatisfy { $0.modules != nil })
        var decoded = try #require(ModeStore.decodeBundle(ModeStore.encode(bundle)))
        decoded.exportedAt = bundle.exportedAt // ISO 8601 keeps whole seconds
        #expect(decoded == bundle)

        // A version 1 file: modes without modules, no installed list — the profiles get modules on import.
        let v1 = #"{"format": "claudepult-settings", "version": 1, "exportedAt": "2026-10-30T10:00:00Z", "modes": [{"id": "a", "name": "Тексты", "source": {"folders": {"_0": "~/Writing"}}}]}"#
        let old = try #require(ModeStore.decodeBundle(Data(v1.utf8)))
        let (settings2, dir2) = environment()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let other = ModeStore(settings: settings2, directory: dir2)
        other.importBundle(old, style: .replace)
        #expect(other.modes.map(\.name) == ["Тексты"])
        #expect(other.current?.modules?.map(\.kind) == [.limits, .sessions, .projects])
        #expect(other.installedModules == [.limits, .sessions, .projects])
    }

    @Test func theProfileDecidesOrderAndVisibility() {
        var video = Mode(name: "Видео", source: .folders("~/Videos"),
                         modules: [ProfileModule(.projects), ProfileModule(.limits, shown: false), ProfileModule(.sessions)])
        #expect(video.normalizedModules(hiddenBlocks: [.limits, .sessions, .projects]) == video.modules,
                "old global blocks no longer matter once a profile has modules")
        video.calendar = .dates
        let withCalendar = video.normalizedModules(hiddenBlocks: [.calendar])
        #expect(withCalendar.map(\.kind) == [.projects, .limits, .sessions, .upcoming])
        #expect(withCalendar.last?.shown == true, "a module that becomes possible is shown")
        video.modules = withCalendar
        #expect(video.panelModules == [.projects, .sessions, .upcoming])
    }

    @Test func selectingAProfileAppliesItsPanelAndMenuBar() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        settings.menuBarConfig = .make(.limits)
        let store = ModeStore(settings: settings, directory: dir)
        let first = try #require(store.current)
        #expect(first.menuBar == .make(.limits), "an old profile takes the menu bar it had")

        var quiet = try #require(store.duplicate(first.id))
        quiet.modules = [ProfileModule(.sessions), ProfileModule(.limits, shown: false)] + (quiet.modules ?? []).filter { ![.limits, .sessions].contains($0.kind) }
        quiet.menuBar = .make(.minimum)
        store.update(quiet)

        store.select(quiet.id)
        #expect(!settings.shows(.limits))
        #expect(settings.shows(.sessions))
        #expect(store.panelModules.first == .sessions)
        #expect(settings.menuBarConfig == .make(.minimum))

        // Settings → «Строка меню» changes the current profile only.
        var custom = MenuBarConfig.make(.everything)
        custom.preset = .custom
        settings.menuBarConfig = custom
        store.setMenuBar(custom)
        store.select(first.id)
        #expect(settings.menuBarConfig == .make(.limits))
        #expect(settings.shows(.limits))
        store.select(quiet.id)
        #expect(settings.menuBarConfig == custom)

        // Old readers see the same through the block flags.
        let reloaded = ModeStore(settings: settings, directory: dir)
        #expect(reloaded.modes.first { $0.id == quiet.id }?.modules == store.modes.first { $0.id == quiet.id }?.modules)
    }

    @Test func emptyStartWithoutDailyReport() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        settings.dailyReportDirectory = dir.appending(path: "no-daily-report").path
        let store = ModeStore(settings: settings, directory: dir)
        #expect(store.modes.isEmpty && store.current == nil)
        #expect(store.installedModules.isEmpty, "nothing works until a profile exists")
        #expect(store.needsAssistant)
        #expect(store.panelModules.isEmpty)
        #expect(ModeStore(settings: settings, directory: dir).needsAssistant, "still nothing set up on the next start")
    }

    @Test func deletingTheLastProfileEmptiesClaudePult() throws {
        let (settings, dir) = environment()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        let only = try #require(store.current)
        store.delete(only.id)
        #expect(store.modes.isEmpty && store.currentID.isEmpty)
        #expect(store.installedModules.isEmpty, "modules no profile uses stop")
        let reloaded = ModeStore(settings: settings, directory: dir)
        #expect(reloaded.modes.isEmpty)
        #expect(!reloaded.needsAssistant, "an emptied ClaudePult doesn't push the assistant on every start")
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "\(only.id).json").path))
    }
}
