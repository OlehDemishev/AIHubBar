import SwiftUI

/// A page of Settings, listed in the sidebar like System Settings (SPEC-settings §2): the app's own areas, the
/// modules by section, and «Сервисы AI» with a page per AI.
enum SettingsPane: Hashable, Sendable, RawRepresentable {
    case general, modes, modules, panel, appearance, menuBar
    case module(ModuleKind)
    case service(ServiceTab)

    static let areas: [SettingsPane] = [.general, .modes, .appearance, .modules, .panel, .menuBar]
    static let services: [SettingsPane] = ServiceTab.allCases.map(SettingsPane.service)

    /// How the page is stored (`StorageKey.settingsPage`): «general», «module.limits», «service.claude»…
    var rawValue: String {
        switch self {
        case .general: "general"
        case .modes: "modes"
        case .modules: "modules"
        case .panel: "panel"
        case .appearance: "appearance"
        case .menuBar: "menuBar"
        case let .module(kind): "module." + kind.rawValue
        case let .service(service): "service." + service.rawValue
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("module", 2): guard let kind = ModuleKind(rawValue: parts[1]) else { return nil }; self = .module(kind)
        case ("service", 2): guard let service = ServiceTab(rawValue: parts[1]) else { return nil }; self = .service(service)
        default:
            guard let area = Self.areas.first(where: { $0.rawValue == rawValue }) else { return nil }
            self = area
        }
    }

    var isService: Bool { if case .service = self { true } else { false } }

    var title: String {
        switch self {
        case .general: String(localized: "Основные")
        case .modes: String(localized: "Профили")
        case .modules: String(localized: "Модули")
        case .panel: String(localized: "Панель")
        case .appearance: String(localized: "Внешний вид")
        case .menuBar: String(localized: "Строка меню")
        case let .module(kind): kind.title
        case let .service(service): service.title
        }
    }

    var subtitle: String {
        switch self {
        case .general: String(localized: "Запуск, уведомления, Telegram и обновления")
        case .modes: String(localized: "Наборы проектов, модулей и команд")
        case .modules: String(localized: "Что включено — плитками и готовыми наборами")
        case .panel: String(localized: "Какие блоки показывать и в каком порядке")
        case .appearance: String(localized: "Тема, фон и размер текста панели")
        case .menuBar: String(localized: "Что показывать рядом со значком")
        case let .module(kind): kind.summary
        case .service(.claude): String(localized: "Путь, свои промпты, CLAUDE.md и MCP")
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
        case .modules: "square.grid.2x2"
        case .panel: "rectangle.stack"
        case .appearance: "paintbrush"
        case .menuBar: "menubar.rectangle"
        case let .module(kind): kind.symbol
        case let .service(service): service.icon
        }
    }

    /// The icon tile's colour, as in System Settings; modules by their section.
    var tint: Color {
        switch self {
        case .general, .modes, .modules, .panel, .appearance, .menuBar: .gray
        case let .module(kind): kind.group.tint
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
             String(localized: "Токен бота"), String(localized: "Версия"), String(localized: "Журнал"), String(localized: "Обновления"),
             String(localized: "Обратная связь"), String(localized: "Сообщить о проблеме…"), String(localized: "Предложить идею…"),
             String(localized: "Бета-версии")]
        case .modes:
            [String(localized: "Проекты"), String(localized: "Общие команды")]
        case .modules:
            [String(localized: "Только AI"), String(localized: "Только раскладка"), String(localized: "Утилиты Mac")]
        case .panel:
            [String(localized: "Порядок"), String(localized: "Блоки")]
        case let .module(kind):
            kind.keywords + NotificationKind.of(kind).map(\.title)
        case .appearance:
            [String(localized: "Тема"), String(localized: "Фон панели"), String(localized: "Размер текста"),
             String(localized: "Ширина"), String(localized: "Плотность строк")]
        case .menuBar:
            MenuBarElement.Kind.allCases.map(\.title)
        case let .service(service):
            service.agents.map(\.title) + service.providers.map(\.title) + service.hubSources.map(\.title)
                + (service == .claude ? [String(localized: "Путь к claude"), String(localized: "Свои промпты")] : [])
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

/// A row of the Settings sidebar; services carry a status dot — green when something of the service works here; a
/// module switched off is pale.
struct PaneRow: View {
    let pane: SettingsPane
    var isSetUp: Bool?
    var isOff = false

    var body: some View {
        HStack(spacing: 9) {
            PaneIcon(pane: pane, size: 22)
            Text(pane.title)
                .font(.system(size: 13.5))
            if let isSetUp {
                Spacer(minLength: 4)
                Circle()
                    .fill(isSetUp ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .help(Self.status(isSetUp))
            }
        }
        .padding(.vertical, 1)
        .opacity(isOff ? 0.45 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOff ? String(localized: "выключен") : isSetUp.map(Self.status) ?? "")
    }

    static func status(_ isSetUp: Bool) -> String {
        isSetUp ? String(localized: "найден или настроен") : String(localized: "не найден и не настроен")
    }
}

/// The top of a pane: a big icon, its title and what's in it; a module's main switch on the right (SPEC-settings §2).
struct PaneHeader: View {
    let pane: SettingsPane
    var isOn: Binding<Bool>?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PaneIcon(pane: pane, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title).font(.system(size: 20, weight: .semibold))
                Text(pane.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let isOn {
                Toggle(String(localized: "Включён"), isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .labelsHidden()
                    .help(isOn.wrappedValue ? String(localized: "Выключить модуль: перестанет работать, место в профилях сохранится") : String(localized: "Включить модуль"))
            }
        }
    }
}

extension ModuleGroup {
    var tint: Color {
        switch self {
        case .ai: .purple
        case .work: .teal
        case .mac: .orange
        }
    }
}
