import SwiftUI

/// «История буфера» in the panel: search, a click copies the entry back, pin, remove, clear.
struct ClipboardView: View {
    @Environment(ClipboardHistory.self) private var history
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""
    @State private var query = ""
    @State private var copied: String?

    private var shown: [ClipItem] {
        let found = query.isEmpty ? history.items : history.items.filter { $0.text.localizedCaseInsensitiveContains(query) }
        return Array((found.filter(\.pinned) + found.filter { !$0.pinned }).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                BlockTitle(block: .clipboard, title: "История буфера")
                if !history.items.isEmpty {
                    Text(verbatim: "\(history.items.count)").scaledFont(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if !history.items.isEmpty {
                    Button("Очистить") { history.clear() }
                        .buttonStyle(.link)
                        .scaledFont(.caption)
                        .help("Удалить всё, кроме закреплённого")
                }
            }
            if !PanelBlock.collapsed(in: collapsedRaw).contains(.clipboard) {
                if history.items.isEmpty {
                    Text("Пока пусто: скопируйте что-нибудь. Пароли из менеджеров паролей не запоминаются.")
                        .scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("Поиск", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    ForEach(shown) { item in row(item) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func row(_ item: ClipItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind == .files ? "doc" : (item.pinned ? "pin.fill" : "doc.on.clipboard"))
                .foregroundStyle(item.pinned ? Color.orange : .secondary)
                .frame(width: 14)
                .help(item.pinned ? String(localized: "Закреплено") : item.kind == .files ? String(localized: "Скопированные файлы") : String(localized: "Скопированный текст"))
            Button {
                history.copy(item)
                copied = item.id
            } label: {
                Text(item.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Скопировать") + (item.sourceApp.map { " · \($0)" } ?? ""))
            if copied == item.id {
                Text("скопировано").foregroundStyle(.green)
            } else {
                Text(RelativeTime.ago(item.date, now: .now)).foregroundStyle(.tertiary)
            }
            Button { history.togglePin(item) } label: { Image(systemName: item.pinned ? "pin.slash" : "pin") }
                .help(item.pinned ? "Открепить" : "Закрепить")
            Button { history.remove(item) } label: { Image(systemName: "xmark") }
                .help("Удалить")
        }
        .buttonStyle(.borderless)
        .scaledFont(.caption)
    }
}

/// «Заметки» in the panel: tabs over Markdown files, an editor, a new note, open in an editor, to the Trash.
struct NotesView: View {
    @Environment(NotesStore.self) private var notes
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""
    @State private var confirmingTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                BlockTitle(block: .notes, title: "Заметки")
                Spacer()
                Button { notes.create() } label: { Image(systemName: "plus") }
                    .help("Новая заметка")
                Button { notes.openInEditor() } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Открыть в редакторе")
                Button { confirmingTrash = true } label: { Image(systemName: "trash") }
                    .help("В корзину")
                    .disabled(notes.selected == nil)
            }
            .buttonStyle(.borderless)
            if !PanelBlock.collapsed(in: collapsedRaw).contains(.notes) {
                if notes.names.count > 1 {
                    Picker("", selection: Binding(get: { notes.selected ?? "" }, set: { notes.select($0) })) {
                        ForEach(notes.names, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                TextEditor(text: Binding(get: { notes.text }, set: { notes.edit($0) }))
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 140)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                if confirmingTrash, let name = notes.selected {
                    HStack(spacing: 6) {
                        Text("«\(name)» — в корзину?").scaledFont(.caption)
                        Spacer()
                        Button("Отмена") { confirmingTrash = false }
                        Button("В корзину") {
                            confirmingTrash = false
                            notes.trashSelected()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onAppear { notes.reload() }
        .onDisappear { notes.flush() }
    }
}
