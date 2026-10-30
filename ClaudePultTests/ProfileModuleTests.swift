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
        #expect(oleh.syncedModules(hiddenBlocks: []) == [
            ProfileModule(.limits), ProfileModule(.sessions), ProfileModule(.projects), ProfileModule(.reports, shown: false),
        ])

        var video = Mode(name: "Видео", source: .folders("~/Videos"), calendar: .dates)
        #expect(video.syncedModules(hiddenBlocks: [.sessions]).map(\.kind) == [.limits, .sessions, .upcoming, .projects])
        #expect(video.syncedModules(hiddenBlocks: [.sessions])[1].shown == false, "hidden blocks stay hidden")

        // A kind keeps its place; a newly used one goes after the kinds that come before it in the panel.
        video.modules = [ProfileModule(.projects), ProfileModule(.limits), ProfileModule(.sessions)]
        #expect(video.syncedModules(hiddenBlocks: []).map(\.kind) == [.projects, .limits, .sessions, .upcoming])
        video.calendar = .off
        video.modules = video.syncedModules(hiddenBlocks: [])
        #expect(video.modules?.map(\.kind) == [.projects, .limits, .sessions], "a block turned off drops its module")

        let empty = Mode(name: "Пусто")
        #expect(empty.syncedModules(hiddenBlocks: []).map(\.kind) == [.limits, .sessions])
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
}
