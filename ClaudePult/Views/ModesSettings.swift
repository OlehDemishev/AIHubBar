import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → «Режимы»: list of modes on the left, the selected mode's blocks on the right (SPEC-modes §2).
struct ModesSettings: View {
    @Environment(ModeStore.self) private var modes
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ImportConfirmation()
            HStack(alignment: .top, spacing: 0) {
                list
                    .frame(width: 210)
                Divider()
                if let mode = modes.modes.first(where: { $0.id == (selection ?? modes.currentID) }) {
                    ModeEditor(mode: mode)
                        .id(mode.id)
                } else {
                    Text("Выберите режим").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: 520)
        .onAppear { selection = selection ?? modes.currentID }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(modes.modes) { mode in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { modes.enabledIDs.contains(mode.id) },
                            set: { modes.setEnabled(mode.id, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help("Показывать в переключателе панели")
                        Image(systemName: mode.icon).frame(width: 16)
                        Text(mode.name).lineLimit(1)
                        Spacer()
                        if mode.id == modes.currentID {
                            Image(systemName: "checkmark").foregroundStyle(.secondary).help("Текущий режим")
                        }
                    }
                    .tag(mode.id)
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 4) {
                Button { selection.map { _ = modes.duplicate($0) } } label: { Image(systemName: "plus.square.on.square") }
                    .help("Дублировать")
                Button { selection.map { modes.move($0, by: -1) } } label: { Image(systemName: "arrow.up") }
                    .help("Выше")
                Button { selection.map { modes.move($0, by: 1) } } label: { Image(systemName: "arrow.down") }
                    .help("Ниже")
                Spacer()
                Menu {
                    Button("Экспорт режима…") { selection.map(exportMode) }
                    Button("Импорт…") { SettingsFiles.chooseImport(into: modes) }
                } label: { Image(systemName: "square.and.arrow.up.on.square") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Экспорт и импорт")
                Button(role: .destructive) {
                    if let id = selection { modes.delete(id); selection = modes.currentID }
                } label: { Image(systemName: "trash") }
                .disabled(modes.modes.count < 2)
                .help("Удалить режим")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func exportMode(_ id: String) {
        guard let bundle = modes.exportMode(id), let mode = bundle.modes.first else { return }
        SettingsFiles.save(bundle, suggestedName: mode.name)
    }
}

/// The right side of «Режимы»: blocks of one mode. Blocks of later stages are listed as coming.
private struct ModeEditor: View {
    @Environment(ModeStore.self) private var modes
    @Environment(AIServiceStore.self) private var services
    @State var mode: Mode

    private static let icons = [
        "chevron.left.forwardslash.chevron.right", "video", "doc.text", "books.vertical", "megaphone", "sparkle",
        "pencil.and.outline", "graduationcap", "briefcase", "paintbrush",
    ]

    var body: some View {
        Form {
            Section {
                TextField("Название", text: $mode.name)
                Picker("Значок", selection: $mode.icon) {
                    ForEach(Self.icons, id: \.self) { Image(systemName: $0).tag($0) }
                }
                if mode.id != modes.currentID {
                    Button("Сделать текущим") { modes.select(mode.id) }
                }
            }

            Section("Проекты") {
                LabeledContent("Источник", value: mode.source.title)
                switch mode.source {
                case let .gitReport(projects, dailyReport):
                    TildeFolderField(title: "Папка проектов", path: projects) { mode.source = .gitReport(projects: $0, dailyReport: dailyReport) }
                    TildeFolderField(title: "Папка _daily-report", path: dailyReport) { mode.source = .gitReport(projects: projects, dailyReport: $0) }
                case let .gitBuiltin(path):
                    TildeFolderField(title: "Папка проектов", path: path) { mode.source = .gitBuiltin(projects: $0) }
                case let .folders(path):
                    TildeFolderField(title: "Папка проектов", path: path) { mode.source = .folders($0) }
                case let .inbox(path):
                    TildeFolderField(title: "Папка", path: path) { mode.source = .inbox($0) }
                case .none:
                    EmptyView()
                }
                Toggle("Показывать проекты в панели", isOn: $mode.showProjects)
                if !mode.source.isReport, mode.source != .none {
                    Text("Проекты из этого источника появятся в следующих этапах.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Сервис по умолчанию", selection: $mode.service) {
                    Text(AIService.claudeCode.title).tag(String?.none)
                    ForEach(services.available.filter { $0 != .claudeCode }, id: \.id) { Text($0.title).tag(String?.some($0.id)) }
                    if let id = mode.service, !services.available.contains(where: { $0.id == id }) {
                        Text((AIService(id: id)?.title ?? id) + " — не найден на этом Маке").tag(String?.some(id))
                    }
                }
                Picker("Где запускать Claude", selection: $mode.launchMode) {
                    Text("Спрашивать").tag(LaunchMode?.none)
                    ForEach(LaunchMode.allCases, id: \.self) { Text($0.title).tag(LaunchMode?.some($0)) }
                }
            } header: {
                Text("Сервис AI")
            } footer: {
                Text("Сервис команд-шаблонов режима (этап 4). Агенты и ключи — Настройки → «Сервисы AI».").font(.caption).foregroundStyle(.secondary)
            }

            Section("Общие команды") {
                Picker("Команды", selection: $mode.commonCommands) {
                    Text("_daily-report: отчёт, сводка, очистка").tag(CommonCommandsKind.dailyReport)
                    Text("Нет").tag(CommonCommandsKind.none)
                }
                Toggle("Показывать в панели", isOn: $mode.showCommonCommands)
                    .disabled(mode.commonCommands == .none)
            }

            Section {
                ForEach(["Карточка и этапы проекта", "Метрики в строке проекта", "Команды-шаблоны",
                         "Права в фоне", "Календарь", "Добавки к строке меню"], id: \.self) { title in
                    LabeledContent(title) { Text("скоро").foregroundStyle(.tertiary) }
                }
            } header: {
                Text("Ещё кубики")
            } footer: {
                Text("Появятся в следующих этапах (docs/SPEC-modes.md §9).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: mode) { modes.update(mode) }
    }
}

/// A `~`-path with «Выбрать…»; red when the folder does not exist on this Mac (e.g. after an import).
private struct TildeFolderField: View {
    let title: String
    let path: String
    let onChange: (String) -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(FileManager.default.fileExists(atPath: PathText.expand(path)) ? .primary : Color.red)
                    .help(FileManager.default.fileExists(atPath: PathText.expand(path)) ? PathText.expand(path) : "Папки нет на этом Маке — выберите свою")
                Button("Выбрать…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: PathText.expand(path))
                    NSApp.activate()
                    if panel.runModal() == .OK, let url = panel.url { onChange(PathText.tilde(url.path)) }
                }
            }
        }
    }
}

/// «Заменить всё / Добавить режимы / Отмена» for a file waiting to be imported.
struct ImportConfirmation: View {
    @Environment(ModeStore.self) private var modes

    var body: some View {
        if let pending = modes.pendingImport {
            VStack(alignment: .leading, spacing: 6) {
                Text("Импорт «\(pending.url.lastPathComponent)»").font(.headline)
                Text(summary(pending.bundle)).font(.callout).foregroundStyle(.secondary)
                HStack {
                    if pending.bundle.format == SettingsBundle.settingsFormat {
                        Button("Заменить все настройки") { modes.importBundle(pending.bundle, style: .replace) }
                    }
                    Button("Добавить режимы") { modes.importBundle(pending.bundle, style: .add) }
                        .buttonStyle(.borderedProminent)
                    Button("Отмена") { modes.cancelImport() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1))
        } else if let message = modes.lastMessage {
            Text(message).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private func summary(_ bundle: SettingsBundle) -> String {
        let names = bundle.modes.map(\.name).joined(separator: ", ")
        let what = bundle.format == SettingsBundle.settingsFormat ? "Все настройки и режимы" : "Режим"
        let missing = bundle.modes.flatMap(ModeStore.missingFolders)
        return "\(what): \(names)." + (missing.isEmpty ? "" : " Нет на этом Маке: \(missing.joined(separator: ", ")) — после импорта выберите свои папки.")
    }
}

/// Save / open panels for `*.claudepult` files.
@MainActor
enum SettingsFiles {
    static let type = UTType(exportedAs: "com.demishev.claudepult.settings", conformingTo: .json)

    static func save(_ bundle: SettingsBundle, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName + ".claudepult"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ModeStore.encode(bundle).write(to: url, options: .atomic)
            AppLog.info("Exported \(bundle.format) to \(url.lastPathComponent)")
        } catch {
            AppLog.error("Export failed: \(error.localizedDescription)")
        }
    }

    static func chooseImport(into modes: ModeStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type, .json]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modes.prepareImport(from: url)
    }
}
