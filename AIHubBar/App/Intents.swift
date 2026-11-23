import AppIntents
import Foundation

/// What the Shortcuts actions reach inside the running app (set once at launch).
@MainActor
enum IntentBridge {
    static weak var settings: AppSettings?
    static weak var quickTools: QuickToolsController?
    static weak var sessions: SessionStore?
    /// «Не спать» from Shortcuts: the new state in words, nil while the module is off.
    static var keepAwake: (@MainActor (KeepAwakeChoice) -> String?)?
    static var projects: (@MainActor () -> [Project])?
    /// Sends a task to Claude Code in the background; the answer is what the project's row would say about it.
    static var startTask: (@MainActor (String, Project) async -> String)?
}

/// One thing by its name, any case. Part of a name is enough only when it means one thing: «clean» must not pick the
/// first of two.
enum IntentMatch {
    static func pick<Item>(_ name: String, in items: [Item], title: (Item) -> String) -> Item? {
        if let exact = items.first(where: { title($0).localizedCaseInsensitiveCompare(name) == .orderedSame }) { return exact }
        let partial = items.filter { title($0).localizedCaseInsensitiveContains(name) }
        return partial.count == 1 ? partial.first : nil
    }
}

/// «Сессия 24 %, сброс через 1 ч 10 мин; неделя 84 %, сброс Пн 10:00» from `usage.json`, the file the limits block
/// writes — so the action answers even before the app has fetched anything this launch.
enum LimitsSummary {
    static func text(fromUsageFile data: Data?, now: Date = .now) -> String {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(localized: "Лимиты ещё не загружены — откройте панель AI Hub Bar")
        }
        func part(_ key: String, _ title: String) -> String? {
            guard let window = object[key] as? [String: Any], let value = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let usage = UsageWindow(key: key, title: title, utilization: value,
                                    resetsAt: (window["resets_at"] as? String).flatMap(ISODate.parse))
            return [title + " " + UsageText.percent(value), UsageText.resetText(usage, now: now, short: true)]
                .compactMap { $0 }.joined(separator: ", ")
        }
        let parts = [part("five_hour", String(localized: "Сессия")), part("seven_day", String(localized: "неделя"))].compactMap { $0 }
        return parts.isEmpty ? String(localized: "Лимиты ещё не загружены — откройте панель AI Hub Bar") : parts.joined(separator: "; ")
    }
}

struct ShowLimitsIntent: AppIntent {
    static let title: LocalizedStringResource = "Лимиты Claude"
    static let description = IntentDescription("Сколько использовано лимита сессии и недели и когда сброс.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let file = SessionFiles.supportDirectory.appending(path: "usage.json")
        let text = LimitsSummary.text(fromUsageFile: try? Data(contentsOf: file))
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct RunQuickCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Быстрая команда AI Hub Bar"
    static let description = IntentDescription("Запускает кнопку из «Быстрых команд» по названию.")

    @Parameter(title: "Название")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let commands = IntentBridge.settings?.quickCommands ?? []
        guard let command = Self.command(named: name, in: commands), let tools = IntentBridge.quickTools else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Нет быстрой команды «\(name)»")))
        }
        // A command marked «Спрашивать перед запуском» asks here too, like from a hot key.
        guard tools.runFromHotKey(command) else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Отменено")))
        }
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Запущено: \(command.title)")))
    }
}

extension RunQuickCommandIntent {
    /// The command with this title, any case. Part of a name is enough only when it means one command: «clean»
    /// must not pick the first of two.
    static func command(named name: String, in commands: [QuickCommand]) -> QuickCommand? {
        IntentMatch.pick(name, in: commands, title: \.title)
    }
}

struct OpenSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Поиск AI Hub Bar"
    static let description = IntentDescription("Окно поиска по проектам, сессиям и командам.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickSearch.show()
        return .result()
    }
}

enum KeepAwakeChoice: String, AppEnum {
    case hour, untilOff, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Не спать"
    static let caseDisplayRepresentations: [KeepAwakeChoice: DisplayRepresentation] = [
        .hour: "На час", .untilOff: "До выключения", .off: "Выключить",
    ]
}

struct KeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Не спать"
    static let description = IntentDescription("Держит Mac включённым час или до выключения, либо отпускает его.")

    @Parameter(title: "Режим")
    var mode: KeepAwakeChoice

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = IntentBridge.keepAwake?(mode) ?? String(localized: "Модуль «Не спать» выключен")
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct WaitingSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Кто ждёт ответа"
    static let description = IntentDescription("Сессии агентов, которые ждут вашего ответа или разрешения.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let waiting = (IntentBridge.sessions?.items ?? []).filter { $0.state == .waiting }.map(\.session)
        let text = Self.text(waiting)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }

    /// «Ambo: какой порт?; Site: Нужно разрешение: Bash».
    static func text(_ waiting: [Session]) -> String {
        guard !waiting.isEmpty else { return String(localized: "Никто не ждёт ответа") }
        return waiting.map { [$0.displayProject, $0.message ?? $0.task].compactMap { $0 }.joined(separator: ": ") }.joined(separator: "; ")
    }
}

struct StartTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Задача Claude в фоне"
    static let description = IntentDescription("Отправляет задачу Claude Code в фон в проекте с этим названием.")

    @Parameter(title: "Задача")
    var task: String

    @Parameter(title: "Проект")
    var project: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result(dialog: IntentDialog(stringLiteral: String(localized: "Задача пустая"))) }
        guard let start = IntentBridge.startTask,
              let found = IntentMatch.pick(project, in: IntentBridge.projects?() ?? [], title: \.name) else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Нет проекта «\(project)»")))
        }
        return .result(dialog: IntentDialog(stringLiteral: await start(text, found)))
    }
}

struct AIHubBarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowLimitsIntent(), phrases: ["Лимиты в \(.applicationName)", "Limits in \(.applicationName)"],
                    shortTitle: "Лимиты Claude", systemImageName: "gauge.with.dots.needle.33percent")
        AppShortcut(intent: OpenSearchIntent(), phrases: ["Поиск в \(.applicationName)", "Search \(.applicationName)"],
                    shortTitle: "Поиск", systemImageName: "magnifyingglass")
        AppShortcut(intent: WaitingSessionsIntent(), phrases: ["Кто ждёт в \(.applicationName)", "Who is waiting in \(.applicationName)"],
                    shortTitle: "Кто ждёт ответа", systemImageName: "hand.raised")
    }
}
