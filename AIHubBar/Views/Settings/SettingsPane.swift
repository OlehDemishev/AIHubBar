import SwiftUI

/// A page of Settings (SPEC-settings §2). The sidebar lists a few: the app's own areas, «Что показывать», one row for
/// «Сервисы AI» and «Остров у чёлки». A module's page and «Строка меню» open from «Что показывать» (`parent`).
enum SettingsPane: Hashable, Sendable, RawRepresentable {
    case general, modes, show, appearance, menuBar, shortcuts
    case module(ModuleKind)
    case service(ServiceTab)

    /// The app's own pages, in sidebar order; «Строка меню» is reached from «Что показывать».
    static let areas: [SettingsPane] = [.general, .show, .appearance, .menuBar, .modes, .shortcuts]
    static let services: [SettingsPane] = ServiceTab.allCases.map(SettingsPane.service)

    /// How the page is stored (`StorageKey.settingsPage`): «general», «module.limits», «service.claude»…
    var rawValue: String {
        switch self {
        case .general: "general"
        case .modes: "modes"
        case .show: "show"
        case .appearance: "appearance"
        case .menuBar: "menuBar"
        case .shortcuts: "shortcuts"
        case let .module(kind): "module." + kind.rawValue
        case let .service(service): "service." + service.rawValue
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("module", 2): guard let kind = ModuleKind(rawValue: parts[1]) else { return nil }; self = .module(kind)
        case ("service", 2): guard let service = ServiceTab(rawValue: parts[1]) else { return nil }; self = .service(service)
        // «Модули» and «Панель» became one page on 2026-11-10: links saved before open it.
        case ("modules", 1), ("panel", 1): self = .show
        default:
            guard let area = Self.areas.first(where: { $0.rawValue == rawValue }) else { return nil }
            self = area
        }
    }

    var isService: Bool { if case .service = self { true } else { false } }

    /// The page this one opens from and goes back to; nil for a page with a row of its own in the sidebar.
    var parent: SettingsPane? {
        switch self {
        case .menuBar: .show
        case let .module(kind): kind == .notch ? nil : .show
        default: nil
        }
    }

    var title: String {
        switch self {
        case .general: String(localized: "Основные")
        case .modes: String(localized: "Профили")
        case .show: String(localized: "Что показывать")
        case .appearance: String(localized: "Внешний вид")
        case .menuBar: String(localized: "Строка меню")
        case .shortcuts: String(localized: "Клавиши")
        case let .module(kind): kind.title
        case let .service(service): service.title
        }
    }

    var subtitle: String {
        switch self {
        case .general: String(localized: "Запуск, уведомления, Telegram и обновления")
        case .modes: String(localized: "Наборы проектов, модулей и команд")
        case .show: String(localized: "Блоки панели, строка меню и их порядок")
        case .appearance: String(localized: "Тема, фон и размер текста панели")
        case .menuBar: String(localized: "Что показывать рядом со значком")
        case .shortcuts: String(localized: "Все сочетания клавиш в одном месте")
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
        case .show: "rectangle.stack"
        case .appearance: "paintbrush"
        case .menuBar: "menubar.rectangle"
        case .shortcuts: "keyboard"
        case let .module(kind): kind.symbol
        case let .service(service): service.icon
        }
    }

    /// The icon tile's colour, as in System Settings; modules by their section.
    var tint: Color {
        switch self {
        case .general, .modes, .show, .appearance, .menuBar, .shortcuts: .gray
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
            [String(localized: "Запускать при входе в систему"), String(localized: "Язык интерфейса"), String(localized: "Уведомления"),
             "Telegram", String(localized: "Экспорт настроек…"), String(localized: "Импорт…"), String(localized: "Версия"),
             String(localized: "Журнал"), String(localized: "Обновления"),
             String(localized: "Обратная связь"), String(localized: "Сообщить о проблеме…"), String(localized: "Предложить идею…"),
             String(localized: "Бета-версии")]
        case .modes:
            [String(localized: "Проекты"), String(localized: "Общие команды")]
        case .show:
            [String(localized: "Только AI"), String(localized: "Только раскладка"), String(localized: "Утилиты Mac"),
             String(localized: "Порядок"), String(localized: "Блоки"), String(localized: "Модули"), String(localized: "Панель")]
        case let .module(kind):
            kind.keywords + NotificationKind.of(kind).map(\.title)
        case .appearance:
            [String(localized: "Тема"), String(localized: "Фон панели"), String(localized: "Размер текста"),
             String(localized: "Ширина"), String(localized: "Плотность строк")]
        case .menuBar:
            MenuBarElement.Kind.allCases.map(\.title)
        case .shortcuts:
            [String(localized: "Сочетание клавиш"), String(localized: "Открывать поиск с клавиатуры"), String(localized: "Быстрый запрос")]
        case let .service(service):
            service.agents.map(\.title) + service.providers.map(\.title) + service.hubSources.map(\.title)
                + (service == .claude ? [String(localized: "Путь к claude"), String(localized: "Свои промпты"),
                                         String(localized: "Другие аккаунты Claude")] : [])
        }
    }

    /// Whether the sidebar search `query` finds this pane.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([title, subtitle] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// A pane's icon: a white symbol on a coloured rounded tile.
struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 20

    var body: some View {
        IconTile(symbol: pane.symbol, tint: pane.tint, size: size)
    }
}

/// A row of the Settings sidebar; services carry a status dot — green when something of the service works here; a
/// module switched off is pale.
struct PaneRow: View {
    let pane: SettingsPane
    var isSetUp: Bool?
    var isOff = false
    /// Pale without being a module that is off: «Профили» while there is one profile.
    var isQuiet = false
    /// The one row for all services carries their common name and icon.
    var allServices = false

    var body: some View {
        HStack(spacing: 9) {
            if allServices {
                IconTile(symbol: "sparkles", tint: .purple, size: 22)
            } else {
                PaneIcon(pane: pane, size: 22)
            }
            Text(allServices ? String(localized: "Сервисы AI") : pane.title)
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
        .opacity(isOff || isQuiet ? 0.45 : 1)
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
    /// Back to the page this one opened from.
    var back: (() -> Void)?

    var body: some View {
        // From the top and with room for two lines: the page below stays in place from one page to the next.
        HStack(alignment: .top, spacing: 14) {
            if let back, let parent = pane.parent {
                Button(action: back) {
                    Label(String(localized: "Назад: \(parent.title)"), systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(height: 46)
                .help(String(localized: "Назад: \(parent.title)"))
                .keyboardShortcut("[", modifiers: .command)
            }
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
                    .frame(height: 46)
                    .help(isOn.wrappedValue ? String(localized: "Выключить модуль: перестанет работать, место в профилях сохранится") : String(localized: "Включить модуль"))
            }
        }
        .frame(minHeight: 56, alignment: .top)
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
