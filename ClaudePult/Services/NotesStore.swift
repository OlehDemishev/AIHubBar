import AppKit
import Foundation
import Observation

/// «Заметки» (SPEC-profiles §3, second wave): Markdown files in one folder, one tab each. Plain files, so any
/// editor opens them; ClaudePult only lists, edits, creates and moves them to the Trash.
@MainActor
@Observable
final class NotesStore {
    private(set) var names: [String] = []
    private(set) var text = ""
    private(set) var selected: String?
    var isActive: () -> Bool = { false }
    /// To the Trash in the app; tests swap it so they don't fill the real Trash.
    var discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    private let settings: AppSettings
    private var pendingSave: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var folder: URL { URL(fileURLWithPath: PathText.expand(settings.notesFolder), isDirectory: true) }

    func url(_ name: String) -> URL { folder.appending(path: name + ".md") }

    /// Reads the folder (made on first use) and the selected note.
    func reload() {
        guard isActive() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        names = Self.noteNames(in: (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        if names.isEmpty {
            create()
            return
        }
        let wanted = UserDefaults.standard.string(forKey: "notesSelected")
        select(wanted.flatMap { names.contains($0) ? $0 : nil } ?? names[0])
    }

    nonisolated static func noteNames(in files: [String]) -> [String] {
        files.filter { $0.lowercased().hasSuffix(".md") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(3)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// «Заметка», «Заметка 2», … — the first free name.
    nonisolated static func freeName(_ base: String, taken: [String]) -> String {
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    func select(_ name: String) {
        flush()
        selected = name
        UserDefaults.standard.set(name, forKey: "notesSelected")
        text = (try? String(contentsOf: url(name), encoding: .utf8)) ?? ""
    }

    func create() {
        flush()
        let name = Self.freeName(String(localized: "Заметка"), taken: names)
        FileManager.default.createFile(atPath: url(name).path, contents: Data())
        names = (names + [name]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        select(name)
    }

    /// Edits are written a second after the last keystroke, and when switching tabs or closing the panel.
    func edit(_ newText: String) {
        text = newText
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let selected else { return }
        let target = url(selected)
        if (try? String(contentsOf: target, encoding: .utf8)) != text {
            try? text.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    /// To the Trash, not deleted: a note removed by mistake can be put back.
    func trashSelected() {
        guard let selected else { return }
        pendingSave?.cancel()
        try? discard(url(selected))
        self.selected = nil
        text = ""
        reload()
    }

    func openInEditor() {
        flush()
        if let selected { NSWorkspace.shared.open(url(selected)) }
    }
}
