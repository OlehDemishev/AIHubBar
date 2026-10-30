import AppKit
import SwiftUI

/// Settings window, one tab per area: general, modes, appearance, menu bar, Claude, AI services, sessions, limits.
struct SettingsView: View {
    enum Tab: String, CaseIterable {
        case general, modes, appearance, menuBar, claude, services, sessions, limits
    }

    @Environment(AppSettings.self) private var settings
    @AppStorage("settingsTab") private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Основные", systemImage: "gearshape") }
                .tag(Tab.general)
            ModesSettings()
                .tabItem { Label("Режимы", systemImage: "square.stack.3d.up") }
                .tag(Tab.modes)
            AppearanceSettings()
                .tabItem { Label("Внешний вид", systemImage: "paintbrush") }
                .tag(Tab.appearance)
            MenuBarSettings()
                .tabItem { Label("Строка меню", systemImage: "menubar.rectangle") }
                .tag(Tab.menuBar)
            ClaudeSettings()
                .tabItem { Label("Claude", systemImage: "sparkle") }
                .tag(Tab.claude)
            ServicesSettings()
                .tabItem { Label("Сервисы AI", systemImage: "cpu") }
                .tag(Tab.services)
            SessionSettings()
                .tabItem { Label("Сессии", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(Tab.sessions)
            LimitSettings()
                .tabItem { Label("Лимиты", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(Tab.limits)
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
                Footnote(text: String(localized: "Один файл .claudepult: все режимы, внешний вид, строка меню, пороги. Без ключей, токенов и журналов. Двойной клик по такому файлу открывает импорт. Папки проектов — на вкладке «Режимы»."))
            }

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
                Text("Календарь")
            } footer: {
                Footnote(text: String(localized: "Даты — из проект.md (дедлайн, публикация) и контент-план.md у режимов с календарём (вкладка «Режимы»)."))
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
                ForEach([PanelBlock.limits, .sessions, .calendar]) { block in
                    Toggle(block.title, isOn: Binding(
                        get: { settings.shows(block) },
                        set: { settings.setShows(block, $0) }
                    ))
                }
            } header: {
                Text("Блоки панели")
            } footer: {
                Footnote(text: String(localized: "Скрытый блок не пропадает из работы: сессии и лимиты отслеживаются, уведомления приходят. Проекты и общие команды включаются у каждого режима на вкладке «Режимы»."))
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
                Footnote(text: String(localized: "Путь пустой — искать в /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.claude/local. Где запускать команды (Терминал / Фон / спрашивать) — у каждого режима на вкладке «Режимы»."))
            }

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

// MARK: - Сессии

private struct SessionSettings: View {
    @Environment(HookController.self) private var hooks

    var body: some View {
        SettingsPage {
            Section {
                LabeledContent("Hooks") {
                    Text(hooks.status.title)
                        .foregroundStyle(hooks.status == .installed ? .green : hooks.status == .outdated ? .orange : .secondary)
                }
                HStack {
                    Button(hooks.status == .notInstalled ? String(localized: "Установить hooks") : String(localized: "Обновить hooks")) { hooks.install() }
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
        }
        .onAppear { hooks.refresh() }
    }
}

// MARK: - Лимиты

private struct LimitSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var usage
    @State private var thresholdsText = ""

    var body: some View {
        @Bindable var settings = settings
        SettingsPage {
            Section {
                LabeledContent("Уведомлять на, %") {
                    TextField("50, 80, 95", text: $thresholdsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit(applyThresholds)
                }
                Toggle("Уведомления о лимитах ещё и в Telegram", isOn: $settings.limitAlertsToTelegram)
                if let error = usage.error {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Лимиты подписки")
            } footer: {
                Footnote(text: String(localized: "Данные — с того же адреса, что использует Claude Code (токен читается из связки ключей «Claude Code-credentials» и нигде не сохраняется). Уведомление — один раз на окно сессии/недели при пересечении порога и когда лимит восстановился. Значения пишутся в ~/Library/Application Support/ClaudePult/usage.json. Что показывать в строке меню — во вкладке «Внешний вид»."))
            }
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
