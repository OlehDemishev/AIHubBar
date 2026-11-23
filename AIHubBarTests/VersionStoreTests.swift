import Foundation
import Testing
@testable import AIHubBar

/// «Версии»: the store of a folder project's draft versions (`VersionStore`, SPEC-content §4).
struct VersionStoreTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func setUp() throws -> (store: VersionStore, project: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "versions-\(UUID().uuidString)")
        let project = base.appending(path: "Projects/Ролик про кофе")
        try FileManager.default.createDirectory(at: project.appending(path: "черновики"), withIntermediateDirectories: true)
        try "идея".write(to: project.appending(path: "проект.md"), atomically: true, encoding: .utf8)
        try "первый вариант".write(to: project.appending(path: "черновики/сценарий.md"), atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: project.appending(path: "обложка.png"))
        return (VersionStore(root: base.appending(path: "store")), project, base)
    }

    @Test func aVersionIsTakenOnlyWhenSomethingDiffers() throws {
        let (store, project, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = try #require(try store.take(projectPath: project.path, reason: .beforeRun("Редактура"), now: now))
        #expect(first.files.map(\.path) == ["проект.md", "черновики/сценарий.md"], "texts and the card; the picture is skipped")
        #expect(first.reason == .beforeRun("Редактура"))
        #expect(try store.take(projectPath: project.path, reason: .automatic, now: now.addingTimeInterval(600)) == nil, "nothing changed")

        try "второй вариант".write(to: project.appending(path: "черновики/сценарий.md"), atomically: true, encoding: .utf8)
        let second = try #require(try store.take(projectPath: project.path, reason: .automatic, now: now.addingTimeInterval(1200)))
        #expect(second.changed(from: first) == ["черновики/сценарий.md"])
        #expect(store.versions(projectPath: project.path).map(\.id) == [second.id, first.id], "newest first")

        // Each content once: the card is the same in both versions.
        let objects = try FileManager.default.contentsOfDirectory(atPath: store.folder(projectPath: project.path).appending(path: "objects").path)
        #expect(objects.count == 3)
        let old = try #require(first.files.first { $0.path == "черновики/сценарий.md" })
        #expect(store.content(projectPath: project.path, hash: old.hash) == Data("первый вариант".utf8))
        #expect(store.content(projectPath: project.path, hash: "../../etc") == nil)

        // A file removed from the project is a change too.
        try FileManager.default.removeItem(at: project.appending(path: "черновики/сценарий.md"))
        let third = try #require(try store.take(projectPath: project.path, reason: .beforeRestore, now: now.addingTimeInterval(1800)))
        #expect(third.changed(from: second) == ["черновики/сценарий.md"] && third.files.count == 1)
        // Nothing of the store lands in the project's folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted() == ["обложка.png", "проект.md", "черновики"])
    }

    @Test func aProjectWithoutTextsHasNoVersions() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "versions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let project = base.appending(path: "Пусто")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = VersionStore(root: base.appending(path: "store"))
        #expect(try store.take(projectPath: project.path, reason: .automatic, now: now) == nil)
        #expect(store.versions(projectPath: project.path).isEmpty && store.size() == 0)
    }

    @Test func aFileOverTheLimitIsSkippedAndNamed() throws {
        let (store, project, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        try String(repeating: "я", count: 600).write(to: project.appending(path: "роман.txt"), atomically: true, encoding: .utf8)
        let version = try #require(try store.take(projectPath: project.path, reason: .automatic, now: now, sizeLimit: 1000))
        #expect(version.skipped == ["роман.txt"] && !version.files.contains { $0.path == "роман.txt" })
    }

    @Test func twoProjectsOfOneNameDoNotMix() {
        let store = VersionStore(root: URL(fileURLWithPath: "/store"))
        let first = store.folder(projectPath: "/Users/me/Видео/Ролик"), second = store.folder(projectPath: "/Users/me/Тексты/Ролик")
        #expect(first != second && first.lastPathComponent.hasPrefix("Ролик-") && second.lastPathComponent.hasPrefix("Ролик-"))
        #expect(store.folder(projectPath: "/Users/me/Видео/Ролик/") == first, "the same folder however it is written")
    }

    @Test func allOfTheLastDayThenOneADay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2026-11-18 12:00 UTC
        let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))!
        func version(hoursAgo: Double) -> ProjectVersion {
            let date = noon.addingTimeInterval(-hoursAgo * 3600)
            return ProjectVersion(id: VersionStore.name(date), takenAt: date, reason: .automatic, files: [])
        }
        let versions = [1, 5, 23, 30, 33, 60, 24 * 29.0, 24 * 31.0].map(version)
        let kept = VersionStore.kept(versions, now: noon, keepDays: 30, calendar: calendar)
        // 30 h and 33 h ago are the same day (17 Nov, 06:00 and 03:00): the later one stays.
        #expect(kept == Set([1, 5, 23, 30, 60, 24 * 29.0].map { version(hoursAgo: $0).id }))
    }

    @Test func pruningRemovesOldVersionsAndTheirContents() throws {
        let (store, project, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = now.addingTimeInterval(-40 * 86_400)
        try store.take(projectPath: project.path, reason: .automatic, now: old)
        try "новый текст".write(to: project.appending(path: "черновики/сценарий.md"), atomically: true, encoding: .utf8)
        let fresh = try #require(try store.take(projectPath: project.path, reason: .automatic, now: now))
        #expect(store.prune(projectPath: project.path, now: now) == 1)
        #expect(store.versions(projectPath: project.path).map(\.id) == [fresh.id])
        let objects = try FileManager.default.contentsOfDirectory(atPath: store.folder(projectPath: project.path).appending(path: "objects").path)
        #expect(Set(objects) == Set(fresh.files.map(\.hash)), "the old draft's content is gone, the card's stays")
        #expect(store.size() > 0)
    }

    @Test func aDeletedProjectsStoreGoesAfterAMonth() throws {
        let (store, project, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.take(projectPath: project.path, reason: .automatic, now: now)
        #expect(store.removeOrphans(now: now.addingTimeInterval(40 * 86_400)).isEmpty, "the project is still there")
        try FileManager.default.removeItem(at: project)
        #expect(store.removeOrphans(now: now.addingTimeInterval(10 * 86_400)).isEmpty, "not yet a month")
        #expect(store.removeOrphans(now: now.addingTimeInterval(40 * 86_400)) == [project.path])
        #expect(store.versions(projectPath: project.path).isEmpty)
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: store.root.path))
    }
}

/// «Версии»: the module's settings and the service that takes the versions (`VersionKeeper`).
@MainActor
struct VersionKeeperTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func theTimerFollowsTheChosenPace() {
        #expect(VersionKeeper.isDue(last: nil, pace: .tenMinutes, now: now), "the first time at once")
        #expect(!VersionKeeper.isDue(last: now.addingTimeInterval(-300), pace: .tenMinutes, now: now))
        #expect(VersionKeeper.isDue(last: now.addingTimeInterval(-600), pace: .tenMinutes, now: now))
        #expect(!VersionKeeper.isDue(last: now.addingTimeInterval(-600), pace: .thirtyMinutes, now: now))
        #expect(!VersionKeeper.isDue(last: nil, pace: .beforeRuns, now: now), "only before AI runs")
    }

    @Test func settingsSurviveAnOlderOrBrokenRecord() throws {
        let fresh = VersionsSettings()
        #expect(fresh.pace == .tenMinutes && fresh.keepDays == 30 && fresh.sizeLimit == 20 * 1024 * 1024)
        let partial = try JSONDecoder().decode(VersionsSettings.self, from: Data(#"{"pace":"beforeRuns"}"#.utf8))
        #expect(partial.pace == .beforeRuns && partial.keepDays == 30 && partial.sizeLimitMB == 20)
        let odd = try JSONDecoder().decode(VersionsSettings.self, from: Data(#"{"pace":"hourly","keepDays":90}"#.utf8))
        #expect(odd.pace == .tenMinutes && odd.keepDays == 90)
        var changed = fresh
        changed.sizeLimitMB = 5
        #expect(try JSONDecoder().decode(VersionsSettings.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func versionsAreTakenBeforeARunAndByTheTimerWhileTheModuleWorks() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "keeper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let project = base.appending(path: "Тексты/Статья")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "первый".write(to: project.appending(path: "статья.md"), atomically: true, encoding: .utf8)
        let name = "versions-\(UUID().uuidString)"
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: name)))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        settings.activeSource = .folders(base.appending(path: "Тексты").path)
        let folders = FolderProjectStore(settings: settings)
        await folders.refresh()
        let store = VersionStore(root: base.appending(path: "store"))
        let keeper = VersionKeeper(settings: settings, folders: folders, store: store)

        // Switched off: nothing is kept.
        keeper.isActive = { false }
        keeper.takeBeforeRun(projectPath: project.path, title: "Редактура", now: now)
        await keeper.tick(now: now)
        #expect(store.versions(projectPath: project.path).isEmpty)

        keeper.isActive = { true }
        keeper.takeBeforeRun(projectPath: project.path, title: "Редактура", now: now)
        #expect(store.versions(projectPath: project.path).map(\.reason) == [.beforeRun("Редактура")])

        try "второй".write(to: project.appending(path: "статья.md"), atomically: true, encoding: .utf8)
        await keeper.tick(now: now.addingTimeInterval(60))
        #expect(store.versions(projectPath: project.path).map(\.reason) == [.automatic, .beforeRun("Редактура")])
        // Not due again five minutes later, even with a change.
        try "третий".write(to: project.appending(path: "статья.md"), atomically: true, encoding: .utf8)
        await keeper.tick(now: now.addingTimeInterval(360))
        #expect(store.versions(projectPath: project.path).count == 2)
        await keeper.tick(now: now.addingTimeInterval(700))
        #expect(store.versions(projectPath: project.path).count == 3)

        await keeper.refreshSize()
        #expect((keeper.diskSize ?? 0) > 0)
        await keeper.clear()
        #expect(keeper.diskSize == 0 && store.versions(projectPath: project.path).isEmpty)
    }

    @Test func aCommandTakesAVersionBeforeItStarts() throws {
        let bench = try CommandEngineJobsTests.Bench()
        defer { try? FileManager.default.removeItem(at: bench.folder) }
        var asked: [String] = []
        bench.engine.beforeRun = { path, title in asked.append("\(title) · \((path as NSString).lastPathComponent)") }
        _ = bench.run()
        #expect(asked == ["Хуки · \(bench.folder.lastPathComponent)"])
    }

    @Test func theAssistantTicksVersionsForFolderTemplates() {
        #expect(AssistantDraft.offeredModules.contains(.versions))
        #expect(!ModuleKind.versions.isPanelBlock && !ModuleKind.versions.isBuiltIn && ModuleKind.versions.definition.places.isEmpty)
    }
}
