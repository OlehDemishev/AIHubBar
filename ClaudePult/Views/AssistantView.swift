import AppKit
import SwiftUI

/// The setup assistant (SPEC-modes §5): one block per screen on the left, a live preview of the panel and the menu bar
/// on the right; «Назад», «Пропустить» (keep the template's choice), «Далее», «Готово».
struct AssistantView: View {
    @Environment(ModeStore.self) private var modes
    @Environment(AppSettings.self) private var settings
    @Environment(AIServiceStore.self) private var services
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var draft: AssistantDraft?

    private static let templates = ModeTemplate.loadAll()
    static let icons = [
        "sparkle", "video", "doc.text", "books.vertical", "megaphone", "chevron.left.forwardslash.chevron.right",
        "pencil.and.outline", "graduationcap", "briefcase", "paintbrush", "camera", "music.note", "globe", "heart",
    ]

    var body: some View {
        Group {
            if let binding = Binding($draft) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        header(binding.wrappedValue)
                        ScrollView {
                            step(binding)
                                .padding(20)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                        navigation(binding)
                    }
                    .frame(width: 470)
                    Divider()
                    AssistantPreview(draft: binding.wrappedValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.03))
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: 900, height: 620)
        .onAppear {
            if draft == nil {
                // A new profile starts with every block shown; the «Что будет в панели» step decides.
                draft = AssistantDraft(firstLaunch: modes.needsAssistant, menuBar: settings.menuBarConfig,
                                       hiddenBlocks: [], reminderHours: settings.calendarReminderHours)
            }
        }
    }

    private func header(_ draft: AssistantDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Шаг \(draft.index + 1) из \(draft.steps.count)").font(.caption).foregroundStyle(.secondary)
            Text(draft.step.title).font(.title2.weight(.semibold))
            ProgressView(value: Double(draft.index + 1), total: Double(draft.steps.count))
        }
        .padding(20)
    }

    private func navigation(_ draft: Binding<AssistantDraft>) -> some View {
        HStack {
            Button("Назад") { withAnimation(.snappy) { draft.wrappedValue.back() } }
                .disabled(draft.wrappedValue.isFirst)
            Spacer()
            if !draft.wrappedValue.isLast, ![.welcome, .importSettings, .template].contains(draft.wrappedValue.step) {
                Button("Пропустить") { withAnimation(.snappy) { draft.wrappedValue.next() } }
                    .help("Оставить как в шаблоне")
            }
            if draft.wrappedValue.isLast {
                Button("Готово") { finish(draft.wrappedValue) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Далее") { withAnimation(.snappy) { draft.wrappedValue.next() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func finish(_ draft: AssistantDraft) {
        // The panel blocks and the menu bar chosen here belong to the new profile (SPEC-profiles §6).
        var profile = draft.mode
        profile.modules = nil
        profile.modules = profile.normalizedModules(hiddenBlocks: draft.hiddenBlocks) + draft.extraModules.map { ProfileModule($0) }
        profile.menuBar = draft.menuBar
        settings.calendarReminderHours = draft.reminderHours
        if let folder = draft.mode.source.folder.map(PathText.expand), !FileManager.default.fileExists(atPath: folder) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        modes.addFromAssistant(profile)
        dismissWindow(id: "assistant")
    }

    // MARK: - Steps

    @ViewBuilder
    private func step(_ draft: Binding<AssistantDraft>) -> some View {
        switch draft.wrappedValue.step {
        case .welcome: welcomeStep
        case .importSettings: importStep(draft)
        case .template: templateStep(draft)
        case .modules: modulesStep(draft)
        case .folder: folderStep(draft)
        case .stages: stagesStep(draft)
        case .metrics: metricsStep(draft)
        case .calendar: calendarStep(draft)
        case .service: serviceStep(draft)
        case .commands: commandsStep(draft)
        case .launch: launchStep(draft)
        case .menuBar: menuBarStep(draft)
        case .name: nameStep(draft)
        }
    }

    /// The first screen on a new Mac: what ClaudePult is and what it still needs (SPEC-modes §9.8).
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Hub Bar живёт в строке меню (✦): проекты, лимиты подписки Claude, сессии и команды для AI — в одной панели. Сначала проверим, что всё готово, потом настроим первый профиль.")
                .fixedSize(horizontal: false, vertical: true)
            ReadinessSection()
            Text("Всё это можно сделать и позже: в Настройках и в окне «Помощь».")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func importStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Есть файл настроек AI Hub Bar (.claudepult) с другого Мака или от коллеги? Его можно перенести целиком — профили, строку меню, внешний вид. Ключи API в файл не попадают.")
                .fixedSize(horizontal: false, vertical: true)
            ImportConfirmation()
            HStack {
                Button("Импортировать файл…") { SettingsFiles.chooseImport(into: modes) }
                Button("Нет, настроить заново") { withAnimation(.snappy) { draft.wrappedValue.next() } }
                    .buttonStyle(.borderedProminent)
            }
            if modes.lastMessage != nil, modes.pendingImport == nil {
                Button("Закрыть помощника") { dismissWindow(id: "assistant") }
            }
        }
    }

    private func templateStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.templates) { template in
                choiceCard(title: template.title, detail: template.description, icon: template.mode.icon,
                           selected: draft.wrappedValue.templateID == template.id) {
                    draft.wrappedValue.choose(template)
                }
            }
            choiceCard(title: String(localized: "С нуля"), detail: String(localized: "Пустой профиль: всё выберете на следующих шагах."), icon: "square.dashed",
                       selected: draft.wrappedValue.templateID == nil) {
                draft.wrappedValue.choose(nil)
            }
        }
    }

    private func choiceCard(title: String, detail: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.title3).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func folderStep(_ draft: Binding<AssistantDraft>) -> some View {
        let folder = draft.wrappedValue.mode.source.folder ?? "~/Documents"
        return VStack(alignment: .leading, spacing: 12) {
            Text(Self.templates.first { $0.id == draft.wrappedValue.templateID }?.folderHint ?? String(localized: "Папка, где каждая подпапка — проект."))
                .foregroundStyle(.secondary)
            HStack {
                Text(folder).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Выбрать…") { chooseFolder(draft) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            if let analysis = draft.wrappedValue.analysis {
                Text(analysis.text).font(.callout)
            } else if !FileManager.default.fileExists(atPath: PathText.expand(folder)) {
                Text("Такой папки пока нет — она будет создана при «Готово».").font(.callout).foregroundStyle(.secondary)
            }
            Picker("Проекты — это", selection: Binding(
                get: { draft.wrappedValue.mode.source.isGit ? 0 : draft.wrappedValue.mode.source.isInbox ? 2 : 1 },
                set: { kind in
                    let path = PathText.tilde(PathText.expand(folder))
                    draft.wrappedValue.mode.source = kind == 0 ? .gitBuiltin(projects: path) : kind == 2 ? .inbox(path) : .folders(path)
                    if kind == 0 { draft.wrappedValue.mode.card = .statusMD; draft.wrappedValue.mode.permissions = .code }
                    else { draft.wrappedValue.mode.card = .projectMD; if draft.wrappedValue.mode.permissions == .code { draft.wrappedValue.mode.permissions = .filesOnly } }
                }
            )) {
                Text("git-репозитории").tag(0)
                Text("папки (каждая подпапка — проект)").tag(1)
                Text("одна папка").tag(2)
            }
            .pickerStyle(.radioGroup)
            if draft.wrappedValue.analysis?.suggestsGit == true {
                Text("Внутри git-репозитории — предлагаю источник «git-репозитории».").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if draft.wrappedValue.analysis == nil, FileManager.default.fileExists(atPath: PathText.expand(folder)) {
                draft.wrappedValue.analysis = .of(PathText.expand(folder))
            }
        }
    }

    private func chooseFolder(_ draft: Binding<AssistantDraft>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Выбрать")
        let current = PathText.expand(draft.wrappedValue.mode.source.folder ?? "~/Documents")
        panel.directoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: current) ? current : PathText.expand("~/Documents"))
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.wrappedValue.setFolder(url.path, analysis: .of(url.path))
    }

    private func stagesStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Этапы, через которые проходит каждый проект. Этап меняется прямо из панели и записывается в проект.md.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(draft.wrappedValue.mode.stages.enumerated()), id: \.offset) { index, _ in
                HStack {
                    TextField("Этап", text: Binding(
                        get: { draft.wrappedValue.mode.stages[index] },
                        set: { draft.wrappedValue.mode.stages[index] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button { draft.wrappedValue.mode.stages.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Убрать этап")
                }
            }
            Button("Добавить этап") { draft.wrappedValue.mode.stages.append("") }
        }
    }

    private func metricsStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(FolderMetric.allCases, id: \.self) { metric in
                Toggle(metric.title, isOn: Binding(
                    get: { draft.wrappedValue.mode.metrics.contains(metric.rawValue) },
                    set: { on in
                        let order = FolderMetric.allCases.map(\.rawValue)
                        draft.wrappedValue.mode.metrics.removeAll { $0 == metric.rawValue }
                        if on { draft.wrappedValue.mode.metrics.append(metric.rawValue) }
                        draft.wrappedValue.mode.metrics.sort { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
                    }
                ))
            }
            if draft.wrappedValue.mode.metrics.contains(FolderMetric.duration.rawValue) {
                Stepper("Темп речи: \(draft.wrappedValue.mode.wordsPerMinute) слов/мин", value: draft.mode.wordsPerMinute, in: 80...250, step: 10)
            }
            Text("Слова считаются по главному файлу проекта (.md, .txt, .rtf, .docx).").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func calendarStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Календарь", selection: draft.mode.calendar) {
                Text("Выключен").tag(CalendarMode.off)
                Text("Дедлайны и публикации из проект.md").tag(CalendarMode.dates)
                Text("+ контент-план (контент-план.md)").tag(CalendarMode.contentPlan)
            }
            .pickerStyle(.radioGroup)
            if draft.wrappedValue.mode.calendar != .off {
                Picker("Напоминать", selection: draft.reminderHours) {
                    Text("не напоминать").tag([Int]())
                    Text("за 2 часа").tag([2])
                    Text("за сутки").tag([24])
                    Text("за сутки и за 2 часа").tag([24, 2])
                    Text("за 3 дня и за сутки").tag([72, 24])
                }
            }
        }
    }

    private func serviceStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Кто выполняет команды профиля. Модель по API получает только текст файла; агент (Claude Code и др.) работает с файлами в папке проекта.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Сервис", selection: draft.mode.service) {
                Text(AIService.claudeCode.title).tag(String?.none)
                ForEach(services.available.filter { $0 != .claudeCode }, id: \.id) { Text($0.title).tag(String?.some($0.id)) }
            }
            .pickerStyle(.radioGroup)
            Button("Подключить другой сервис…") {
                UserDefaults.standard.set("services", forKey: "settingsTab")
                NSApp.activate()
                openSettings()
            }
            Text("Агенты ставятся отдельно; ключи API вставляются в Настройках → «Сервисы AI». Вернитесь сюда — список обновится.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func commandsStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Команды появятся у каждого проекта. «Своя задача» есть всегда. Тексты можно поправить сейчас или позже в Настройках.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach(draft.mode.commands) { $command in
                    CommandEditor(command: $command) { draft.wrappedValue.mode.commands.removeAll { $0.id == command.id } }
                }
                Button("Добавить команду") {
                    draft.wrappedValue.mode.commands.append(CommandTemplate(title: String(localized: "Новая команда"), task: "", output: String(localized: "результат-<время>.md")))
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 300)
        }
    }

    private func launchStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Где запускать Claude", selection: draft.mode.launchMode) {
                Text("Спрашивать каждый раз").tag(LaunchMode?.none)
                Text("В фоне — результат придёт уведомлением").tag(LaunchMode?.some(.background))
                Text("В Терминале — видно, что он делает").tag(LaunchMode?.some(.terminal))
            }
            .pickerStyle(.radioGroup)
            Picker("Что разрешить в фоне", selection: draft.mode.permissions) {
                ForEach(PermissionProfile.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(permissionsText(draft.wrappedValue.mode.permissions)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionsText(_ profile: PermissionProfile) -> String {
        switch profile {
        case .code: String(localized: "Чтение и правка файлов, git (без push в main и удаления истории), проверки и сборки, pull request.")
        case .filesOnly: String(localized: "Читать и писать только внутри папки проекта. Без терминала и интернета.")
        case .filesAndWeb: String(localized: "Файлы проекта плюс поиск и чтение страниц в интернете. Без терминала.")
        }
    }

    /// Which modules the new profile has (SPEC-profiles §5). «Проекты» brings the project steps that follow.
    private func modulesStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Что будет в панели этого профиля. Порядок и всё остальное можно поменять потом в Настройках → «Профили».")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AssistantDraft.offeredModules, id: \.self) { kind in
                Toggle(isOn: Binding(
                    get: { draft.wrappedValue.hasModule(kind) },
                    set: { on in withAnimation(.snappy) { draft.wrappedValue.setModule(kind, on) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(kind.title, systemImage: kind.symbol).fontWeight(.medium)
                        Text(kind.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!draft.wrappedValue.canChange(kind))
                .padding(.vertical, 2)
            }
            if !draft.wrappedValue.canChange(.upcoming) {
                Text("«Ближайшее» берёт даты из проектов-папок: включите «Проекты» с папками.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func menuBarStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Набор", selection: Binding(
                get: { draft.wrappedValue.menuBar.preset },
                set: { preset in
                    var config = draft.wrappedValue.menuBar
                    if preset != .custom { config.elements = MenuBarConfig.make(preset).elements }
                    config.preset = preset
                    draft.wrappedValue.menuBar = config
                }
            )) {
                ForEach(MenuBarConfig.Preset.allCases.filter { $0 != .custom }, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("«Минимум» — значок и события, «Лимиты» — ещё проценты сессии и недели, «Всё» — всё, что есть. Отдельные элементы — в Настройках → «Строка меню». Набор общий для всех профилей.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Значок профиля вместо ✦", isOn: Binding(
                get: { draft.wrappedValue.menuBar.element(.icon).symbol == "mode" },
                set: { on in draft.wrappedValue.menuBar.set(.icon) { $0.symbol = on ? "mode" : "sparkle" } }
            ))
        }
    }

    private func nameStep(_ draft: Binding<AssistantDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Название", text: draft.mode.name)
                .textFieldStyle(.roundedBorder)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 7), spacing: 8) {
                ForEach(Self.icons, id: \.self) { icon in
                    Button { draft.wrappedValue.mode.icon = icon } label: {
                        Image(systemName: icon)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 7).fill(
                                draft.wrappedValue.mode.icon == icon ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("«Готово» добавит профиль и сделает его текущим. Дальше всё правится в Настройках → «Профили».")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The right side: the menu bar item and the panel as they would look with this draft, on sample data.
struct AssistantPreview: View {
    let draft: AssistantDraft

    private var mode: Mode { draft.mode }

    private var sampleProjects: [FolderProject] {
        let names: [String] = switch draft.templateID {
        case "video": [String(localized: "Ролик про кофе"), String(localized: "Обзор чайников"), String(localized: "Shorts: лайфхак")]
        case "texts": [String(localized: "Статья о сне"), String(localized: "Рассылка №12"), String(localized: "Пост про отпуск")]
        case "research": [String(localized: "Курсовая: климат"), String(localized: "Нейросети в медицине")]
        case "social": [String(localized: "Запуск курса"), String(localized: "Instagram: ноябрь")]
        default: [String(localized: "Проект один"), String(localized: "Проект два")]
        }
        let stages = mode.stageList
        return names.enumerated().map { index, name in
            var card = ProjectCardFile()
            if !stages.isEmpty { card.values[.stage] = stages[min(index + 1, stages.count - 1)] }
            card.values[.deadline] = CalendarScanner.text(Date.now.addingTimeInterval(Double(index + 2) * 86_400), withTime: false)
            card.values[.publish] = CalendarScanner.text(Date.now.addingTimeInterval(Double(index + 5) * 86_400), withTime: false)
            return FolderProject(name: name, path: "/\(name)", card: card, hasCardFile: true, mainFile: String(localized: "текст.md"),
                                 words: [1340, 820, 150][index % 3], sources: [4, 0, 2][index % 3],
                                 lastActivity: Date.now.addingTimeInterval(-Double(index + 1) * 5400))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Предпросмотр").font(.headline).foregroundStyle(.secondary)
            menuBar
            panel
            Spacer()
        }
        .padding(20)
    }

    private var menuBar: some View {
        var data = MenuBarData.sample
        data.modeIcon = mode.icon
        data.modeName = mode.name
        let groups = MenuBarComposer.groups(draft.menuBar, data)
        return HStack {
            Spacer()
            Group {
                if let symbol = MenuBarComposer.plainSymbol(groups) {
                    Image(systemName: symbol)
                } else {
                    Image(nsImage: MenuBarRenderer.image(groups, config: draft.menuBar))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                Text(mode.name.isEmpty ? String(localized: "Новый профиль") : mode.name).fontWeight(.semibold)
            }
            .font(.callout)
            if !draft.hiddenBlocks.contains(.limits) {
                VStack(alignment: .leading, spacing: 4) {
                    sampleBar(String(localized: "Сессия"), 0.34, .green)
                    sampleBar(String(localized: "Неделя"), 0.58, .orange)
                }
            }
            if mode.calendar != .off, mode.source.isFolders, !draft.hiddenBlocks.contains(.calendar) {
                Divider()
                Text("Ближайшее").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(sampleProjects.prefix(2)) { project in
                    HStack {
                        Image(systemName: "flag").foregroundStyle(.secondary)
                        Text(project.name)
                        Spacer()
                        Text(project.card.deadline.map { CalendarText.relative($0, hasTime: false) } ?? "").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            if mode.showProjects {
                Divider()
                if mode.source.isGit {
                    gitRow("my-app", branch: "main", detail: String(localized: "2 файла · PR #12 ✓"), color: .yellow)
                    gitRow("website", branch: "feat/blog", detail: String(localized: "чисто · 3 ч назад"), color: .green)
                } else if mode.source.isFolders {
                    ForEach(sampleProjects) { project in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(project.name).fontWeight(.medium)
                                Spacer()
                                if let stage = project.card.stage {
                                    StageChip(stage: stage, index: mode.stageList.firstIndex(of: stage), count: mode.stageList.count)
                                }
                            }
                            let metrics = mode.metrics.compactMap(FolderMetric.init(rawValue:))
                                .compactMap { $0.text(for: project, wordsPerMinute: mode.wordsPerMinute) }
                            if !metrics.isEmpty {
                                Text(metrics.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    FlowRow(spacing: 4) {
                        ForEach(mode.commands.prefix(4) + [CommandTemplate.customTask]) { command in
                            Text(command.title).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background).shadow(color: .black.opacity(0.15), radius: 8, y: 3))
    }

    private func sampleBar(_ title: String, _ value: Double, _ color: Color) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color).frame(width: proxy.size.width * value)
                }
            }
            .frame(height: 6)
            Text("\(Int((value * 100).rounded()))%").font(.caption).monospacedDigit()
        }
    }

    private func gitRow(_ name: String, branch: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).fontWeight(.medium)
                Spacer()
            }
            Text("\(branch) · \(detail)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
