import Foundation
import Testing
@testable import ClaudePult

/// SPEC-profiles second wave: «История буфера» and «Заметки».
struct ClipboardNotesTests {
    @Test func secretsAreNotRecorded() {
        let excluded = ClipboardPolicy.defaultExcludedApps
        #expect(ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], frontmostApp: "com.apple.Safari", excludedApps: excluded))
        #expect(!ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], frontmostApp: "com.apple.Safari", excludedApps: excluded),
                "a password manager marks its copies as concealed")
        #expect(!ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], frontmostApp: "com.1password.1password", excludedApps: excluded))
        #expect(!ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], frontmostApp: "com.apple.Passwords", excludedApps: excluded))
        #expect(!ClipboardPolicy.shouldRecord(types: ["org.nspasteboard.TransientType"], frontmostApp: nil, excludedApps: []))
    }

    @Test func historyKeepsPinnedAndMovesRepeatsUp() {
        func item(_ text: String, pinned: Bool = false) -> ClipItem { ClipItem(kind: .text, text: text, date: .now, pinned: pinned) }
        var items: [ClipItem] = []
        items = ClipboardPolicy.adding(item("a"), to: items, limit: 2)
        items = ClipboardPolicy.adding(item("b", pinned: true), to: items, limit: 2)
        items = ClipboardPolicy.adding(item("c"), to: items, limit: 2)
        items = ClipboardPolicy.adding(item("d"), to: items, limit: 2)
        #expect(items.map(\.text) == ["d", "c", "b"], "two unpinned kept, the pinned one stays")
        items = ClipboardPolicy.adding(item("b"), to: items, limit: 2)
        #expect(items.map(\.text) == ["b", "d", "c"] && items[0].pinned, "a repeat moves up and stays pinned")
        #expect(ClipboardPolicy.adding(item("  \n"), to: items, limit: 2) == items, "blank copies are ignored")
    }

    @Test func noteNamesAndFreeNames() {
        #expect(NotesStore.noteNames(in: ["Б.md", "а.md", ".hidden.md", "x.txt", "Заметка 10.md", "Заметка 2.md"]) == ["а", "Б", "Заметка 2", "Заметка 10"])
        #expect(NotesStore.freeName("Заметка", taken: []) == "Заметка")
        #expect(NotesStore.freeName("Заметка", taken: ["Заметка", "Заметка 2"]) == "Заметка 3")
    }
}

@MainActor
struct NotesStoreTests {
    @Test func writeReadAndTrash() async throws {
        let name = "claudepult-notes-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: dir) }
        settings.notesFolder = dir.path
        let notes = NotesStore(settings: settings)
        notes.isActive = { true }
        notes.discard = { try FileManager.default.removeItem(at: $0) } // not the real Trash
        notes.reload()
        let first = try #require(notes.selected)
        #expect(notes.names == [first], "an empty folder gets a first note")
        notes.edit("# План\n- пункт")
        notes.flush()
        #expect(try String(contentsOf: notes.url(first), encoding: .utf8) == "# План\n- пункт")
        notes.create()
        #expect(notes.names.count == 2 && notes.text.isEmpty)
        notes.select(first)
        #expect(notes.text == "# План\n- пункт")
        notes.trashSelected()
        #expect(!FileManager.default.fileExists(atPath: notes.url(first).path) && notes.names.count == 1)
    }
}
