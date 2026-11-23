import AppKit
import Foundation
import Testing
@testable import AIHubBar

/// «Версии» in the card: putting a version back, the side-by-side comparison and «Что изменилось»
/// (SPEC-content §4, stage 3).
struct VersionRestoreTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func setUp() throws -> (store: VersionStore, project: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "restore-\(UUID().uuidString)")
        let project = base.appending(path: "Projects/Ролик про кофе")
        try FileManager.default.createDirectory(at: project.appending(path: "черновики"), withIntermediateDirectories: true)
        try "идея".write(to: project.appending(path: "проект.md"), atomically: true, encoding: .utf8)
        try "первый вариант".write(to: project.appending(path: "черновики/сценарий.md"), atomically: true, encoding: .utf8)
        return (VersionStore(root: base.appending(path: "store")), project, base)
    }

    private func read(_ project: URL, _ path: String) -> String? { try? String(contentsOf: project.appending(path: path), encoding: .utf8) }

    @Test func aWholeVersionComesBackAndTheCurrentStateIsKept() throws {
        let (store, project, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try #require(try store.take(projectPath: project.path, reason: .beforeRun("Редактура"), now: now))

        // The run rewrote the script, removed the card and left a result.
        try "после AI".write(to: project.appending(path: "черновики/сценарий.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: project.appending(path: "проект.md"))
        try "итог".write(to: project.appending(path: "редактура.md"), atomically: true, encoding: .utf8)

        let restored = try store.restore(projectPath: project.path, version: first, now: now.addingTimeInterval(60))
        #expect(restored.sorted() == ["проект.md", "черновики/сценарий.md"])
        #expect(read(project, "черновики/сценарий.md") == "первый вариант")
        #expect(read(project, "проект.md") == "идея")
        #expect(read(project, "редактура.md") == "итог", "a file added since stays")

        // What was there before the restore is a version of its own.
        let versions = store.versions(projectPath: project.path)
        #expect(versions.map(\.reason) == [.beforeRestore, .beforeRun("Редактура")])
        let kept = try #require(versions[0].files.first { $0.path == "черновики/сценарий.md" })
        #expect(store.content(projectPath: project.path, hash: kept.hash) == Data("после AI".utf8))

        // Nothing differs now: a second restore writes nothing and takes no version.
        #expect(try store.restore(projectPath: project.path, version: first, now: now.addingTimeInterval(120)).isEmpty)
        #expect(store.versions(projectPath: project.path).count == 2)
    }

    @Test func oneFileComesBackAlone() throws {
        let (store, project, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try #require(try store.take(projectPath: project.path, reason: .automatic, now: now))
        try "новая идея".write(to: project.appending(path: "проект.md"), atomically: true, encoding: .utf8)
        try "второй вариант".write(to: project.appending(path: "черновики/сценарий.md"), atomically: true, encoding: .utf8)

        #expect(try store.restore(projectPath: project.path, version: first, paths: ["проект.md"], now: now.addingTimeInterval(60)) == ["проект.md"])
        #expect(read(project, "проект.md") == "идея")
        #expect(read(project, "черновики/сценарий.md") == "второй вариант", "the other file is not touched")
    }

    @Test func nothingIsWrittenWhenARestoreCannotBeSafe() throws {
        let (store, project, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try #require(try store.take(projectPath: project.path, reason: .automatic, now: now))
        try "новая идея".write(to: project.appending(path: "проект.md"), atomically: true, encoding: .utf8)

        // The file as it is now is over the limit: it could not be saved first, so it is left alone.
        try String(repeating: "я", count: 400).write(to: project.appending(path: "черновики/сценарий.md"), atomically: true, encoding: .utf8)
        #expect(throws: VersionStore.RestoreError.currentTooLarge("черновики/сценарий.md")) {
            try store.restore(projectPath: project.path, version: first, now: now.addingTimeInterval(60), sizeLimit: 100)
        }
        #expect(read(project, "проект.md") == "новая идея", "the other file was not put back either")
        #expect(store.versions(projectPath: project.path).count == 1)

        // A version that names a path outside the folder, or a content that is gone.
        var outside = first
        outside.files[0].path = "../чужое.md"
        #expect(throws: VersionStore.RestoreError.missingContent("../чужое.md")) {
            try store.restore(projectPath: project.path, version: outside, now: now.addingTimeInterval(60))
        }
        #expect(!FileManager.default.fileExists(atPath: project.deletingLastPathComponent().appending(path: "чужое.md").path))
        #expect(VersionStore.isSafe("черновики/сценарий.md") && !VersionStore.isSafe("/etc/hosts") && !VersionStore.isSafe("a/../../b") && !VersionStore.isSafe(""))
    }

    @Test func theVersionBeforeARunIsTheNewestNotLaterThanItsStart() throws {
        let (store, project, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try #require(try store.take(projectPath: project.path, reason: .automatic, now: now))
        try "второй вариант".write(to: project.appending(path: "черновики/сценарий.md"), atomically: true, encoding: .utf8)
        let second = try #require(try store.take(projectPath: project.path, reason: .beforeRun("Редактура"), now: now.addingTimeInterval(600)))

        #expect(store.version(projectPath: project.path, before: now.addingTimeInterval(300))?.id == first.id)
        #expect(store.version(projectPath: project.path, before: now.addingTimeInterval(600.2))?.id == second.id, "taken a moment before the run started")
        #expect(store.version(projectPath: project.path, before: now.addingTimeInterval(-60)) == nil)
    }

    @Test func filesOfAVersionAgainstNow() throws {
        let version = ProjectVersion(id: "v", takenAt: now, reason: .automatic, files: [
            VersionFile(path: "а.md", hash: "1", size: 1, modified: now),
            VersionFile(path: "б.md", hash: "2", size: 1, modified: now),
            VersionFile(path: "в.md", hash: "3", size: 1, modified: now),
        ])
        let current = ["а.md": "1", "б.md": "22", "итог.md": "9"]
        #expect(version.differing(from: current) == ["б.md", "в.md"])
        #expect(version.added(in: current) == ["итог.md"])

        let entries = VersionsWindow.Entry.list(version, current: current)
        #expect(entries.map(\.status) == [.same, .changed, .missing, .added])
        #expect(entries.last?.hash == nil, "a later file has nothing to put back")
        #expect(VersionsWindow.Entry.first(entries) == "б.md", "the first file that differs opens first")
        #expect(VersionsWindow.Entry.first(VersionsWindow.Entry.list(version, current: ["а.md": "1", "б.md": "2", "в.md": "3", "итог.md": "9"])) == "итог.md")
    }

    @Test func textsSideBySide() {
        let old = "Заголовок\n\nПервый абзац.\nВторой абзац.\nКонец."
        let new = "Заголовок\n\nПервый абзац, длиннее.\nКонец.\nПостскриптум."
        let rows = TextCompare.rows(old: old, new: new).rows
        #expect(rows.map(\.old) == ["Заголовок", "", "Первый абзац.", "Второй абзац.", "Конец.", nil])
        #expect(rows.map(\.new) == ["Заголовок", "", "Первый абзац, длиннее.", nil, "Конец.", "Постскриптум."])
        #expect(rows.map(\.isChanged) == [false, false, true, true, false, true])

        #expect(TextCompare.rows(old: "", new: "").rows.contains(where: \.isChanged) == false)
        #expect(TextCompare.rows(old: "а\r\nб", new: "а\nб").rows.contains(where: \.isChanged) == false, "line endings are not a change")
        let long = TextCompare.rows(old: "", new: Array(repeating: "строка", count: 30).joined(separator: "\n"), limit: 10)
        #expect(long.cut && long.rows.count == 10)

        #expect(VersionsWindow.spoken(rows[2]) == "Было: Первый абзац.. Сейчас: Первый абзац, длиннее.")
        #expect(VersionsWindow.spoken(rows[0]) == "Заголовок")
    }

    @Test func aFormattedFileIsReadAsText() throws {
        let rtf = try NSAttributedString(string: "Текст в RTF").data(
            from: NSRange(location: 0, length: 11), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #expect(TextCompare.text(of: rtf, path: "заметки.rtf") == "Текст в RTF")
        #expect(TextCompare.text(of: Data("просто".utf8), path: "заметки.md") == "просто")
    }

    @Test func aCommandsNotificationOffersWhatChanged() {
        let started = Date(timeIntervalSince1970: 1_795_000_000)
        let target = NotificationTarget.commandResult(path: "/P/Ролик/редактура.md", project: "/P/Ролик", started: started, versions: true)
        #expect(target == .result(path: "/P/Ролик/редактура.md", project: "/P/Ролик", started: started))
        #expect(NotificationTarget(userInfo: target.userInfo) == target)
        #expect(target.category == NotificationAction.resultCategory)
        #expect(NotificationAction.resolve(target, action: "com.apple.UNNotificationDefaultActionIdentifier") == .openFile(path: "/P/Ролик/редактура.md"))
        #expect(NotificationAction.resolve(target, action: NotificationAction.changes) == .openChanges(projectPath: "/P/Ролик", before: started))
        // Without the module the notification is what it was.
        #expect(NotificationTarget.commandResult(path: "/a.md", project: "/P", started: started, versions: false) == .file(path: "/a.md"))
    }
}
