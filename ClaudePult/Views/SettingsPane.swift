import SwiftUI

/// A page of Settings, listed in the sidebar like System Settings (design variant A, 2026-11-02): the app's own
/// areas, then «Сервисы AI» with a page per AI.
enum SettingsPane: Hashable, Sendable {
    case general, modes, modules, appearance, menuBar
    case service(ServiceTab)

    static let areas: [SettingsPane] = [.general, .modes, .modules, .appearance, .menuBar]
    static let services: [SettingsPane] = ServiceTab.allCases.map(SettingsPane.service)

    /// The pane `settingsTab` / `servicesTab` point at (kept as before, so links into Settings still work).
    init(tab: SettingsView.Tab, service: ServiceTab) {
        switch tab {
        case .general: self = .general
        case .modes: self = .modes
        case .modules: self = .modules
        case .appearance: self = .appearance
        case .menuBar: self = .menuBar
        case .services: self = .service(service)
        }
    }

    var tab: SettingsView.Tab {
        switch self {
        case .general: .general
        case .modes: .modes
        case .modules: .modules
        case .appearance: .appearance
        case .menuBar: .menuBar
        case .service: .services
        }
    }

    var title: String {
        switch self {
        case .general: String(localized: "Основные")
        case .modes: String(localized: "Профили")
        case .modules: String(localized: "Модули")
        case .appearance: String(localized: "Внешний вид")
        case .menuBar: String(localized: "Строка меню")
        case let .service(service): service.title
        }
    }

    var subtitle: String {
        switch self {
        case .general: String(localized: "Запуск, уведомления, Telegram и обновления")
        case .modes: String(localized: "Наборы проектов, модулей и команд")
        case .modules: String(localized: "Что умеет панель и как это настроить")
        case .appearance: String(localized: "Тема, фон и размер текста панели")
        case .menuBar: String(localized: "Что показывать рядом со значком")
        case .service(.claude): String(localized: "Путь, сессии и hooks, Telegram, фоновые задачи")
        case .service(.codex): String(localized: "Агент, лимиты и ключ OpenAI")
        case .service(.gemini): String(localized: "Gemini CLI, Antigravity и ключ Google")
        case .service(.copilot), .service(.cursor): String(localized: "Агент и лимиты")
        case .service(.other): String(localized: "xAI, DeepSeek, Mistral, OpenRouter и расход по API")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .modes: "square.stack.3d.up"
        case .modules: "puzzlepiece.extension"
        case .appearance: "paintbrush"
        case .menuBar: "menubar.rectangle"
        case let .service(service): service.icon
        }
    }

    /// The icon tile's colour, as in System Settings.
    var tint: Color {
        switch self {
        case .general: .gray
        case .modes: .blue
        case .modules: .purple
        case .appearance: .pink
        case .menuBar: .teal
        case .service(.claude): .orange
        case .service(.codex): .black
        case .service(.gemini): .indigo
        case .service(.copilot): .green
        case .service(.cursor): .brown
        case .service(.other): .gray
        }
    }

    /// Words the sidebar search finds the pane by, besides its title — names of settings already shown in it.
    var keywords: [String] {
        switch self {
        case .general:
            [String(localized: "Запускать при входе в систему"), String(localized: "Уведомления"), "Telegram",
             String(localized: "Токен бота"), String(localized: "Версия"), String(localized: "Журнал"), String(localized: "Обновления")]
        case .modes:
            [String(localized: "Проекты"), String(localized: "Общие команды")]
        case .modules:
            ModuleKind.allCases.map(\.title)
        case .appearance:
            [String(localized: "Тема"), String(localized: "Фон панели"), String(localized: "Размер текста"),
             String(localized: "Ширина"), String(localized: "Плотность строк")]
        case .menuBar:
            MenuBarElement.Kind.allCases.map(\.title)
        case let .service(service):
            service.agents.map(\.title) + service.providers.map(\.title) + service.hubSources.map(\.title)
                + (service == .claude ? ["Hooks", "Telegram", String(localized: "Путь к claude")] : [])
        }
    }

    /// Whether the sidebar search `query` finds this pane.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([title] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// A pane's icon: a white symbol on a coloured rounded tile.
struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: size * 0.55, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(pane.tint.gradient))
            .accessibilityHidden(true)
    }
}

/// A row of the Settings sidebar; services carry a status dot — green when something of the service works here.
struct PaneRow: View {
    let pane: SettingsPane
    var isSetUp: Bool?

    var body: some View {
        HStack(spacing: 8) {
            PaneIcon(pane: pane)
            Text(pane.title)
            if let isSetUp {
                Spacer(minLength: 4)
                Circle()
                    .fill(isSetUp ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .help(Self.status(isSetUp))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSetUp.map(Self.status) ?? "")
    }

    static func status(_ isSetUp: Bool) -> String {
        isSetUp ? String(localized: "найден или настроен") : String(localized: "не найден и не настроен")
    }
}

/// The top of a pane: its icon, title and what's in it.
struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 12) {
            PaneIcon(pane: pane, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title).font(.title3.weight(.semibold))
                Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
