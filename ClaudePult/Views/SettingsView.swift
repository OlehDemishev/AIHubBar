import AppKit
import SwiftUI

/// Settings window like System Settings (SPEC-settings §2): a sidebar with search — the app's areas, the modules by
/// section (AI, Работа, Mac) and «Сервисы AI» with a page per AI; the chosen page on the right under its header.
/// One window size for every page.
struct SettingsView: View {
    /// What `settingsTab` stores; with `servicesTab` / `settingsModule` it names the open page (`SettingsPane`).
    enum Tab: String, CaseIterable {
        case general, modes, modules, panel, appearance, menuBar, services, module
    }

    static let size = CGSize(width: 940, height: 700)
    /// The window can grow; below this the module tiles and the menu bar editor get cramped.
    static let minSize = CGSize(width: 820, height: 560)

    @Environment(AppSettings.self) private var settings
    @Environment(AIServiceStore.self) private var services
    @Environment(HubLimitsStore.self) private var hub
    @Environment(ModeStore.self) private var modes
    @AppStorage(SettingsRoute.tabKey) private var tab: Tab = .general
    @AppStorage(SettingsRoute.serviceKey) private var service: ServiceTab = .claude
    @AppStorage(SettingsRoute.moduleKey) private var module: ModuleKind = .limits
    /// «Сервисы AI» folded by default: six rows the sidebar rarely needs.
    @AppStorage("settingsServicesExpanded") private var servicesExpanded = false
    @State private var query = ""

    init() {
        SettingsRoute.migrate()
    }

    private var pane: SettingsPane { SettingsPane(tab: tab, service: service, module: module) }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { pane }, set: { if let new = $0 { select(new) } })) {
                ForEach(SettingsPane.areas.filter { $0.matches(query) }, id: \.self) { pane in
                    PaneRow(pane: pane)
                }
                ForEach(ModuleGroup.allCases, id: \.self) { group in
                    let found = group.modules.filter(isListed).map(SettingsPane.module).filter { $0.matches(query) }
                    if !found.isEmpty {
                        Section(group.title) {
                            ForEach(found, id: \.self) { pane in
                                PaneRow(pane: pane, isOff: !isOn(pane))
                            }
                        }
                    }
                    if group == .ai {
                        let found = SettingsPane.services.filter { $0.matches(query) }
                        if !found.isEmpty {
                            Section("Сервисы AI", isExpanded: Binding(
                                // Open while searching or while one of them is the page shown.
                                get: { servicesExpanded || !query.isEmpty || pane.tab == .services },
                                set: { servicesExpanded = $0 }
                            )) {
                                ForEach(found, id: \.self) { pane in
                                    PaneRow(pane: pane, isSetUp: isSetUp(pane))
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text("Поиск"))
            .navigationSplitViewColumnWidth(230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                PaneHeader(pane: pane, isOn: mainSwitch)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .font(.system(size: 13.5))
            }
            .navigationTitle(pane.title)
        }
        .modifier(NoWindowToolbar())
        // The Settings scene makes a fixed-size window; this one may grow (SPEC-settings §2).
        .background(WindowReader { window in
            if let window { ResizableSettingsWindow.keep(window, minSize: Self.minSize, size: Self.size) }
        })
        .frame(minWidth: Self.minSize.width, idealWidth: Self.size.width, maxWidth: .infinity,
               minHeight: Self.minSize.height, idealHeight: Self.size.height, maxHeight: .infinity)
        .task { if services.agents.isEmpty { await services.scan() } }
        .preferredColorScheme(settings.panelTheme.colorScheme)
        .debugSnapshot("settings")
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .general: GeneralSettings()
        case .modes: ModesSettings()
        case .modules: ModuleCatalog { select(.module($0)) }
        case .panel: PanelBuilder()
        case .appearance: AppearanceSettings()
        case .menuBar: MenuBarSettings()
        case let .module(kind): ModulePage(kind: kind).id(kind)
        case let .service(service): ServicePage(service: service).id(service)
        }
    }

    /// «Раскладка» is offered only with beta builds (SPEC-layout).
    private func isListed(_ kind: ModuleKind) -> Bool { !kind.isBeta || settings.betaUpdates }

    private func isOn(_ pane: SettingsPane) -> Bool {
        guard case let .module(kind) = pane else { return true }
        return modes.isOn(kind)
    }

    private var mainSwitch: Binding<Bool>? {
        guard case let .module(kind) = pane, ModuleSwitch.canSwitch(kind, modes: modes) else { return nil }
        return Binding(get: { modes.isOn(kind) }, set: { modes.setOn(kind, $0) })
    }

    private func select(_ new: SettingsPane) {
        tab = new.tab
        if case let .service(chosen) = new { service = chosen }
        if case let .module(chosen) = new { module = chosen }
    }

    private func isSetUp(_ pane: SettingsPane) -> Bool? {
        guard case let .service(service) = pane else { return nil }
        return service.isSetUp(agents: Set(services.agents.keys), keys: services.hasKey, limits: hub.available.union(hub.savedKeys))
    }
}

/// SwiftUI makes the Settings window fixed-size and takes `.resizable` away again after each layout pass; this puts
/// it back every time it goes, so the window can grow (SPEC-settings §2).
@MainActor
enum ResizableSettingsWindow {
    private static var observed: [ObjectIdentifier: NSKeyValueObservation] = [:]

    static func keep(_ window: NSWindow, minSize: CGSize, size: CGSize) {
        let id = ObjectIdentifier(window)
        guard observed[id] == nil else { return }
        observed[id] = window.observe(\.styleMask, options: [.new]) { window, _ in
            guard !window.styleMask.contains(.resizable) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { window.styleMask.insert(.resizable) } }
        }
        DispatchQueue.main.async {
            window.styleMask.insert(.resizable)
            window.contentMinSize = minSize
            if window.frame.width < size.width || window.frame.height < size.height { window.setContentSize(size) }
        }
    }
}

/// No title strip above the pages: the page header already names the page, as in System Settings. Only the title
/// and the bar's background go — hiding the whole window toolbar takes the close / minimise buttons with it.
private struct NoWindowToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// A page's form: grouped, filling the page and scrolling.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

/// A settings row with an icon in front of its title, like the toggles and pickers that take `systemImage:`.
struct IconRow<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let content: Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        symbol = systemImage
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

extension IconRow where Content == Text {
    init(_ title: LocalizedStringKey, systemImage: String, value: String) {
        self.init(title, systemImage: systemImage) { Text(value) }
    }
}

/// The small text under a section. A long one shows its first sentence and «Подробнее» (SPEC-settings §2): the
/// pages read as settings, not as manuals.
struct Footnote: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        let short = Self.firstSentence(text)
        VStack(alignment: .leading, spacing: 2) {
            Text(expanded || short == nil ? text : short ?? text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if short != nil {
                Button(expanded ? String(localized: "Свернуть") : String(localized: "Подробнее")) {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
        }
    }

    /// The first sentence when the text is long and has more after it; nil — show it whole.
    nonisolated static func firstSentence(_ text: String) -> String? {
        guard text.count > 140 else { return nil }
        let ends = [". ", "。", "! ", "? "]
        let found = ends.compactMap { text.range(of: $0) }.filter { text.distance(from: text.startIndex, to: $0.lowerBound) >= 12 }
        guard let end = found.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let sentence = String(text[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        return text.count - sentence.count > 30 ? sentence : nil
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
                Toggle("Запускать при входе в систему", systemImage: "power", isOn: Binding(
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
                Picker("Открывать поиск с клавиатуры", systemImage: "magnifyingglass", selection: $settings.panelHotKey) {
                    ForEach(PanelHotKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.panelHotKey) { GlobalHotKey.register(settings.panelHotKey) }
            }

            Section {
                IconRow("Уведомления", systemImage: "bell") {
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

            TelegramBotSection()

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

            FeedbackSection()

            Section {
                IconRow("Версия", systemImage: "info.circle", value: Self.version)
                UpdatesRow()
                BetaRow()
                IconRow("Журнал", systemImage: "doc.text") {
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        @Bindable var settings = settings
        SettingsPage {
            Section("Панель") {
                Picker("Тема", systemImage: "circle.lefthalf.filled", selection: $settings.panelTheme) {
                    ForEach(PanelTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Фон панели", systemImage: "square.on.square", selection: $settings.panelBackground) {
                    ForEach(PanelBackground.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!glassSupported)
                if let backgroundNote {
                    Footnote(text: backgroundNote)
                }
                Picker("Размер текста", systemImage: "textformat.size", selection: $settings.panelTextSize) {
                    ForEach(PanelTextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Ширина", systemImage: "arrow.left.and.right", selection: $settings.panelWidth) {
                    ForEach(PanelWidth.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Плотность строк", systemImage: "line.3.horizontal", selection: $settings.panelDensity) {
                    ForEach(PanelDensity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Анимации при открытии", systemImage: "sparkle", isOn: $settings.panelAnimations)
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

private extension AppearanceSettings {
    var glassSupported: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    var backgroundNote: String? {
        if !glassSupported { return String(localized: "Стекло — в macOS 26 и новее.") }
        if settings.panelBackground == .glass, reduceTransparency {
            return String(localized: "Включено «Уменьшить прозрачность» — панель остаётся с обычным фоном.")
        }
        return nil
    }
}

/// A sample line at the chosen text size, so the effect is visible without opening the panel.
private struct TextSizePreview: View {
    let scale: CGFloat

    var body: some View {
        IconRow("Пример", systemImage: "textformat") {
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
/// Settings → «Сервисы AI» → Claude Code: all of Claude Code's options, as sections of that tab's form.
struct ClaudeSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = settings
        Group {
            Section {
                IconRow("Путь к claude", systemImage: "folder") {
                    TextField("", text: $settings.claudePath,
                              prompt: Text(ClaudeLocator.detect().map { String(localized: "авто: \($0)") } ?? String(localized: "авто: не найден")))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            } footer: {
                Footnote(text: String(localized: "Путь пустой — искать в /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.claude/local. Где запускать команды (Терминал / Фон / спрашивать) — у каждого профиля на вкладке «Профили»."))
            }

            SavedPromptsSection()

            Section {
                Button("Открыть инструкции и MCP-серверы…") {
                    NSApp.activate()
                    openWindow(id: "claude-config")
                }
            } header: {
                Text("CLAUDE.md и MCP")
            } footer: {
                Footnote(text: String(localized: "Отдельное окно: все CLAUDE.md и AGENTS.md (общие и проектов) с поиском и правкой, и MCP-серверы Claude Code с выключателем. То же окно — значок в низу панели."))
            }

            Section {
                Button("Сессии, hooks и фоновые задачи — «Сессии агентов»…") { SettingsRoute.open(module: .sessions) }
                    .buttonStyle(.link)
            }
        }
    }
}

/// «Сессии агентов» → «Фоновые задачи»: `claude -p` runs without a window, their time limit, night start and results.
struct BackgroundRunsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Stepper(value: $settings.backgroundTimeLimitMinutes, in: 10...600, step: 10) {
                IconRow("Лимит времени", systemImage: "timer", value: String(localized: "\(settings.backgroundTimeLimitMinutes) мин"))
            }
            Toggle("Итог в Telegram", systemImage: "paperplane", isOn: $settings.telegramForBackground)
            Picker("Ночные задачи начинаются в", systemImage: "moon.stars", selection: $settings.nightStartHour) {
                ForEach(NightQueue.hours, id: \.self) { Text(verbatim: String(format: "%02d:00", $0)).tag($0) }
            }
            if settings.telegramForBackground,
               Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) == nil {
                Text("Telegram не настроен (Настройки → Основные → Telegram) — будет только уведомление macOS.")
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

/// Settings → Основные → Telegram: the bot results, limits and summaries go to. Without it, a `_daily-report/config.json`
/// bot is used if there is one.
private struct TelegramBotSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var token = ""
    @State private var hasToken = false
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            if hasToken {
                IconRow("Токен бота", systemImage: "key") {
                    HStack {
                        Text("сохранён в связке ключей").foregroundStyle(.secondary)
                        Button("Удалить", role: .destructive) {
                            Task {
                                await APIKeyStore.delete(account: Telegram.keychainAccount)
                                hasToken = false
                                await Telegram.loadOwnBot(chatID: settings.telegramChatID)
                            }
                        }
                    }
                }
            } else {
                IconRow("Токен бота", systemImage: "key") {
                    HStack {
                        SecureField("", text: $token, prompt: Text(verbatim: "123456:ABC…"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Button("Сохранить", action: saveToken)
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            IconRow("ID чата", systemImage: "number") {
                HStack {
                    TextField("", text: $settings.telegramChatID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit { Task { await Telegram.loadOwnBot(chatID: settings.telegramChatID) } }
                    Button("Определить", action: detectChat)
                        .disabled(!hasToken || busy)
                        .help("Напишите боту любое сообщение, затем нажмите — ID чата подставится сам")
                    Button("Проверить", action: test)
                        .disabled(!hasToken || settings.telegramChatID.isEmpty || busy)
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Telegram")
        } footer: {
            Footnote(text: String(localized: "Сюда приходят итоги фоновых задач, пороги лимитов, недельная сводка, напоминания календаря — где в модуле включён Telegram. Бот создаётся у @BotFather; токен хранится только в связке ключей. Пока здесь пусто, используется бот из _daily-report/config.json, если он есть."))
        }
        .task {
            hasToken = await APIKeyStore.exists(account: Telegram.keychainAccount)
        }
        .onChange(of: settings.telegramChatID) { Task { await Telegram.loadOwnBot(chatID: settings.telegramChatID) } }
    }

    private func saveToken() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await APIKeyStore.save(value, account: Telegram.keychainAccount, label: "Telegram bot")
                token = ""
                hasToken = true
                await Telegram.loadOwnBot(chatID: settings.telegramChatID)
                status = String(localized: "Токен сохранён. Напишите боту любое сообщение и нажмите «Определить».")
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func detectChat() {
        busy = true
        Task {
            defer { busy = false }
            guard let token = await APIKeyStore.read(account: Telegram.keychainAccount),
                  let chat = await Telegram.latestChat(token: token) else {
                status = String(localized: "Сообщений боту не нашлось: напишите ему что-нибудь и попробуйте снова.")
                return
            }
            settings.telegramChatID = chat
            await Telegram.loadOwnBot(chatID: chat)
            status = String(localized: "Чат найден.")
        }
    }

    private func test() {
        busy = true
        Task {
            defer { busy = false }
            await Telegram.loadOwnBot(chatID: settings.telegramChatID)
            guard let bot = Telegram.ownBot else { return }
            let ok = await Telegram.send(html: RunMessage.escape(String(localized: "AI Hub Bar: Telegram работает.")), with: bot)
            status = ok ? String(localized: "Отправлено") : String(localized: "Не отправилось: проверьте токен и ID чата")
        }
    }
}

/// Settings → «Сервисы AI» → Claude Code → «Свои промпты»: title and text; the search (⌃⌥C) offers them by title.
private struct SavedPromptsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach($settings.savedPrompts) { $prompt in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Название", text: $prompt.title)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            settings.savedPrompts.removeAll { $0.id == prompt.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Удалить промпт")
                    }
                    TextField("Текст", text: $prompt.text, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.vertical, 2)
            }
            Button("Добавить промпт") {
                settings.savedPrompts.append(SavedPrompt(title: String(localized: "Новый промпт"), text: ""))
            }
        } header: {
            Text("Свои промпты")
        } footer: {
            Footnote(text: String(localized: "Наберите название в поиске (⌃⌥C), выберите проект — Claude запустится с этим текстом. Подстановки: {проект}, {ветка}, {файл} — файл, выделенный в Finder (macOS один раз спросит разрешение)."))
        }
    }
}

// MARK: - Модули

/// «бета» next to a module still in beta testing.
struct BetaBadge: View {
    var body: some View {
        Text("бета")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.orange)
            .background(.orange.opacity(0.15), in: Capsule())
    }
}

/// «Раскладка» (SPEC-layout §4): the permission, the layouts it switches between and the few switches it has.
struct LayoutSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LayoutSwitcher.self) private var switcher

    var body: some View {
        @Bindable var settings = settings
        Section {
            if !switcher.trusted {
                LabeledContent {
                    Button("Открыть настройки") { switcher.requestAccess() }
                } label: {
                    Label("Нужен доступ к «Универсальному доступу»", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            IconRow("Раскладки", systemImage: "keyboard", value: switcher.layouts.isEmpty ? String(localized: "нет подходящих") : switcher.layouts.map(\.name).joined(separator: ", "))
            Toggle("Исправлять раскладку сам", systemImage: "wand.and.stars", isOn: $settings.layout.auto)
            Toggle("Не исправлять в терминалах", systemImage: "terminal", isOn: $settings.layout.skipTerminals)
                .disabled(!settings.layout.auto)
            Toggle("Двойной Shift — последнее слово", systemImage: "shift", isOn: $settings.layout.doubleShift)
            Toggle("⌥⇧ — выделенный текст", systemImage: "option", isOn: $settings.layout.optionShift)
            Toggle("Язык в строке меню", systemImage: "menubar.rectangle", isOn: $settings.layout.menuBarIcon)
                .onChange(of: settings.layout.menuBarIcon) { switcher.sync() }
        } header: {
            Text("Раскладка")
        } footer: {
            Footnote(text: switcher.layouts.count < 2
                ? String(localized: "Нужны хотя бы две раскладки из: русская, английская, украинская, немецкая, французская, испанская, португальская. Добавьте их в Системных настройках → Клавиатура → Источники ввода.")
                : String(localized: "Слово проверяется системным словарём, когда вы ставите пробел, Enter или Tab. Двойной Shift сразу после исправления отменяет его и запоминает слово. Пароли и поля паролей не читаются, набранное никуда не записывается."))
        }
        Section {
            if settings.layout.learned.isEmpty {
                Text("Пока пусто")
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.layout.learned, id: \.self) { word in
                LabeledContent(word) {
                    Button("Убрать") { switcher.forgetLearned(word) }
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Не исправлять")
        } footer: {
            Footnote(text: String(localized: "Слова, исправление которых вы отменили двойным Shift или ⌘Z. Уберите слово, чтобы оно снова исправлялось."))
        }
    }
}

/// «Остров у чёлки» (SPEC-notch §6): what the ears show and how the card opens.
struct NotchSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Скрыть остров", systemImage: "eye.slash", isOn: $settings.notch.hidden)
            Picker("Сводка — лимиты и сессии", systemImage: "rectangle.split.2x1", selection: $settings.notch.summary) {
                ForEach(NotchSummary.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Где показывать", systemImage: "display", selection: $settings.notch.screen) {
                ForEach(NotchScreen.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Пилюля на экранах без чёлки", systemImage: "capsule", isOn: Binding(
                get: { settings.notch.showsPill(macHasNotch: NotchGeometry.macHasNotch) },
                set: { settings.notch.pill = $0 }
            ))
        } header: {
            Text("Остров у чёлки")
        } footer: {
            Footnote(text: String(localized: "«Только в острове»: в строке меню остаются значок и красная точка проектов, лимиты и сессии — в ушках у чёлки. Пилюля — чёрный остров под строкой меню по центру, только для событий и запросов: у неё нет ушек, поэтому сводка тогда остаётся в строке меню. Скрытый остров ничего не показывает, уведомления приходят как обычно."))
        }
        Section {
            Picker("Слева от чёлки", systemImage: "arrow.left.to.line", selection: $settings.notch.leftEar) {
                ForEach(NotchEar.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Справа от чёлки", systemImage: "arrow.right.to.line", selection: $settings.notch.rightEar) {
                ForEach(NotchEar.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Открывать карточку при наведении", systemImage: "cursorarrow.motionlines", isOn: $settings.notch.openOnHover)
            Toggle("Файл на остров — AI-команды", systemImage: "doc.badge.arrow.up", isOn: $settings.notch.fileDrop)
                .help("Перетащите файл или папку на чёлку: команды профиля и «Своя задача» для него, результат — новым файлом рядом.")
            Toggle("Ход работы Claude в ушке сессий", systemImage: "list.bullet.clipboard", isOn: $settings.notch.liveActivity)
                .help("Кольцо и «3/7» по списку задач Claude, шаги в карточке, итог в «Готово». Без списка — минуты с начала ответа.")
            Toggle("Горячие клавиши ⌃⌥Y / ⌃⌥N для запросов", systemImage: "keyboard", isOn: $settings.notch.hotKeys)
                .onChange(of: settings.notch.hotKeys) { GlobalHotKey.registerIsland(settings.notch.hotKeys) }
                .help("Разрешить или отклонить запрос, который сейчас в острове. Клавишей легко разрешить, не прочитав команду.")
        } header: {
            Text("Ушки и карточка")
        } footer: {
            Footnote(text: NotchGeometry.macHasNotch
                ? String(localized: "Без наведения карточка открывается кликом по чёлке. В покое остров пропускает клики к строке меню.")
                : String(localized: "На этом Маке сейчас нет экрана с чёлкой: остров появится, когда она будет (например, на встроенном экране MacBook)."))
        }
        Section {
            ForEach(NotchEventKind.allCases, id: \.self) { kind in
                Toggle(isOn: Binding(
                    get: { settings.notch.events.contains(kind) },
                    set: { on in
                        settings.notch.events = NotchEventKind.allCases.filter { $0 == kind ? on : settings.notch.events.contains($0) }
                    }
                )) {
                    Label(kind.title, systemImage: kind.symbol)
                }
            }
            Toggle("Запросы и ожидание — только в острове", systemImage: "bell.slash", isOn: $settings.notch.replaceNotifications)
        } header: {
            Text("События в острове")
        } footer: {
            Footnote(text: String(localized: "Событие ненадолго раскрывает остров; запрос разрешения держится, пока на него не ответят. «Только в острове»: пока остров виден, уведомление о запросе или ожидании не приходит; если острова не видно (экран спит, Мак заблокирован, полноэкранное приложение), уведомление придёт как обычно. Telegram — без изменений."))
        }
    }
}

struct ResourceSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Уведомлять о нагрузке, памяти, месте и заряде", systemImage: "bell.badge", isOn: $settings.resourceAlerts)
            Picker("Мало места — свободно меньше", systemImage: "internaldrive", selection: $settings.resourceDiskBelowGB) {
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

struct KeepAwakeSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(KeepAwakeController.self) private var keepAwake
    @State private var lidBusy = false
    @State private var lidError: String?
    @State private var sleepOffNow = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Пока работает Claude (сессия или фоновая задача)", systemImage: "sparkles", isOn: $settings.keepAwakeRules.whileClaudeWorks)
            Toggle("Пока подключено питание", systemImage: "powerplug", isOn: $settings.keepAwakeRules.whileOnPower)
            Toggle("Пока подключён внешний монитор", systemImage: "display", isOn: $settings.keepAwakeRules.whileExternalDisplay)
            IconRow("Пока открыты приложения", systemImage: "app.badge") {
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
            Toggle("Не гасить и экран", systemImage: "sun.max", isOn: $settings.keepAwakeRules.keepDisplayOn)
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
            Toggle("И с закрытой крышкой", systemImage: "laptopcomputer", isOn: $settings.keepAwakeRules.lidClosed)
                .disabled(!keepAwake.lidInstalled || !LidSleep.hasLid)
            IconRow("Разрешение администратора", systemImage: "lock.shield") {
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
struct QuickCommandsSection: View {
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
                    Picker("Что делает", systemImage: "bolt", selection: $command.kind) {
                        ForEach(QuickCommand.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField(placeholder(command.kind), text: $command.value)
                        .font(.callout.monospaced())
                    Toggle("Спрашивать перед запуском", systemImage: "questionmark.circle", isOn: $command.confirm)
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

struct QuickTogglesSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModeStore.self) private var modes

    var body: some View {
        Section {
            ForEach(QuickToggle.available(installed: modes.activeModules), id: \.self) { toggle in
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

struct ClipboardSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClipboardHistory.self) private var history

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Хранить последних", systemImage: "tray.full", selection: $settings.clipboardLimit) {
                ForEach([20, 50, 100, 200], id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            Toggle("Помнить после перезапуска", systemImage: "arrow.clockwise", isOn: $settings.clipboardRemember)
                .onChange(of: settings.clipboardRemember) { history.rememberChanged() }
            IconRow("Не запоминать из приложений", systemImage: "hand.raised.slash") {
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

struct NotesSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NotesStore.self) private var notes

    var body: some View {
        Section {
            IconRow("Папка", systemImage: "folder") {
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

struct ReminderSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Напоминать", systemImage: "alarm", selection: Binding(
                get: { settings.calendarReminderHours },
                set: { settings.calendarReminderHours = $0 }
            )) {
                Text("не напоминать").tag([Int]())
                Text("за 2 часа").tag([2])
                Text("за сутки").tag([24])
                Text("за сутки и за 2 часа").tag([24, 2])
                Text("за 3 дня и за сутки").tag([72, 24])
            }
            Toggle("Дублировать напоминания в Telegram", systemImage: "paperplane", isOn: $settings.calendarRemindersToTelegram)
        } header: {
            Text("Напоминания")
        } footer: {
            Footnote(text: String(localized: "Даты — из проект.md (дедлайн, публикация) и контент-план.md у профилей с календарём (вкладка «Профили»)."))
        }
    }
}

// MARK: - Claude Code: sessions

/// Notifications about open pull requests of the projects.
struct PullRequestAlertSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Уведомлять, когда CI упал или починился и когда PR закрыт", systemImage: "arrow.triangle.pull", isOn: $settings.pullRequestAlerts)
            Toggle("Дублировать в Telegram", systemImage: "paperplane", isOn: $settings.pullRequestAlertsToTelegram)
                .disabled(!settings.pullRequestAlerts)
        } header: {
            Text("Pull requests")
        } footer: {
            Footnote(text: String(localized: "По данным списка проектов (gh): обновляется раз в 5 минут и при открытии панели. Клик по уведомлению открывает PR."))
        }
    }
}

/// Permission requests answered from the phone, through a bot of ClaudePult's own.
struct TelegramApprovalsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TelegramApprovals.self) private var telegram
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Присылать запросы разрешений в Telegram", systemImage: "paperplane", isOn: $settings.telegramApprovals)
            IconRow("Токен бота", systemImage: "key") {
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
            TextField("ID чата", text: $settings.telegramApprovalsChatID, prompt: Text("как в «Основные → Telegram»"))
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
            Footnote(text: String(localized: "Нужен отдельный бот, не тот, что в «Основные → Telegram»: эти ответы бот получает через свои обновления, а у основного бота их может читать другая программа (например, бот _daily-report), и они забирали бы сообщения друг у друга. Создайте бота в @BotFather (/newbot), вставьте его токен, откройте бота в Telegram и нажмите «Start», затем «Проверить». Кнопки принимаются только из указанного чата."))
        }
    }
}

struct SessionSection: View {
    @Environment(HookController.self) private var hooks
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            IconRow("Hooks", systemImage: "link") {
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
            Toggle("Отвечать на запросы разрешений из уведомлений и панели", systemImage: "hand.raised", isOn: $settings.approvalsFromClaudePult)
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

struct LimitSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var usage
    @Environment(WeeklySummarySender.self) private var weeklySummary
    @State private var thresholdsText = ""
    @State private var summarySent: Bool?

    var body: some View {
        @Bindable var settings = settings
        Section {
            IconRow("Уведомлять на, %", systemImage: "bell.badge") {
                // No title: in a Form a titled field also shows its title as a label next to it.
                TextField("", text: $thresholdsText, prompt: Text(verbatim: "50, 80, 95"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit(applyThresholds)
            }
            Toggle("Уведомления о лимитах ещё и в Telegram", systemImage: "paperplane", isOn: $settings.limitAlertsToTelegram)
            VStack(alignment: .leading, spacing: 2) {
                Picker("Ставить фоновые задачи на паузу", systemImage: "pause.circle", selection: $settings.runGuardPercent) {
                    ForEach(RunGuard.thresholds, id: \.self) { value in
                        Text(value == 0 ? String(localized: "никогда") : String(localized: "с \(value) %")).tag(value)
                    }
                }
                Text("Когда сессия или неделя дошла до порога, фоновые задачи замирают там, где были, а запланированные ждут. После сброса лимита работа продолжается сама. Так задача не обрывается на полпути из-за лимита.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Сводка за неделю в Telegram", systemImage: "calendar.badge.clock", isOn: $settings.weeklySummary)
                if settings.weeklySummary {
                    HStack {
                        Picker("День", selection: $settings.weeklySummaryWeekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(Calendar.current.standaloneWeekdaySymbols[day - 1].capitalized).tag(day)
                            }
                        }
                        Picker("Час", selection: $settings.weeklySummaryHour) {
                            ForEach(6...23, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        .frame(width: 140)
                    }
                }
                HStack {
                    Button("Отправить сейчас") {
                        Task { summarySent = await weeklySummary.send() }
                    }
                    .controlSize(.small)
                    if let summarySent {
                        Text(summarySent ? String(localized: "Отправлено") : String(localized: "Не отправилось: Telegram не настроен (Основные → Telegram) или нет связи"))
                            .font(.caption)
                            .foregroundStyle(summarySent ? Color.secondary : Color.orange)
                    }
                }
                Text("Своим сообщением, через бота ежедневного отчёта: расход недели по проектам, самые тяжёлые сессии, сколько раз упирался в лимит, итоги фоновых задач.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Продлевать вход Claude Code сам", systemImage: "key", isOn: $settings.renewClaudeLogin)
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
        Picker("Язык интерфейса", systemImage: "globe", selection: $choice) {
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

/// Ideas and problems go to the repository's issue forms (Feedback); after a crash the app offers to report it.
private struct FeedbackSection: View {
    @AppStorage(CrashReports.askKey) private var asksAfterCrash = true

    var body: some View {
        Section {
            IconRow("Обратная связь", systemImage: "envelope") {
                HStack {
                    Button("Предложить идею…") { Feedback.suggestIdea() }
                    Button("Сообщить о проблеме…") { Feedback.reportProblem() }
                }
            }
            Toggle("После сбоя предлагать отправить отчёт", systemImage: "exclamationmark.bubble", isOn: $asksAfterCrash)
        } footer: {
            Footnote(text: String(localized: "Откроется форма на GitHub, версия и macOS в ней уже заполнены. Сама программа ничего не отправляет: перед отправкой видно всё, что уходит. Нужен аккаунт GitHub."))
        }
    }
}

/// «Проверить обновления» and the daily check (Sparkle, scripts/release.sh).
private struct UpdatesRow: View {
    @State private var automatic = Updates.checksAutomatically

    var body: some View {
        IconRow("Обновления", systemImage: "arrow.down.circle") {
            HStack {
                Toggle("Проверять раз в день", systemImage: "clock.arrow.circlepath", isOn: $automatic)
                    .onChange(of: automatic) { Updates.checksAutomatically = automatic }
                Button("Проверить сейчас") { Updates.checkNow() }
            }
        }
    }
}

/// «Бета-версии»: beta builds before everyone else, and the modules still in beta testing.
private struct BetaRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Toggle(isOn: $settings.betaUpdates) {
            Text("Бета-версии")
            Text("Новые сборки раньше всех и функции на испытании: \(ModuleKind.allCases.filter(\.isBeta).map(\.title).joined(separator: ", ")). Может работать с ошибками; выключите — останетесь на этой версии до следующего обычного выпуска.")
        }
    }
}
