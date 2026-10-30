import AppKit
import SwiftUI

/// Settings window, one tab per area: general, modes, appearance, menu bar, Claude Code (path, sessions, limits,
/// background runs), AI services.
struct SettingsView: View {
    enum Tab: String, CaseIterable {
        case general, modes, modules, appearance, menuBar, claude, services
    }

    @Environment(AppSettings.self) private var settings
    @AppStorage("settingsTab") private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Основные", systemImage: "gearshape") }
                .tag(Tab.general)
            ModesSettings()
                .tabItem { Label("Профили", systemImage: "square.stack.3d.up") }
                .tag(Tab.modes)
            ModulesSettings()
                .tabItem { Label("Модули", systemImage: "puzzlepiece.extension") }
                .tag(Tab.modules)
            AppearanceSettings()
                .tabItem { Label("Внешний вид", systemImage: "paintbrush") }
                .tag(Tab.appearance)
            MenuBarSettings()
                .tabItem { Label("Строка меню", systemImage: "menubar.rectangle") }
                .tag(Tab.menuBar)
            ClaudeSettings()
                .tabItem { Label { Text(verbatim: "Claude Code") } icon: { Image(systemName: "sparkle") } }
                .tag(Tab.claude)
            ServicesSettings()
                .tabItem { Label("Сервисы AI", systemImage: "cpu") }
                .tag(Tab.services)
        }
        .frame(width: 560)
        .preferredColorScheme(settings.panelTheme.colorScheme)
        .debugSnapshot("settings")
    }
}

/// A tab's form: grouped, fixed width, as tall as its content.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Footnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Основные

private struct GeneralSettings: View {
    @Environment(ModeStore.self) private var modes
    @Environment(NotificationPermission.self) private var notifications
    @Environment(LoginItemController.self) private var loginItem
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @Environment(HookController.self) private var hooks

    var body: some View {
        @Bindable var settings = settings
        SettingsPage {
            Section {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { loginItem.state.isOn },
                    set: { loginItem.setEnabled($0) }
                ))
                if let message = loginItem.state.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if loginItem.state == .requiresApproval {
                    Button("Открыть «Объекты входа»") { loginItem.openSystemSettings() }
                }
                if let error = loginItem.lastError {
                    Text("Ошибка: \(error)").font(.callout).foregroundStyle(.red)
                }
                LanguagePicker()
                Picker("Открывать поиск с клавиатуры", selection: $settings.panelHotKey) {
                    ForEach(PanelHotKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.panelHotKey) { GlobalHotKey.register(settings.panelHotKey) }
            }

            Section {
                LabeledContent("Уведомления") {
                    HStack(spacing: 8) {
                        Text(notificationsText)
                            .foregroundStyle(notifications.state == .allowed ? .green : .orange)
                        if notifications.state == .notAsked {
                            Button("Разрешить") { notifications.request() }
                        } else if notifications.state == .allowed {
                            Button("Проверить") { Notifier.postTest() }
                        } else {
                            Button("Открыть настройки") { NotificationPermission.openSystemSettings() }
                        }
                    }
                }
            } footer: {
                Footnote(text: String(localized: "Нужны для «Claude ждёт ответа», итогов фоновых задач, порогов лимитов и результатов команд. Клик по уведомлению ведёт к сессии, PR, журналу или отчёту."))
            }

            Section {
                ImportConfirmation()
                HStack {
                    Button("Экспорт настроек…") { SettingsFiles.save(modes.exportBundle(), suggestedName: "AI Hub Bar") }
                    Button("Импорт…") { SettingsFiles.chooseImport(into: modes) }
                }
            } header: {
                Text("Перенос и обмен")
            } footer: {
                Footnote(text: String(localized: "Один файл .claudepult: все профили, внешний вид, строка меню, пороги. Без ключей, токенов и журналов. Двойной клик по такому файлу открывает импорт. Папки проектов — на вкладке «Профили»."))
            }

            Section {
                LabeledContent("Версия", value: Self.version)
                UpdatesRow()
                LabeledContent("Журнал") {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                    }
                }
            }
        }
        .onAppear {
            loginItem.refresh()
            notifications.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            notifications.refresh()
        }
    }

    private var notificationsText: String {
        switch notifications.state {
        case .allowed: String(localized: "включены")
        case .denied: String(localized: "выключены в macOS")
        case .notAsked: String(localized: "ещё не разрешены")
        case .unknown: "—"
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Внешний вид

private struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsPage {
            Section("Панель") {
                Picker("Тема", selection: $settings.panelTheme) {
                    ForEach(PanelTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Размер текста", selection: $settings.panelTextSize) {
                    ForEach(PanelTextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Ширина", selection: $settings.panelWidth) {
                    ForEach(PanelWidth.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Плотность строк", selection: $settings.panelDensity) {
                    ForEach(PanelDensity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Анимации при открытии", isOn: $settings.panelAnimations)
                TextSizePreview(scale: settings.panelTextSize.scale)
            }

            Section {
            } footer: {
                Footnote(text: String(localized: "Какие блоки показывать в панели и в каком порядке — у каждого профиля: вкладка «Профили» → «Панель»."))
            }

            Section {
                Button("Сбросить внешний вид") { settings.resetAppearance() }
            }
        }
    }
}

/// A sample line at the chosen text size, so the effect is visible without opening the panel.
private struct TextSizePreview: View {
    let scale: CGFloat

    var body: some View {
        LabeledContent("Пример") {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Cantero · claude/feature")
                    .font(ScaledFont.font(.body, scale: scale, weight: .medium))
                Text("22 файла · 15 мин назад")
                    .font(ScaledFont.font(.caption, scale: scale))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Claude

/// Claude Code in one tab (it was three small ones): where it is, its sessions, the subscription limits, background runs.
private struct ClaudeSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsPage {
            Section {
                LabeledContent("Путь к claude") {
                    TextField("", text: $settings.claudePath,
                              prompt: Text(ClaudeLocator.detect().map { String(localized: "авто: \($0)") } ?? String(localized: "авто: не найден")))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            } footer: {
                Footnote(text: String(localized: "Путь пустой — искать в /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.claude/local. Где запускать команды (Терминал / Фон / спрашивать) — у каждого профиля на вкладке «Профили»."))
            }

            SessionSection()
            TelegramApprovalsSection()

            Section {
                Stepper(value: $settings.backgroundTimeLimitMinutes, in: 10...600, step: 10) {
                    LabeledContent("Лимит времени", value: String(localized: "\(settings.backgroundTimeLimitMinutes) мин"))
                }
                Toggle("Итог в Telegram", isOn: $settings.telegramForBackground)
                Picker("Ночные задачи начинаются в", selection: $settings.nightStartHour) {
                    ForEach(NightQueue.hours, id: \.self) { Text(verbatim: String(format: "%02d:00", $0)).tag($0) }
                }
                if settings.telegramForBackground,
                   Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) == nil {
                    Text("В _daily-report/config.json нет telegram.bot_token / chat_id — будет только уведомление macOS.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Фоновые задачи")
            } footer: {
                Footnote(text: String(localized: "«Фон» запускает claude -p без окна: разрешены чтение и правка файлов проекта, проверки и сборки, git без push в main и без force, gh pr create/view/list; остальное отклоняется. Итог — уведомлением и в Telegram."))
            }
        }
    }
}

// MARK: - Модули

/// Settings → «Модули» (SPEC-profiles §6): the catalog — what each module does, which profiles show it, and its
/// settings that don't depend on a profile. The five modules ClaudePult has today are built in; installing and
/// removing arrive with the first optional module (Ресурсы Mac, SPEC-profiles §9.4).
private struct ModulesSettings: View {
    @Environment(ModeStore.self) private var modes

    var body: some View {
        Form {
            ForEach(ModuleKind.allCases, id: \.self) { kind in
                Section {
                    Text(kind.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent("В профилях", value: profiles(showing: kind))
                } header: {
                    HStack {
                        Label(kind.title, systemImage: kind.symbol)
                        Spacer()
                        if kind.isBuiltIn {
                            Text(modes.installedModules.contains(kind) ? String(localized: "встроенный") : String(localized: "не используется"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if modes.installedModules.contains(kind) {
                            Button("Снять") { modes.uninstall(kind) }
                                .controlSize(.small)
                                .help("Убрать из всех профилей и остановить; настройки сохранятся")
                        } else {
                            Button("Установить") { modes.install(kind) }
                                .controlSize(.small)
                                .help("Установить и добавить в текущий профиль")
                        }
                    }
                }
                switch kind {
                case .limits:
                    LimitSection()
                    HubSection()
                case .upcoming: ReminderSection()
                case .projects: PullRequestAlertSection()
                case .resources where modes.installedModules.contains(.resources): ResourceSection()
                case .keepAwake where modes.installedModules.contains(.keepAwake): KeepAwakeSection()
                case .quickCommands where modes.installedModules.contains(.quickCommands): QuickCommandsSection()
                case .toggles where modes.installedModules.contains(.toggles): QuickTogglesSection()
                case .clipboard where modes.installedModules.contains(.clipboard): ClipboardSection()
                case .notes where modes.installedModules.contains(.notes): NotesSection()
                default: EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
    }

    private func profiles(showing kind: ModuleKind) -> String {
        let names = modes.modes.filter { $0.shows(kind) }.map(\.name)
        return names.isEmpty ? String(localized: "нет") : names.joined(separator: ", ")
    }
}

private struct ResourceSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Уведомлять о нагрузке, памяти, месте и заряде", isOn: $settings.resourceAlerts)
            Picker("Мало места — свободно меньше", selection: $settings.resourceDiskBelowGB) {
                ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) ГБ").tag($0) }
            }
            .disabled(!settings.resourceAlerts)
        } header: {
            Text("Уведомления о ресурсах")
        } footer: {
            Footnote(text: String(localized: "Процессор выше 90 % дольше 5 минут, критическая нехватка памяти, мало места, заряд ниже 15 % без зарядки — по одному уведомлению, пока не наладится. В строку меню процессор и память добавляются во вкладке «Строка меню»."))
        }
    }
}

private struct KeepAwakeSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(KeepAwakeController.self) private var keepAwake
    @State private var lidBusy = false
    @State private var lidError: String?
    @State private var sleepOffNow = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Пока работает Claude (сессия или фоновая задача)", isOn: $settings.keepAwakeRules.whileClaudeWorks)
            Toggle("Пока подключено питание", isOn: $settings.keepAwakeRules.whileOnPower)
            Toggle("Пока подключён внешний монитор", isOn: $settings.keepAwakeRules.whileExternalDisplay)
            LabeledContent("Пока открыты приложения") {
                HStack {
                    Text(settings.keepAwakeRules.whileApps.isEmpty ? String(localized: "нет") : settings.keepAwakeRules.whileApps.map(\.name).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Выбрать…", action: chooseApps)
                    if !settings.keepAwakeRules.whileApps.isEmpty {
                        Button("Очистить") { settings.keepAwakeRules.whileApps = [] }
                    }
                }
            }
            Toggle("Не гасить и экран", isOn: $settings.keepAwakeRules.keepDisplayOn)
        } header: {
            Text("Правила «Не спать»")
        } footer: {
            Footnote(text: String(localized: "Любое сработавшее правило не даёт Mac уснуть; вручную — переключателем и таймерами в панели. Системные настройки не меняются: как только правил нет, Mac засыпает как обычно. На Маке без своего экрана любой монитор считается внешним."))
        }
        Section {
            if !LidSleep.hasLid {
                Text("У этого Mac нет крышки: правило нужно только ноутбукам.")
                    .foregroundStyle(.secondary)
            }
            Toggle("И с закрытой крышкой", isOn: $settings.keepAwakeRules.lidClosed)
                .disabled(!keepAwake.lidInstalled || !LidSleep.hasLid)
            LabeledContent("Разрешение администратора") {
                HStack {
                    Text(keepAwake.lidInstalled ? String(localized: "есть") : String(localized: "нет"))
                        .foregroundStyle(.secondary)
                    if keepAwake.lidInstalled {
                        Button("Убрать…") { change { await keepAwake.removeLidPermission() } }
                    } else {
                        Button("Разрешить…") { change { await keepAwake.installLidPermission() } }
                            .disabled(!LidSleep.hasLid)
                    }
                }
                .disabled(lidBusy)
            }
            if let lidError {
                Text(lidError).foregroundStyle(.red).scaledFont(.caption)
            }
            if sleepOffNow && !keepAwake.lidHeld {
                Text("Сейчас сон уже отключён другим приложением или командой pmset — AI Hub Bar его не трогает.")
                    .foregroundStyle(.secondary)
                    .scaledFont(.caption)
            }
        } header: {
            Text("С закрытой крышкой")
        } footer: {
            Footnote(text: String(localized: "Без монитора и питания закрытый Mac засыпает всегда, это может отменить только pmset от имени администратора. «Разрешить…» один раз спрашивает пароль и добавляет правило /etc/sudoers.d/claudepult: только команды pmset -a disablesleep 0 и 1. Пока держит правило «Не спать», сон выключен; потом и при выходе из AI Hub Bar — включается обратно. На батарее ниже 20 % — тоже включается. Закрытый Mac греется: не кладите его в сумку."))
        }
        .task { sleepOffNow = await LidSleep.systemSleepDisabled() }
    }

    private func change(_ action: @escaping () async -> LidSleep.AdminResult) {
        lidBusy = true
        lidError = nil
        Task {
            switch await action() {
            case .done, .cancelled: break
            case let .failed(message): lidError = message.isEmpty ? String(localized: "Не получилось") : message
            }
            if !keepAwake.lidInstalled { settings.keepAwakeRules.lidClosed = false }
            sleepOffNow = await LidSleep.systemSleepDisabled()
            lidBusy = false
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.compactMap { url -> KeepAwakeRules.App? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            return KeepAwakeRules.App(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        settings.keepAwakeRules.whileApps = Array(Set(settings.keepAwakeRules.whileApps + picked)).sorted { $0.name < $1.name }
    }
}

/// The «Быстрые команды» library: what each button runs (SPEC-profiles §4.3).
private struct QuickCommandsSection: View {
    @Environment(AppSettings.self) private var settings

    private static let symbols = ["bolt", "terminal", "folder", "link", "doc", "arrow.down.circle", "network", "hammer", "play", "wand.and.stars", "camera", "music.note"]

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach($settings.quickCommands) { $command in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: $command.symbol) {
                            ForEach(Self.symbols, id: \.self) { Image(systemName: $0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 60)
                        .help("Значок кнопки")
                        TextField("Название", text: $command.title)
                        Button { move(command.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(settings.quickCommands.first?.id == command.id)
                            .help("Выше")
                        Button { move(command.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(settings.quickCommands.last?.id == command.id)
                            .help("Ниже")
                        Button(role: .destructive) { settings.quickCommands.removeAll { $0.id == command.id } } label: { Image(systemName: "trash") }
                            .help("Удалить команду")
                    }
                    .buttonStyle(.borderless)
                    Picker("Что делает", selection: $command.kind) {
                        ForEach(QuickCommand.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField(placeholder(command.kind), text: $command.value)
                        .font(.callout.monospaced())
                    Toggle("Спрашивать перед запуском", isOn: $command.confirm)
                }
                .padding(.vertical, 4)
            }
            Button("Добавить команду") {
                settings.quickCommands.append(QuickCommand(title: String(localized: "Новая команда"), kind: .script, value: ""))
            }
        } header: {
            Text("Команды")
        } footer: {
            Footnote(text: String(localized: "Скрипт в фоне запускается через zsh в домашней папке, итог приходит уведомлением; «в Терминале» — открывает новое окно. Ярлык — имя из приложения «Команды». Открыть — ссылка (https://…) или путь (~/…)."))
        }
    }

    private func placeholder(_ kind: QuickCommand.Kind) -> String {
        switch kind {
        case .script, .terminal: String(localized: "команда, например: brew upgrade")
        case .shortcut: String(localized: "имя ярлыка")
        case .open: String(localized: "https://… или ~/папка")
        }
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = settings.quickCommands.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), settings.quickCommands.count - 1)
        settings.quickCommands.swapAt(index, target)
    }
}

private struct QuickTogglesSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            ForEach(QuickToggle.allCases, id: \.self) { toggle in
                Toggle(isOn: Binding(
                    get: { settings.quickToggles.contains(toggle) },
                    set: { on in settings.quickToggles = QuickToggle.allCases.filter { $0 == toggle ? on : settings.quickToggles.contains($0) } }
                )) {
                    Label(toggle.title, systemImage: toggle.symbol)
                }
            }
        } header: {
            Text("Какие переключатели показывать")
        } footer: {
            Footnote(text: String(localized: "Тёмная тема и корзина в первый раз попросят разрешение «Автоматизация» (System Events, Finder). Корзина очищается только после подтверждения."))
        }
    }
}

private struct ClipboardSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClipboardHistory.self) private var history

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Хранить последних", selection: $settings.clipboardLimit) {
                ForEach([20, 50, 100, 200], id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            Toggle("Помнить после перезапуска", isOn: $settings.clipboardRemember)
                .onChange(of: settings.clipboardRemember) { history.rememberChanged() }
            LabeledContent("Не запоминать из приложений") {
                HStack {
                    Text(verbatim: "\(settings.clipboardExcludedApps.count)").foregroundStyle(.secondary)
                    Button("Добавить…", action: addApps)
                    Button("По умолчанию") { settings.clipboardExcludedApps = ClipboardPolicy.defaultExcludedApps }
                }
            }
            Button("Очистить историю") { history.clear() }
        } header: {
            Text("История буфера")
        } footer: {
            Footnote(text: String(localized: "Не запоминается то, что менеджеры паролей помечают как скрытое, и всё, что скопировано, пока впереди менеджер паролей или «Связка ключей». Без «Помнить после перезапуска» история живёт только в памяти; с ним — в файле, доступном только вам."))
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        settings.clipboardExcludedApps = Array(Set(settings.clipboardExcludedApps + ids)).sorted()
    }
}

private struct NotesSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NotesStore.self) private var notes

    var body: some View {
        Section {
            LabeledContent("Папка") {
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

private struct ReminderSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Напоминать", selection: Binding(
                get: { settings.calendarReminderHours },
                set: { settings.calendarReminderHours = $0 }
            )) {
                Text("не напоминать").tag([Int]())
                Text("за 2 часа").tag([2])
                Text("за сутки").tag([24])
                Text("за сутки и за 2 часа").tag([24, 2])
                Text("за 3 дня и за сутки").tag([72, 24])
            }
            Toggle("Дублировать напоминания в Telegram", isOn: $settings.calendarRemindersToTelegram)
        } header: {
            Text("Напоминания")
        } footer: {
            Footnote(text: String(localized: "Даты — из проект.md (дедлайн, публикация) и контент-план.md у профилей с календарём (вкладка «Профили»)."))
        }
    }
}

// MARK: - Claude Code: sessions

/// Notifications about open pull requests of the projects.
private struct PullRequestAlertSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Уведомлять, когда CI упал или починился и когда PR закрыт", isOn: $settings.pullRequestAlerts)
            Toggle("Дублировать в Telegram", isOn: $settings.pullRequestAlertsToTelegram)
                .disabled(!settings.pullRequestAlerts)
        } header: {
            Text("Pull requests")
        } footer: {
            Footnote(text: String(localized: "По данным списка проектов (gh): обновляется раз в 5 минут и при открытии панели. Клик по уведомлению открывает PR."))
        }
    }
}

/// Permission requests answered from the phone, through a bot of ClaudePult's own.
private struct TelegramApprovalsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TelegramApprovals.self) private var telegram
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Присылать запросы разрешений в Telegram", isOn: $settings.telegramApprovals)
            LabeledContent("Токен бота") {
                HStack {
                    if telegram.hasToken {
                        Text(telegram.botName ?? String(localized: "сохранён в Связке ключей")).foregroundStyle(.secondary)
                        Button("Удалить") { Task { await telegram.removeToken() } }
                    } else {
                        SecureField("", text: $token, prompt: Text(verbatim: "123456:ABC…"))
                            .frame(width: 200)
                        Button("Сохранить") {
                            busy = true
                            Task {
                                await telegram.saveToken(token)
                                token = ""
                                busy = false
                            }
                        }
                        .disabled(token.isEmpty || busy)
                    }
                }
            }
            TextField("ID чата", text: $settings.telegramApprovalsChatID, prompt: Text("как у _daily-report"))
            HStack {
                Button("Проверить") {
                    busy = true
                    Task { await telegram.check(); busy = false }
                }
                .disabled(!telegram.hasToken || busy)
                if let status = telegram.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Ответы из Telegram")
        } footer: {
            Footnote(text: String(localized: "Нужен отдельный бот: бот _daily-report уже читает свои обновления, и второй читатель забирал бы у него сообщения. Создайте бота в @BotFather (/newbot), вставьте его токен, откройте бота в Telegram и нажмите «Start», затем «Проверить». Кнопки принимаются только из указанного чата."))
        }
    }
}

private struct SessionSection: View {
    @Environment(HookController.self) private var hooks
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("Hooks") {
                Text(hooks.status.title)
                    .foregroundStyle(hooks.status == .installed ? .green : hooks.status == .outdated ? .orange : .secondary)
            }
            HStack {
                // «Обновить» only when something is out of date: installed hooks need nothing.
                if hooks.status != .installed {
                    Button(hooks.status == .notInstalled ? String(localized: "Установить hooks") : String(localized: "Обновить hooks")) { hooks.install() }
                }
                if hooks.status != .notInstalled {
                    Button("Снять hooks") { hooks.uninstall() }
                }
            }
            if let message = hooks.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(hooks.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Отвечать на запросы разрешений из уведомлений и панели", isOn: $settings.approvalsFromClaudePult)
            Text("Когда Claude просит разрешение (команда, правка файла), в уведомлении и в строке сессии появляются «Разрешить» и «Отклонить». Диалог Claude при этом тоже на месте — работает тот ответ, что пришёл первым. В режиме auto Claude спрашивает редко. Если у hooks написано «нужно обновить», нажмите «Обновить hooks».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Сессии Claude Code")
        } footer: {
            Footnote(text: String(localized: "Hooks добавляются в ~/.claude/settings.json (остальные настройки не трогаются, перед изменением рядом сохраняется копия). Они записывают состояние каждой сессии Claude Code на этом Маке — в Терминале, в приложении Claude, фоновых — чтобы AI Hub Bar показывал их в панели."))
        }
        .onAppear { hooks.refresh() }
    }
}

// MARK: - Claude Code: limits

private struct LimitSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var usage
    @State private var thresholdsText = ""

    var body: some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("Уведомлять на, %") {
                // No title: in a Form a titled field also shows its title as a label next to it.
                TextField("", text: $thresholdsText, prompt: Text(verbatim: "50, 80, 95"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit(applyThresholds)
            }
            Toggle("Уведомления о лимитах ещё и в Telegram", isOn: $settings.limitAlertsToTelegram)
            VStack(alignment: .leading, spacing: 2) {
                Picker("Ставить фоновые задачи на паузу", selection: $settings.runGuardPercent) {
                    ForEach(RunGuard.thresholds, id: \.self) { value in
                        Text(value == 0 ? String(localized: "никогда") : String(localized: "с \(value) %")).tag(value)
                    }
                }
                Text("Когда сессия или неделя дошла до порога, фоновые задачи замирают там, где были, а запланированные ждут. После сброса лимита работа продолжается сама. Так задача не обрывается на полпути из-за лимита.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Продлевать вход Claude Code сам", isOn: $settings.renewClaudeLogin)
                Text("Когда вход истёк (claude давно не запускался, а работа идёт в приложении Claude), AI Hub Bar отправляет через claude запрос из одного слова — самая маленькая модель, без инструментов, не чаще раза в час. Вход продлевается примерно на 8 часов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = usage.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text("Лимиты подписки")
        } footer: {
            Footnote(text: String(localized: "Данные — с того же адреса, что использует Claude Code (токен читается из связки ключей «Claude Code-credentials» и нигде не сохраняется). Уведомление — один раз на окно сессии/недели при пересечении порога и когда лимит восстановился. Значения пишутся в ~/Library/Application Support/ClaudePult/usage.json. Что показывать в строке меню — во вкладке «Строка меню»."))
        }
        .onAppear { thresholdsText = settings.limitThresholds.map(String.init).joined(separator: ", ") }
        .onDisappear(perform: applyThresholds)
    }

    /// «50, 80, 95» → [50, 80, 95]; invalid input keeps the previous thresholds.
    private func applyThresholds() {
        let values = SettingsParsing.thresholds(thresholdsText)
        if !values.isEmpty { settings.limitThresholds = values }
        thresholdsText = settings.limitThresholds.map(String.init).joined(separator: ", ")
    }
}

// MARK: - Helpers

enum SettingsParsing {
    /// Percentages between 1 and 100 from free text, sorted and de-duplicated.
    static func thresholds(_ text: String) -> [Int] {
        Array(Set(text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...100).contains($0) })).sorted()
    }
}

/// The interface language (SPEC-modes §13): the system's, or one of ClaudePult's translations. macOS reads the
/// per-app `AppleLanguages` at launch, so a change needs a relaunch.
private struct LanguagePicker: View {
    @State private var choice = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first.flatMap { language in
        (Bundle.main.localizations + ["ru"]).first { language.hasPrefix($0) }
    } ?? ""
    @State private var changed = false

    /// Translations plus the development language (Russian), which has no `.lproj` of its own.
    private var languages: [String] {
        Set(Bundle.main.localizations + [Bundle.main.developmentLocalization ?? "ru"]).filter { $0 != "Base" }.sorted()
    }

    var body: some View {
        Picker("Язык интерфейса", selection: $choice) {
            Text("Как в системе").tag("")
            ForEach(languages, id: \.self) { code in
                Text(Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized ?? code).tag(code)
            }
        }
        .onChange(of: choice) {
            if choice.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([choice], forKey: "AppleLanguages")
            }
            changed = true
        }
        if changed {
            HStack {
                Text("Язык сменится после перезапуска.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Перезапустить") { Relaunch.now() }
            }
        }
    }
}

@MainActor
enum Relaunch {
    static func now() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// «Проверить обновления» and the daily check (Sparkle, scripts/release.sh).
private struct UpdatesRow: View {
    @State private var automatic = Updates.checksAutomatically

    var body: some View {
        LabeledContent("Обновления") {
            HStack {
                Toggle("Проверять раз в день", isOn: $automatic)
                    .onChange(of: automatic) { Updates.checksAutomatically = automatic }
                Button("Проверить сейчас") { Updates.checkNow() }
            }
        }
    }
}
