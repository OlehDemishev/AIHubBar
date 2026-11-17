import AppKit
import SwiftUI

/// «Claude Code» window: every CLAUDE.md / AGENTS.md in one place, and the MCP servers with an on/off switch.
struct ClaudeConfigWindow: View {
    @Environment(ClaudeConfigStore.self) private var config
    @AppStorage(StorageKey.claudeConfigTab) private var tab = "instructions"

    var body: some View {
        TabView(selection: $tab) {
            InstructionsView()
                .tabItem { Label("Инструкции", systemImage: "doc.text") }
                .tag("instructions")
            MCPServersView()
                .tabItem { Label("MCP-серверы", systemImage: "puzzlepiece") }
                .tag("mcp")
            AgentExtrasView()
                .tabItem { Label("Skills и плагины", systemImage: "wand.and.stars") }
                .tag("extras")
        }
        .padding(8)
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            config.reload()
            config.reloadExtras()
        }
        .alert("Не получилось", isPresented: Binding(get: { config.lastError != nil }, set: { if !$0 { config.lastError = nil } })) {
            Button("OK") { config.lastError = nil }
        } message: {
            Text(config.lastError ?? "")
        }
    }
}

// MARK: - Instructions

private struct InstructionsView: View {
    @Environment(ClaudeConfigStore.self) private var config
    @State private var selection: String?
    @State private var query = ""

    private var shown: [InstructionFile] {
        query.isEmpty ? config.files : config.files.filter { !InstructionFile.matches(config.texts[$0.path] ?? "", query: query).isEmpty }
    }

    private var selected: InstructionFile? { config.files.first { $0.path == selection } }
    private var changed: Bool { selected.map { config.drafts[$0.path] != nil } ?? false }
    private var draft: String { selected.map { config.text(of: $0.path) } ?? "" }
    private var editor: Binding<String> {
        Binding(get: { draft }, set: { text in
            if let path = selected?.path { config.edit(text, of: path) }
        })
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 6) {
                TextField("Искать во всех файлах", text: $query)
                    .textFieldStyle(.roundedBorder)
                List(selection: $selection) {
                    ForEach(Array(Dictionary(grouping: shown, by: \.group).sorted { order($0.key) < order($1.key) }), id: \.key) { group, files in
                        Section(group) {
                            ForEach(files) { file in
                                HStack {
                                    Text(file.title)
                                    if config.drafts[file.path] != nil {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 6))
                                            .foregroundStyle(.orange)
                                            .help("Есть несохранённые правки")
                                            .accessibilityLabel("Есть несохранённые правки")
                                    }
                                    Spacer()
                                    if !query.isEmpty {
                                        Text("\(InstructionFile.matches(config.texts[file.path] ?? "", query: query).count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(file.path)
                                .help(file.path)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                if shown.isEmpty {
                    Text(query.isEmpty ? String(localized: "Файлов инструкций не нашлось") : String(localized: "Нигде не встречается"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

            VStack(alignment: .leading, spacing: 6) {
                if let file = selected {
                    HStack {
                        Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
                        Button("Открыть в редакторе") { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
                        Button("Сохранить") { config.save(draft, to: file) }
                            .keyboardShortcut("s", modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(!changed)
                    }
                    .controlSize(.small)
                    let hits = InstructionFile.matches(draft, query: query)
                    if !hits.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(hits.prefix(30), id: \.line) { hit in
                                    Text("\(hit.line): \(hit.text)").font(.caption.monospaced()).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                    }
                    TextEditor(text: editor)
                        .font(.body.monospaced())
                } else {
                    Text("Выберите файл слева").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.leading, 6)
            .frame(minWidth: 420)
        }
        .onAppear {
            if selection == nil { selection = config.files.first?.path }
        }
    }

    /// «Общие» first, then projects by name.
    private func order(_ group: String) -> String { group == String(localized: "Общие") ? "" : group.lowercased() }
}

// MARK: - MCP

private struct MCPServersView: View {
    @Environment(ClaudeConfigStore.self) private var config

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if config.servers.isEmpty {
                ContentUnavailableView("MCP-серверов нет", systemImage: "puzzlepiece",
                                       description: Text("Добавляются командой claude mcp add или файлом .mcp.json в проекте."))
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.servers) { server in
                                MCPServerRow(server: server)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Обновить") { config.reload() }
                Spacer()
                Text("Выключенный сервер AI Hub Bar помнит целиком и возвращает как был. Новые настройки подхватит следующая сессия Claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private var groups: [(title: String, servers: [MCPServer])] {
        var result: [(String, [MCPServer])] = []
        let general = config.servers.filter { $0.scope.projectPath == nil }
        if !general.isEmpty { result.append((String(localized: "Для всех проектов"), general)) }
        let byProject = Dictionary(grouping: config.servers.filter { $0.scope.projectPath != nil }) { $0.scope.projectPath ?? "" }
        for (path, servers) in byProject.sorted(by: { $0.key < $1.key }) {
            result.append((config.projectName(path), servers))
        }
        return result
    }
}

private struct MCPServerRow: View {
    let server: MCPServer
    @Environment(ClaudeConfigStore.self) private var config

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name).fontWeight(.medium)
                    Text(server.transport).font(.caption).foregroundStyle(.secondary)
                    if server.status == .pending {
                        Text("ждёт разрешения в Claude").font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(server.target).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(server.scope.title).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if config.busy.contains(server.id) {
                ProgressView().controlSize(.small)
            }
            Toggle("", isOn: Binding(
                get: { server.status != .off },
                set: { on in Task { await config.setEnabled(server, on) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(config.busy.contains(server.id))
            .help(server.status == .off ? String(localized: "Включить «\(server.name)»") : String(localized: "Выключить «\(server.name)»"))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Skills, plugins, hooks

/// What else is added to Claude Code and Codex: skills and plugins with a switch, hooks to look at.
private struct AgentExtrasView: View {
    @Environment(ClaudeConfigStore.self) private var config

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if config.skills.isEmpty, config.plugins.isEmpty, config.hooks.isEmpty {
                ContentUnavailableView("Ничего не установлено", systemImage: "wand.and.stars",
                                       description: Text("Skills лежат в ~/.claude/skills и ~/.codex/skills, плагины ставятся командой /plugin в Claude Code."))
            } else {
                List {
                    ForEach([AgentKind.claudeCode, .codex], id: \.self) { agent in
                        let skills = config.skills.filter { $0.agent == agent }
                        if !skills.isEmpty {
                            Section("Skills — \(agent.title)") {
                                ForEach(skills) { skill in
                                    ExtraRow(title: skill.name, detail: skill.description, note: nil, isOn: skill.isOn) { config.setEnabled(skill, $0) }
                                }
                            }
                        }
                    }
                    if !config.plugins.isEmpty {
                        Section("Плагины — \(AgentKind.claudeCode.title)") {
                            ForEach(config.plugins) { plugin in
                                ExtraRow(title: plugin.name, detail: plugin.marketplace, note: plugin.version.isEmpty ? nil : plugin.version,
                                         isOn: plugin.isOn) { config.setEnabled(plugin, $0) }
                            }
                        }
                    }
                    if !config.hooks.isEmpty {
                        Section("Hooks") {
                            ForEach(config.hooks) { hook in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(hook.event).fontWeight(.medium)
                                        Text(hook.agent.title).font(.caption).foregroundStyle(.secondary)
                                        if hook.isOurs { Text("AI Hub Bar").font(.caption).foregroundStyle(.tint) }
                                    }
                                    Text(hook.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Обновить") { config.reloadExtras() }
                Spacer()
                Text("Выключенный skill переносится в папку рядом (skills.disabled) и возвращается как был. Hooks здесь только для просмотра. Изменения подхватит следующая сессия.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }
}

private struct ExtraRow: View {
    let title: String
    let detail: String
    let note: String?
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(isOn ? String(localized: "Выключить «\(title)»") : String(localized: "Включить «\(title)»"))
        }
        .padding(.vertical, 2)
    }
}
