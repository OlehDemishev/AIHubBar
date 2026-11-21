import AppKit
import SwiftUI

/// «Версии»: a folder project's draft versions by time, a file of a version against the same file now, and putting
/// a file or a whole version back (docs/specs/SPEC-content.md §4). Opened from the project's card, and by «Что
/// изменилось» of a run — then on the version taken before it.
struct VersionsWindow: View {
    @Environment(VersionKeeper.self) private var keeper
    @Environment(FolderProjectStore.self) private var folders
    @State private var versions: [ProjectVersion] = []
    /// Path → hash of the project's files as they are now.
    @State private var current: [String: String] = [:]
    @State private var isLoaded = false
    @State private var selected: String?
    @State private var file: String?
    @State private var rows: [TextCompare.Row]?
    @State private var cut = false
    @State private var unreadable = false
    @State private var changedOnly = false
    @State private var note: Note?
    /// Bumped when the files on disk changed (a restore, an edit elsewhere), so the comparison is read again.
    @State private var serial = 0

    private struct Note: Equatable {
        var text: String
        var isError: Bool
    }

    /// One row of the file picker: a file of the version, or one that appeared later.
    struct Entry: Identifiable, Equatable {
        enum Status { case changed, missing, same, added }

        var path: String
        var hash: String?
        var status: Status
        var id: String { path }

        var label: String {
            switch status {
            case .changed: String(localized: "\(path) — изменён с тех пор")
            case .missing: String(localized: "\(path) — сейчас нет в папке")
            case .same: String(localized: "\(path) — как сейчас")
            case .added: String(localized: "\(path) — появился позже")
            }
        }

        static func list(_ version: ProjectVersion, current: [String: String]) -> [Entry] {
            version.files.map { file in
                Entry(path: file.path, hash: file.hash,
                      status: current[file.path] == nil ? .missing : current[file.path] == file.hash ? .same : .changed)
            } + version.added(in: current).map { Entry(path: $0, hash: nil, status: .added) }
        }

        /// The file to show first: one that differs, else one that appeared, else the first.
        static func first(_ entries: [Entry]) -> String? {
            (entries.first { $0.status == .changed || $0.status == .missing } ?? entries.first { $0.status == .added } ?? entries.first)?.path
        }
    }

    private struct CompareKey: Equatable {
        /// Versions of two projects taken in one pass share an id, so the project is part of the key.
        var project: String?
        var version: String?
        var file: String?
        var serial: Int
    }

    private var version: ProjectVersion? { versions.first { $0.id == selected } }
    private var entries: [Entry] { version.map { Entry.list($0, current: current) } ?? [] }
    private var entry: Entry? { entries.first { $0.path == file } }

    var body: some View {
        Group {
            if let shown = keeper.shown {
                if isLoaded, versions.isEmpty {
                    Text("У этого проекта пока нет версий. Они появляются перед запуском AI и когда тексты меняются.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content(shown)
                }
            } else {
                Text("Нет выбранного проекта")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .task(id: folders.projects.first?.path) {
            // Opened from outside the card (`--app-command versions`): the profile's first folder project.
            if keeper.shown == nil, let first = folders.projects.first { keeper.shown = .init(projectPath: first.path) }
        }
        .task(id: keeper.shown) {
            isLoaded = false
            note = nil
            await reload(pick: true)
        }
        .task(id: CompareKey(project: keeper.shown?.projectPath, version: selected, file: file, serial: serial)) { await compare() }
        .onChange(of: keeper.taken) {
            // A version taken while the window is open joins the list; the selection stays.
            Task { await reload(pick: false) }
        }
        .onChange(of: selected) {
            // Another version: keep the file if it has it, else the first one that differs.
            if entry == nil { file = Entry.first(entries) }
            // The files may have changed since the list was read: «как сейчас» must be about now.
            Task { await reload(pick: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Back from the editor: what the files are now is read again.
            Task { await reload(pick: false) }
        }
    }

    private func content(_ shown: VersionKeeper.Shown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if folders.projects.count > 1, folders.projects.contains(where: { $0.path == shown.projectPath }) {
                    // The profile's other folder projects are one click away.
                    Picker("Проект", selection: Binding(get: { shown.projectPath }, set: { keeper.shown = .init(projectPath: $0) })) {
                        ForEach(folders.projects) { Text(verbatim: $0.name).tag($0.path) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(verbatim: (shown.projectPath as NSString).lastPathComponent).font(.headline).lineLimit(1)
                }
                Text(verbatim: PathText.tilde(shown.projectPath)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                List(versions, selection: $selected) { version in
                    row(version).tag(version.id)
                }
                .frame(width: 250)
                .accessibilityLabel("Версии")
                Divider()
                if let version {
                    detail(version, shown: shown)
                } else {
                    Color.clear
                }
            }
        }
    }

    private func row(_ version: ProjectVersion) -> some View {
        let differs = version.differing(from: current).count + version.added(in: current).count
        return VStack(alignment: .leading, spacing: 2) {
            Text(version.takenAt.formatted(date: .abbreviated, time: .shortened))
            Text(verbatim: version.reason.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(differs == 0 ? String(localized: "как сейчас") : String(localized: "файлов с отличиями: \(differs)"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ version: ProjectVersion, shown: VersionKeeper.Shown) -> some View {
        let taken = version.takenAt.formatted(date: .abbreviated, time: .shortened)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Файл", selection: $file) {
                    ForEach(entries) { Text(verbatim: $0.label).tag(Optional($0.path)) }
                }
                .fixedSize()
                Spacer()
                Toggle("Только отличия", isOn: $changedOnly)
                    .toggleStyle(.checkbox)
                    .help("Скрыть строки, которые не менялись")
            }
            if !version.skipped.isEmpty {
                Text("Не сохранены из-за размера: \(version.skipped.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 1) {
                Text("Версия: \(taken)").frame(maxWidth: .infinity, alignment: .leading)
                Text("Сейчас").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            comparison
            footer(version, taken: taken, shown: shown)
        }
        .padding(12)
    }

    @ViewBuilder private var comparison: some View {
        if unreadable {
            notice(String(localized: "Не удалось прочитать файл из версии."))
        } else if let rows {
            let visible = changedOnly ? rows.filter(\.isChanged) : rows
            if !rows.contains(where: \.isChanged) {
                notice(String(localized: "Файл такой же, как сейчас."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { row in
                            HStack(alignment: .top, spacing: 1) {
                                cell(row.old, tint: row.isChanged ? .red : nil)
                                cell(row.new, tint: row.isChanged ? .green : nil)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Self.spoken(row))
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
                if cut {
                    Text("Сравнивается начало файлов: строк \(TextCompare.lineLimit).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notice(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ text: String?, tint: Color?) -> some View {
        Text(verbatim: text.map { $0.isEmpty ? " " : $0 } ?? " ")
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // A side without the line stays plain: the colour marks only what is there.
            .background(text == nil ? Color.clear : (tint ?? .clear).opacity(0.16))
    }

    /// What VoiceOver says of a row: the colours and the sides are not heard.
    nonisolated static func spoken(_ row: TextCompare.Row) -> String {
        guard row.isChanged else { return row.new ?? "" }
        switch (row.old, row.new) {
        case let (old?, new?): return String(localized: "Было: \(old). Сейчас: \(new)")
        case let (old?, nil): return String(localized: "Убрано: \(old)")
        case let (nil, new?): return String(localized: "Добавлено: \(new)")
        case (nil, nil): return ""
        }
    }

    private func footer(_ version: ProjectVersion, taken: String, shown: VersionKeeper.Shown) -> some View {
        let differing = version.differing(from: current)
        return HStack(spacing: 8) {
            if let note {
                Label { Text(verbatim: note.text) } icon: { Image(systemName: note.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") }
                    .font(.caption)
                    .foregroundStyle(note.isError ? .orange : .green)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let entry, entry.status != .missing {
                Button("Открыть файл") { NSWorkspace.shared.open(URL(fileURLWithPath: shown.projectPath).appending(path: entry.path)) }
                    .help("Открыть файл, как он есть сейчас")
            }
            if let entry, entry.hash != nil {
                ConfirmedButton(
                    title: "Вернуть этот файл?",
                    message: String(localized: "«\(entry.path)» станет таким, как в версии от \(taken). То, что есть сейчас, сначала сохранится отдельной версией."),
                    confirm: "Вернуть", role: nil
                ) {
                    restore(version, paths: [entry.path], in: shown.projectPath)
                } label: { Text("Вернуть этот файл") }
                .disabled(entry.status == .same)
            }
            ConfirmedButton(
                title: "Вернуть всю версию?",
                message: String(localized: "Файлов: \(differing.count) — станут такими, как в версии от \(taken). То, что есть сейчас, сначала сохранится отдельной версией. Файлы, которые появились позже, останутся."),
                confirm: "Вернуть", role: nil
            ) {
                restore(version, paths: nil, in: shown.projectPath)
            } label: { Text("Вернуть всю версию") }
            .disabled(differing.isEmpty)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Work

    private func reload(pick: Bool) async {
        guard let shown = keeper.shown else { return }
        let loaded = await keeper.load(projectPath: shown.projectPath)
        guard keeper.shown == shown else { return }
        versions = loaded.versions
        // The files changed on disk: the comparison on screen is read again too.
        if isLoaded, loaded.current != current { serial += 1 }
        current = loaded.current
        isLoaded = true
        if pick || version == nil {
            let before = shown.before.flatMap { date in versions.first { $0.takenAt <= date.addingTimeInterval(1) } }
            selected = (before ?? versions.first)?.id
            // «Что изменилось» of a run: only what the run touched.
            if before != nil { changedOnly = true }
        }
        if entry == nil { file = Entry.first(entries) }
    }

    private func compare() async {
        rows = nil
        unreadable = false
        guard let shown = keeper.shown, let entry else { return }
        let result = await keeper.compare(projectPath: shown.projectPath, path: entry.path, hash: entry.hash)
        guard !Task.isCancelled else { return }
        if let result {
            rows = result.rows
            cut = result.cut
        } else {
            unreadable = true
        }
    }

    private func restore(_ version: ProjectVersion, paths: Set<String>?, in projectPath: String) {
        Task {
            do {
                let restored = try await keeper.restore(projectPath: projectPath, version: version, paths: paths)
                note = Note(text: String(localized: "Возвращено файлов: \(restored.count). То, что было до этого, сохранено в списке версий."), isError: false)
            } catch {
                note = Note(text: error.localizedDescription, isError: true)
            }
            await reload(pick: false)
        }
    }
}
