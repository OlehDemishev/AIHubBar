import SwiftUI

/// The panel's search: sessions, projects, quick commands and report commands by name, first match on ↵.
enum PanelSearch {
    enum Result: Identifiable, Equatable {
        case session(id: String, project: String, detail: String)
        case project(id: String, name: String, detail: String)
        case quickCommand(id: String, title: String)
        case command(CommonCommand)

        var id: String {
            switch self {
            case let .session(id, _, _): "s-" + id
            case let .project(id, _, _): "p-" + id
            case let .quickCommand(id, _): "q-" + id
            case let .command(command): "c-" + command.rawValue
            }
        }
    }

    struct Item: Equatable {
        var id: String
        var name: String
        var detail: String
    }

    static let limit = 12

    static func results(_ query: String, sessions: [Item], projects: [Item], quickCommands: [Item], commands: [CommonCommand]) -> [Result] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        // Typed on the wrong keyboard layout («ыгкм» for «surv») counts too.
        let queries = [query, swappedLayout(query)]
        func matches(_ item: Item) -> Bool {
            queries.contains { item.name.localizedStandardContains($0) || item.detail.localizedStandardContains($0) }
        }
        var results: [Result] = []
        results += sessions.filter(matches).map { .session(id: $0.id, project: $0.name, detail: $0.detail) }
        results += projects.filter(matches).map { .project(id: $0.id, name: $0.name, detail: $0.detail) }
        results += quickCommands.filter(matches).map { .quickCommand(id: $0.id, title: $0.name) }
        // The destructive cleanup keeps its confirmation in the commands block.
        results += commands.filter { command in command != .cleanupRun && queries.contains { command.title.localizedStandardContains($0) } }
            .map { .command($0) }
        return Array(results.prefix(limit))
    }

    private static let latin = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`")
    private static let cyrillic = Array("йцукенгшщзхъфывапролджэячсмитьбюё")

    /// The same keys on the other layout: Russian ЙЦУКЕН ↔ QWERTY.
    static func swappedLayout(_ text: String) -> String {
        String(text.lowercased().map { character in
            if let index = latin.firstIndex(of: character) { return cyrillic[index] }
            if let index = cyrillic.firstIndex(of: character) { return latin[index] }
            return character
        })
    }
}

/// The search field under the header.
struct PanelSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var onCancel: (() -> Void)?
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Найти проект, сессию, команду…", text: $query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(onSubmit)
                // Esc clears the query, and with nothing typed closes the search window.
                .onExitCommand { if query.isEmpty { onCancel?() } else { query = "" } }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Очистить поиск (Esc)")
            }
        }
        .scaledFont(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 8)
    }
}

/// What the search found; the first row is what ↵ does.
struct PanelSearchResults: View {
    let results: [PanelSearch.Result]
    let activate: (PanelSearch.Result) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if results.isEmpty {
                Text("Ничего не найдено")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                Button { activate(result) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol(result))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(title(result)).fontWeight(.medium).lineLimit(1)
                        Text(detail(result))
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if index == 0 {
                            Text(verbatim: "↵").foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(index == 0 ? Color.accentColor.opacity(0.15) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(hint(result))
            }
        }
        .padding(4)
    }

    private func symbol(_ result: PanelSearch.Result) -> String {
        switch result {
        case .session: "bubble.left.and.text.bubble.right"
        case .project: "folder"
        case .quickCommand: "bolt"
        case let .command(command): command.systemImage
        }
    }

    private func title(_ result: PanelSearch.Result) -> String {
        switch result {
        case let .session(_, project, _): project
        case let .project(_, name, _): name
        case let .quickCommand(_, title): title
        case let .command(command): command.title
        }
    }

    private func detail(_ result: PanelSearch.Result) -> String {
        switch result {
        case let .session(_, _, detail), let .project(_, _, detail): detail
        case .quickCommand: String(localized: "быстрая команда")
        case .command: String(localized: "команда")
        }
    }

    private func hint(_ result: PanelSearch.Result) -> String {
        switch result {
        case .session: String(localized: "Показать сессию")
        case .project: String(localized: "Раскрыть проект в панели")
        case .quickCommand, .command: String(localized: "Запустить")
        }
    }
}

/// The window the hot key opens: the same search, then it closes. A project opens in Terminal here (the panel
/// expands it instead).
struct QuickSearchWindow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @Environment(FolderProjectStore.self) private var folders
    @Environment(SessionStore.self) private var sessions
    @Environment(RunStore.self) private var runs
    @Environment(ModeStore.self) private var modes
    @Environment(QuickToolsController.self) private var quickTools
    @Environment(CommandStore.self) private var commands
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [PanelSearch.Result] {
        let sessionItems = SessionRow.rows(sessions: sessions.items, runs: runs.runs).map {
            PanelSearch.Item(id: $0.id, name: $0.project, detail: $0.task ?? "")
        }
        let projectItems = folders.isActive
            ? folders.projects.map { PanelSearch.Item(id: $0.path, name: $0.name, detail: "") }
            : store.projects.map { PanelSearch.Item(id: $0.path, name: $0.name, detail: $0.branch ?? "") }
        let quick = modes.installedModules.contains(.quickCommands)
            ? settings.quickCommands.map { PanelSearch.Item(id: $0.id, name: $0.title, detail: "") } : []
        let common = modes.panelModules.contains(.reports) ? CommonCommand.allCases : []
        return PanelSearch.results(query, sessions: sessionItems, projects: projectItems, quickCommands: quick, commands: common)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSearchField(query: $query, focused: $focused, onCancel: { dismiss() }) {
                if let first = results.first { activate(first) }
            }
            if !query.isEmpty {
                PanelSearchResults(results: results, activate: activate)
            }
        }
        .padding(.vertical, 10)
        .frame(width: 460)
        .onAppear {
            query = ""
            focused = true
        }
    }

    private func activate(_ result: PanelSearch.Result) {
        switch result {
        case let .session(id, _, _):
            if let session = sessions.items.first(where: { $0.id == id })?.session { SessionActions.show(session) }
        case let .project(id, _, _):
            ProjectActions.openInTerminal(id)
        case let .quickCommand(id, _):
            if let command = settings.quickCommands.first(where: { $0.id == id }) { quickTools.run(command) }
        case let .command(command):
            commands.run(command)
        }
        dismiss()
    }
}
