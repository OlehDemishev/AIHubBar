import AppKit
import SwiftUI

// «Заметки» (docs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let notes = ModuleDefinition(
        kind: .notes,
        group: .work,
        symbol: "note.text",
        title: String(localized: "Заметки"),
        summary: String(localized: "Заметки в Markdown прямо в панели: вкладки, обычные файлы .md в папке, которую откроет любой редактор."),
        tagline: String(localized: "Markdown прямо в панели"),
        keywords: [String(localized: "Папка")]
    )
}

extension ModuleUI {
    static let notes = ModuleUI(
        settings: { AnyView(NotesSection()) },
        sketch: { AnyView(NotesSketch()) }
    )
}

/// «Панель сейчас»: how many notes.
private struct NotesSketch: View {
    @Environment(NotesStore.self) private var notes

    var body: some View {
        SketchLine(String(localized: "Заметок: \(notes.names.count)"))
    }
}

struct NotesSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NotesStore.self) private var notes

    var body: some View {
        Section {
            IconRow("Папка", systemImage: "folder") {
                HStack {
                    Text(settings.notesFolder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Выбрать…", action: chooseFolder)
                    Button("Показать в Finder") {
                        try? FileManager.default.createDirectory(at: notes.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(notes.folder)
                    }
                }
            }
        } header: {
            Text("Заметки")
        } footer: {
            Footnote(text: String(localized: "Каждая заметка — файл .md в этой папке; удалённые уходят в корзину. Папку можно положить в iCloud Drive, чтобы заметки были и на других Маках."))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Выбрать")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        notes.flush()
        settings.notesFolder = PathText.tilde(url.path)
        notes.reload()
    }
}
