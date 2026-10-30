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
                    Button("Экспорт настроек…") { SettingsFiles.save(modes.exportBundle(), suggestedName: "ClaudePult") }
                    Button("Импорт…") { SettingsFiles.chooseImport(into: modes) }
                }
            } header: {
                Text("Перенос и обмен")
            } footer: {
                Footnote(text: String(localized: "Один файл .claudepult: все профили, внешний вид, строка меню, пороги. Без ключей, токенов и журналов. Двойной клик по такому файлу открывает импорт. Папки проектов — на вкладке «Профили»."))
            }

            Section {
                LabeledContent("Версия", value: Self.version)
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

            Section {
                Stepper(value: $settings.backgroundTimeLimitMinutes, in: 10...600, step: 10) {
                    LabeledContent("Лимит времени", value: String(localized: "\(settings.backgroundTimeLimitMinutes) мин"))
                }
                Toggle("Итог в Telegram", isOn: $settings.telegramForBackground)
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
                case .limits: LimitSection()
                case .upcoming: ReminderSection()
                case .resources where modes.installedModules.contains(.resources): ResourceSection()
                case .keepAwake where modes.installedModules.contains(.keepAwake): KeepAwakeSection()
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

private struct SessionSection: View {
    @Environment(HookController.self) private var hooks

    var body: some View {
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
        } header: {
            Text("Сессии Claude Code")
        } footer: {
            Footnote(text: String(localized: "Hooks добавляются в ~/.claude/settings.json (остальные настройки не трогаются, перед изменением рядом сохраняется копия). Они записывают состояние каждой сессии Claude Code на этом Маке — в Терминале, в приложении Claude, фоновых — чтобы ClaudePult показывал их в панели."))
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
                Toggle("Продлевать вход Claude Code сам", isOn: $settings.renewClaudeLogin)
                Text("Когда вход истёк (claude давно не запускался, а работа идёт в приложении Claude), ClaudePult отправляет через claude запрос из одного слова — самая маленькая модель, без инструментов, не чаще раза в час. Вход продлевается примерно на 8 часов.")
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
