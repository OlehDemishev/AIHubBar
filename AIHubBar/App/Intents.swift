import AppIntents
import Foundation

/// What the Shortcuts actions reach inside the running app (set once at launch).
@MainActor
enum IntentBridge {
    static weak var settings: AppSettings?
    static weak var quickTools: QuickToolsController?
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
        if let exact = commands.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return exact }
        let partial = commands.filter { $0.title.localizedCaseInsensitiveContains(name) }
        return partial.count == 1 ? partial.first : nil
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

struct AIHubBarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowLimitsIntent(), phrases: ["Лимиты в \(.applicationName)", "Limits in \(.applicationName)"],
                    shortTitle: "Лимиты Claude", systemImageName: "gauge.with.dots.needle.33percent")
        AppShortcut(intent: OpenSearchIntent(), phrases: ["Поиск в \(.applicationName)", "Search \(.applicationName)"],
                    shortTitle: "Поиск", systemImageName: "magnifyingglass")
    }
}
