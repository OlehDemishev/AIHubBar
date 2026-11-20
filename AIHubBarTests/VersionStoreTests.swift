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
