import AppKit
import SwiftUI

/// An AI under «Сервисы AI» in the Settings sidebar (SPEC-ai-services §4), with everything that belongs to it.
enum ServiceTab: String, CaseIterable, Sendable {
    case claude, codex, gemini, copilot, cursor, other

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .copilot: "Copilot"
        case .cursor: "Cursor"
        case .other: String(localized: "Другие")
        }
    }

    var icon: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "terminal"
        case .gemini: "diamond"
        case .copilot: "person.2"
        case .cursor: "cursorarrow.rays"
        case .other: "ellipsis"
        }
    }

    /// Something of this service works here: an agent found, an API key saved or its limits available.
    func isSetUp(agents: Set<AgentKind>, keys: Set<APIProvider>, limits: Set<HubLimit.Source>) -> Bool {
        self.agents.contains(where: agents.contains)
            || providers.contains(where: keys.contains)
            || hubSources.contains(where: limits.contains)
    }

    var agents: [AgentKind] { AgentKind.allCases.filter { ServiceTab(agent: $0) == self } }
    var providers: [APIProvider] { APIProvider.allCases.filter { ServiceTab(provider: $0) == self } }
    var hubSources: [HubLimit.Source] { HubLimit.Source.allCases.filter { ServiceTab(hub: $0) == self } }

    init(agent: AgentKind) {
        switch agent {
        case .claudeCode: self = .claude
        case .codex: self = .codex
        case .gemini, .antigravity: self = .gemini
        case .copilot: self = .copilot
        case .cursor: self = .cursor
        }
    }

    init(provider: APIProvider) {
        switch provider {
        case .anthropic: self = .claude
        case .openai: self = .codex
        case .google: self = .gemini
        case .xai, .deepseek, .mistral, .qwen, .kimi, .glm, .minimax, .compatible: self = .other
        }
    }

    init(hub: HubLimit.Source) {
        switch hub {
        case .anthropicCosts: self = .claude
        case .codex, .openAICosts: self = .codex
        case .gemini: self = .gemini
        case .copilot: self = .copilot
        case .cursor: self = .cursor
        case .openRouter: self = .other
        }
    }
}

/// Settings → «Сервисы AI» → one AI (SPEC-ai-services §4): everything that belongs to it — the agent, its limits,
/// its API access and, for Claude Code, all of Claude Code's options.
struct ServicePage: View {
    let service: ServiceTab

    var body: some View {
        Form {
            if service == .claude {
                ClaudeSettings()
            }
            if !service.agents.isEmpty, service != .claude {
                AgentsSection(kinds: service.agents)
            }
            if service == .copilot {
                AgentStatesSection(agent: .copilot)
            }
            if service == .codex {
                AgentStatesSection(agent: .codex)
            }
            if !service.hubSources.isEmpty {
                LimitsSourcesSection(sources: service.hubSources)
            }
            ThresholdsSection(service: service)
            if !service.providers.isEmpty {
                ProvidersSection(providers: service.providers)
            }
            if service == .other {
                SpendSection()
            }
        }
        .formStyle(.grouped)
    }
}

/// When this service's limits notify (SPEC-ai-services stage 4): at the common thresholds from «Модули → Лимиты»,
/// at its own, or never.
private struct ThresholdsSection: View {
    let service: ServiceTab
    @Environment(AppSettings.self) private var settings
    @State private var text = ""

    enum AlertMode: Hashable { case common, own, off }

    private var mode: AlertMode {
        guard let own = settings.serviceThresholds[service.rawValue] else { return .common }
        return own.isEmpty ? .off : .own
    }

    var body: some View {
        Section {
            Picker("Уведомлять о лимите", systemImage: "bell", selection: Binding(get: { mode }, set: { choose($0) })) {
                Text("как у всех: \(Self.list(settings.limitThresholds)) %").tag(AlertMode.common)
                Text("на своих порогах").tag(AlertMode.own)
                Text("не уведомлять").tag(AlertMode.off)
            }
            if mode == .own {
                IconRow("Пороги, %", systemImage: "bell.badge") {
                    TextField("", text: $text, prompt: Text(verbatim: "80, 95"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit(apply)
                }
            }
        } header: {
            Text("Уведомления о лимитах")
        } footer: {
            Footnote(text: String(localized: "Один раз на окно лимита, когда порог пройден. Общие пороги — на странице «Лимиты AI»."))
        }
        .onAppear { text = Self.list(settings.thresholds(for: service)) }
        .onDisappear { if mode == .own { apply() } }
    }

    private func choose(_ new: AlertMode) {
        switch new {
        case .common: settings.serviceThresholds[service.rawValue] = nil
        case .own: settings.serviceThresholds[service.rawValue] = settings.thresholds(for: service).isEmpty ? settings.limitThresholds : settings.thresholds(for: service)
        case .off: settings.serviceThresholds[service.rawValue] = []
        }
        text = Self.list(settings.thresholds(for: service))
    }

    /// «80, 95» → [80, 95]; invalid input keeps the previous thresholds.
    private func apply() {
        let values = SettingsParsing.thresholds(text)
        if !values.isEmpty { settings.serviceThresholds[service.rawValue] = values }
        text = Self.list(settings.thresholds(for: service))
    }

    static func list(_ values: [Int]) -> String { values.map(String.init).joined(separator: ", ") }
}

/// The tab's agents: installed or not, with the install command and the sign-in.
private struct AgentsSection: View {
    let kinds: [AgentKind]
    @Environment(AIServiceStore.self) private var services

    var body: some View {
        Section {
            ForEach(kinds, id: \.self) { kind in
                AgentRow(kind: kind, info: services.agents[kind])
            }
        } header: {
            HStack {
                Text("Агенты — работают с файлами в папке проекта")
                Spacer()
                Button("Найти заново") { Task { await services.scan() } }
                    .controlSize(.small)
                    .disabled(services.isScanning)
            }
        } footer: {
            Footnote(text: String(localized: "Вход у каждого агента свой (его команда в подсказке), AI Hub Bar их токены не трогает. В фоне пока работает только Claude Code: остальные открываются в Терминале, пока их запрет действий не проверен вживую."))
        }
    }
}

/// Copilot or Codex CLI sessions in «Сессии» with «работает / ждёт / готово» through AI Hub Bar's hook
/// (`CopilotHooks`, `CodexHooks`).
private struct AgentStatesSection: View {
    let agent: AgentKind
    @Environment(AppSettings.self) private var settings
    @State private var status: HookStatus = .notInstalled
    @State private var message: String?

    /// The agent's hook file: status and changes, the same for both.
    private var hooks: (status: () -> HookStatus, install: () throws -> Void, uninstall: () throws -> Void, update: () throws -> Bool) {
        if agent == .codex {
            let hooks = CodexHooks.live(projectsDirectory: settings.projectsDirectory)
            return (hooks.status, { try hooks.install() }, { try hooks.uninstall() }, hooks.updateScriptIfNeeded)
        }
        let hooks = CopilotHooks.live(projectsDirectory: settings.projectsDirectory)
        return (hooks.status, hooks.install, hooks.uninstall, hooks.updateScriptIfNeeded)
    }

    /// One hook here, not Claude's «hooks».
    private var statusText: String {
        switch status {
        case .installed, .notInstalled, .outdated: status.title
        }
    }

    private var label: String { String(localized: "Отслеживание сессий") }

    private var header: String {
        agent == .codex ? String(localized: "Состояние сессий Codex") : String(localized: "Состояние сессий Copilot")
    }

    private var footnote: String {
        agent == .codex
            ? String(localized: "С отслеживанием сессии Codex CLI видны в «Сессиях» как у Claude: работает, ждёт разрешения, готово — и «ждёт» приходит уведомлением. Записи AI Hub Bar добавляются в ~/.codex/hooks.json (перед изменением — резервная копия рядом), другие hooks Codex не трогаются. Codex запускает новый hook только после проверки: один раз откройте codex, введите /hooks и доверьте hooks AI Hub Bar. Подхватывается новыми сессиями Codex.")
            : String(localized: "С отслеживанием сессии Copilot CLI видны в «Сессиях» как у Claude: работает, ждёт разрешения или ответа, готово — и «ждёт» приходит уведомлением. Это отдельный файл ~/.copilot/hooks/aihubbar.json; другие hooks Copilot не трогаются. Подхватывается новыми сессиями Copilot.")
    }

    var body: some View {
        Section {
            LabeledContent(label, value: statusText)
            HStack {
                if status != .installed {
                    Button(status == .outdated ? String(localized: "Обновить отслеживание") : String(localized: "Включить отслеживание")) {
                        perform { try hooks.install() }
                    }
                    .help(agent == .codex ? String(localized: "Добавить записи AI Hub Bar в ~/.codex/hooks.json")
                        : String(localized: "Записать файл ~/.copilot/hooks/aihubbar.json"))
                }
                if status != .notInstalled {
                    Button("Выключить отслеживание") { perform { try hooks.uninstall() } }
                        .help(String(localized: "Убрать hook AI Hub Bar; другие hooks агента остаются"))
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(header)
        } footer: {
            Footnote(text: footnote)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        _ = try? hooks.update()
        status = hooks.status()
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            message = agent == .codex && hooks.status() == .installed
                ? String(localized: "Готово. Теперь в codex введите /hooks и доверьте hooks AI Hub Bar — до этого Codex их пропускает.") : nil
        } catch {
            message = error.localizedDescription
            AppLog.error("\(agent.binary) hook install/uninstall failed: \(error.localizedDescription)")
        }
        refresh()
        AppLog.info("\(agent.binary) hook: \(status)")
    }
}

/// The tab's limit sources from «Другие AI» (SPEC-hub): on/off, status, keys and consents.
private struct LimitsSourcesSection: View {
    let sources: [HubLimit.Source]
    @Environment(HubLimitsStore.self) private var hub

    var body: some View {
        Section {
            ForEach(sources) { source in
                HubSourceRow(source: source)
            }
            HStack {
                Button("Проверить сейчас") { Task { await hub.refresh() } }
                    .disabled(hub.isRefreshing)
                if hub.isRefreshing { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Лимиты и расход")
        } footer: {
            Footnote(text: String(localized: "Сервис появляется под кольцами Claude сам, когда найден на Mac или сохранён его ключ. Ключи хранятся только в связке ключей. Codex и Copilot спрашиваются через свои программы (codex, gh); вход Gemini CLI и Cursor читается только с вашего согласия. Обновляется раз в 5 минут. Форматы ответов не документированы производителями и могут поменяться."))
        }
    }
}

private struct ProvidersSection: View {
    let providers: [APIProvider]

    var body: some View {
        Section {
            ForEach(providers, id: \.self) { provider in
                ProviderRow(provider: provider)
            }
        } header: {
            Text("Модели по API — получают только текст")
        } footer: {
            Footnote(text: String(localized: "Ключ хранится только в связке ключей macOS (запись «ClaudePult API key»), не пишется в журнал и не попадает в экспорт. «Проверить» запрашивает список моделей — токены на это не тратятся. Модели по API выполняют команды проектов-папок."))
        }
    }
}

/// Spend of AI Hub Bar's own API requests and the monthly budget.
private struct SpendSection: View {
    @Environment(AIServiceStore.self) private var services
    @Environment(CommandEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let today = engine.summary(since: Calendar.current.startOfDay(for: .now))
        let month = engine.summary(since: engine.monthStart)
        Section {
            IconRow("Сегодня", systemImage: "sun.max", value: SpendText.line(today))
            IconRow("В этом месяце", systemImage: "calendar", value: SpendText.line(month))
            IconRow("Бюджет в месяц, $", systemImage: "dollarsign.circle") {
                TextField("", value: $settings.aiServices.monthlyBudget, format: .number, prompt: Text("нет"))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            // Anthropic always: «История расхода» counts Claude Code's tokens at this price, no key needed.
            ForEach(APIProvider.allCases.filter { services.hasKey.contains($0) || $0 == .compatible || $0 == .anthropic }, id: \.self) { provider in
                LabeledContent("\(provider.title): $ за 1 млн токенов (вход / выход)") {
                    HStack(spacing: 4) {
                        TextField("", value: price(provider, \.input), format: .number, prompt: Text("—")).frame(width: 60)
                        Text("/")
                        TextField("", value: price(provider, \.output), format: .number, prompt: Text("—")).frame(width: 60)
                    }
                    .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Расход по API")
        } footer: {
            Footnote(text: String(localized: "AI Hub Bar считает токены своих запросов по ответам сервисов; стоимость — по ценам, которые вы введёте (цены меняются, поэтому они не зашиты). Уведомление при 80 % и 100 % бюджета."))
        }
    }

    private func price(_ provider: APIProvider, _ path: WritableKeyPath<APIPrice, Double>) -> Binding<Double?> {
        Binding(
            get: { settings.aiServices.prices[provider.rawValue]?[keyPath: path] },
            set: { value in
                var price = settings.aiServices.prices[provider.rawValue] ?? APIPrice(input: 0, output: 0)
                price[keyPath: path] = value ?? 0
                settings.aiServices.prices[provider.rawValue] = price.input == 0 && price.output == 0 ? nil : price
            }
        )
    }
}

enum SpendText {
    static func line(_ summary: SpendSummary) -> String {
        guard summary.tokens > 0 else { return "—" }
        let tokens = TokenBreakdown.tokensText(summary.tokens) + String(localized: " токенов")
        return summary.cost.map { tokens + String(format: " · $%.2f", $0) } ?? tokens
    }
}

private struct AgentRow: View {
    let kind: AgentKind
    let info: AIServiceStore.AgentInfo?

    var body: some View {
        LabeledContent {
            if let info {
                Text(info.version ?? String(localized: "установлен"))
                    .foregroundStyle(.secondary)
                    .help(info.path)
            } else {
                HStack(spacing: 6) {
                    Text("не установлен").foregroundStyle(.tertiary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(kind.install, forType: .string)
                    } label: { Label("Скопировать: \(kind.install)", systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Скопировать: \(kind.install)")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(info == nil ? kind.install : String(localized: "Вход: \(kind.login)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let note = kind.note {
                    Text(note).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: APIProvider

    @Environment(AIServiceStore.self) private var services
    @Environment(AppSettings.self) private var settings
    @State private var keyText = ""
    @State private var error: String?
    @State private var editing = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider == .compatible && !settings.aiServices.compatibleName.isEmpty
                     ? settings.aiServices.compatibleName : provider.title)
                Spacer()
                status
            }
            if provider == .compatible {
                TextField("Название", text: $settings.aiServices.compatibleName, prompt: Text("Ollama, LM Studio, OpenRouter…"))
                TextField("Адрес", text: $settings.aiServices.compatibleBaseURL, prompt: Text(APIProvider.compatible.defaultBaseURL))
            }
            if editing || (!services.hasKey.contains(provider) && provider.keyRequired) {
                HStack {
                    SecureField("Ключ API", text: $keyText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Сохранить", action: save)
                        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let page = provider.keyPage, let url = URL(string: page) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .help("Где взять ключ: \(page)")
                            .accessibilityLabel("Где взять ключ: \(page)")
                    }
                }
            }
            HStack(spacing: 10) {
                if services.hasKey.contains(provider) || !provider.keyRequired {
                    Button("Проверить") { Task { await services.check(provider) } }
                        .disabled(services.checking.contains(provider))
                }
                if services.hasKey.contains(provider) {
                    Button(editing ? String(localized: "Отмена") : String(localized: "Заменить ключ")) { editing.toggle(); keyText = "" }
                    ConfirmedButton(title: "Удалить ключ", message: provider.title) {
                        Task { await services.deleteKey(provider) }
                    } label: { Text("Удалить ключ") }
                }
                if !provider.keyRequired, !services.hasKey.contains(provider) {
                    Button("Ключ (если нужен)") { editing.toggle() }
                }
                Spacer()
                if case let .ok(models) = services.checks[provider], !models.isEmpty {
                    Picker("Модель", selection: Binding(
                        get: { settings.aiServices.model(provider) ?? models[0] },
                        set: { settings.aiServices.models[provider.rawValue] = $0 }
                    )) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 260)
                } else if let model = settings.aiServices.model(provider) {
                    Text(model).font(.caption).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        if services.checking.contains(provider) {
            ProgressView().controlSize(.small)
        } else if let check = services.checks[provider] {
            Label(check.text, systemImage: check.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.isOK ? .green : .orange)
                .font(.caption)
        } else if services.hasKey.contains(provider) {
            Text("ключ сохранён").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let key = keyText
        keyText = ""
        Task {
            do {
                try await services.saveKey(key, for: provider)
                error = nil
                editing = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension APICheck {
    var isOK: Bool { if case .ok = self { true } else { false } }
}
