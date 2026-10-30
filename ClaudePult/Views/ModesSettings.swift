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
                Picker("Источник", selection: Binding(
                    get: { SourceKind(mode.source) },
                    set: { mode.source = $0.source(keeping: mode.source) }
                )) {
                    ForEach(SourceKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
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
                if case .gitBuiltin = mode.source {
                    Text("Встроенный сканер git появится вместе с шаблонами (этап 6).").font(.caption).foregroundStyle(.secondary)
                }
            }

            if mode.source.isFolders {
                Section {
                    TextField("Этапы", text: Binding(
                        get: { mode.stages.joined(separator: ", ") },
                        // Empty items stay while typing («идея, »); `Mode.stageList` drops them.
                        set: { mode.stages = $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
                    ), prompt: Text("идея, черновик, готово"))
                    ForEach(FolderMetric.allCases, id: \.self) { metric in
                        Toggle(metric.title, isOn: Binding(
                            get: { mode.metrics.contains(metric.rawValue) },
                            set: { on in
                                mode.metrics.removeAll { $0 == metric.rawValue }
                                if on {
                                    // Keep the order of FolderMetric.
                                    let order = FolderMetric.allCases.map(\.rawValue)
                                    mode.metrics.append(metric.rawValue)
                                    mode.metrics.sort { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
                                }
                            }
                        ))
                    }
                    if mode.metrics.contains(FolderMetric.duration.rawValue) {
                        Stepper("Темп речи: \(mode.wordsPerMinute) слов/мин", value: $mode.wordsPerMinute, in: 80...250, step: 10)
                    }
                } header: {
                    Text("Карточка, этапы и метрики")
                } footer: {
                    Text("Карточка проекта — файл проект.md в папке проекта (этап, дедлайн, публикация, формат, главный файл, площадка); этап меняется прямо из панели. Слова считаются по главному файлу.").font(.caption).foregroundStyle(.secondary)
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
                Picker("Права Claude в фоне", selection: $mode.permissions) {
                    ForEach(PermissionProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("«Только файлы»: читать и писать внутри папки проекта, без терминала и интернета")
                Picker("Где запускать Claude", selection: $mode.launchMode) {
                    Text("Спрашивать").tag(LaunchMode?.none)
                    ForEach(LaunchMode.allCases, id: \.self) { Text($0.title).tag(LaunchMode?.some($0)) }
                }
            } header: {
                Text("Сервис AI")
            } footer: {
                Text("Сервис команд-шаблонов режима (этап 4). Агенты и ключи — Настройки → «Сервисы AI».").font(.caption).foregroundStyle(.secondary)
            }

            if mode.source.isFolders {
                Section {
                    ForEach($mode.commands) { $command in
                        CommandEditor(command: $command) { mode.commands.removeAll { $0.id == command.id } }
                    }
                    Button("Добавить команду") {
                        mode.commands.append(CommandTemplate(title: "Новая команда", task: "", output: "результат-<время>.md"))
                    }
                } header: {
                    Text("Команды проектов")
                } footer: {
                    Text("Подстановки: {проект} {файл} {формат} {площадка} {хронометраж} {текст} {язык}; в имени файла ещё <время> и <файл>. Результат — всегда новый файл в папке проекта. «Своя задача» есть всегда.").font(.caption).foregroundStyle(.secondary)
                }
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

/// The project sources a mode can be switched between in Settings.
private enum SourceKind: CaseIterable, Hashable {
    case report, folders, inbox, none

    init(_ source: ProjectSource) {
        switch source {
        case .gitReport, .gitBuiltin: self = .report
        case .folders: self = .folders
        case .inbox: self = .inbox
        case .none: self = .none
        }
    }

    var title: String {
        switch self {
        case .report: "git-репозитории через report.py"
        case .folders: "папки (каждая подпапка — проект)"
        case .inbox: "одна папка"
        case .none: "без проектов"
        }
    }

    /// The new source, keeping the folder the mode already had.
    func source(keeping old: ProjectSource) -> ProjectSource {
        let folder = old.folder ?? "~/Documents"
        switch self {
        case .report:
            if case .gitReport = old { return old }
            return .gitReport(projects: folder, dailyReport: folder + "/_daily-report")
        case .folders: return .folders(folder)
        case .inbox: return .inbox(folder)
        case .none: return .none
        }
    }
}

/// One command of a folder mode, folded into a line until opened.
private struct CommandEditor: View {
    @Binding var command: CommandTemplate
    let onDelete: () -> Void
    @Environment(AIServiceStore.self) private var services

    var body: some View {
        DisclosureGroup(command.title) {
            TextField("Название", text: $command.title)
            TextField("Файл результата", text: $command.output, prompt: Text("хуки.md"))
            Picker("На чём", selection: $command.input) {
                ForEach(CommandTemplate.Input.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Спросить перед запуском", text: Binding(
                get: { command.asks ?? "" },
                set: { command.asks = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ), prompt: Text("пусто — запускать сразу; «Язык», «Тон»…"))
            Picker("Сервис", selection: $command.service) {
                Text("Сервис режима").tag(String?.none)
                ForEach(services.available, id: \.id) { Text($0.title).tag(String?.some($0.id)) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Задача").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $command.task)
                    .font(.body)
                    .frame(minHeight: 70)
            }
            Button("Удалить команду", role: .destructive, action: onDelete)
        }
    }
}
