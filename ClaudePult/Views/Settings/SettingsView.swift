import AppKit
import SwiftUI

/// Settings window like System Settings (SPEC-settings §2): a sidebar with search — the app's areas, the modules by
/// section (AI, Работа, Mac) and «Сервисы AI» with a page per AI; the chosen page on the right under its header.
/// One window size for every page.
struct SettingsView: View {
    static let size = CGSize(width: 940, height: 700)
    /// The window can grow; below this the module tiles and the menu bar editor get cramped.
    static let minSize = CGSize(width: 820, height: 560)

    @Environment(AppSettings.self) private var settings
    @Environment(AIServiceStore.self) private var services
    @Environment(HubLimitsStore.self) private var hub
    @Environment(ModeStore.self) private var modes
    @AppStorage(StorageKey.settingsPage) private var pane: SettingsPane = .general
    /// «Сервисы AI» folded by default: six rows the sidebar rarely needs.
    @AppStorage(StorageKey.servicesExpanded) private var servicesExpanded = false
    @State private var query = ""

    init() {
        SettingsRoute.migrate()
    }

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
                                get: { servicesExpanded || !query.isEmpty || pane.isService },
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
        pane = new
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
            DispatchQueue.main.async { MainActor.assumeIsolated { window.styleMask.formUnion(.resizable) } }
        }
        DispatchQueue.main.async {
            window.styleMask.formUnion(.resizable)
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
    /// Where `claude` was found: looked up once, not on every keystroke in the path field (SPEC-refactor §2.8).
    @State private var detected: String??

    var body: some View {
        @Bindable var settings = settings
        Group {
            Section {
                IconRow("Путь к claude", systemImage: "folder") {
                    TextField("", text: $settings.claudePath,
                              prompt: Text(detectedText))
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
                    openWindow(.claudeConfig)
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
        .task { if detected == nil { detected = ClaudeLocator.detect() } }
    }

    private var detectedText: String {
        switch detected {
        case .none: String(localized: "авто: …")
        case .some(.none): String(localized: "авто: не найден")
        case let .some(.some(path)): String(localized: "авто: \(path)")
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










// MARK: - Claude Code: sessions




// MARK: - Claude Code: limits


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
