import Foundation

/// What a new Mac needs before ClaudePult is useful (SPEC-modes §9.8, onboarding): one row per check, shown on the
/// assistant's first screen and in «Помощь». Built from plain values so it can be tested and printed by the CLI.
struct ReadinessItem: Equatable, Identifiable, Sendable {
    enum ID: String, Sendable { case service, hooks, notifications, loginItem }

    enum State: Equatable, Sendable {
        case done
        /// Something the person should do.
        case todo
        /// Fine to leave as it is.
        case optional
    }

    enum Action: Equatable, Sendable {
        case openServices, installHooks, updateHooks, allowNotifications, openNotificationSettings, enableLoginItem, openLoginItems

        var title: String {
            switch self {
            case .openServices: String(localized: "Открыть «Сервисы AI»")
            case .installHooks: String(localized: "Установить hooks")
            case .updateHooks: String(localized: "Обновить hooks")
            case .allowNotifications: String(localized: "Разрешить")
            case .openNotificationSettings, .openLoginItems: String(localized: "Открыть Системные настройки")
            case .enableLoginItem: String(localized: "Включить")
            }
        }
    }

    var id: ID
    var title: String
    var detail: String
    var state: State
    var action: Action?
}

enum Readiness {
    enum Notifications: Sendable { case allowed, denied, notAsked }

    struct Input: Sendable {
        /// nil = Claude Code not found; "" = found, version unknown.
        var claudeVersion: String?
        /// Other usable services: installed agents and API keys, by title.
        var otherServices: [String]
        /// False while the first search for agents and keys is still running.
        var servicesChecked = true
        var hooks: HookStatus
        var notifications: Notifications
        var loginItem: LoginItemState
    }

    static func items(_ input: Input) -> [ReadinessItem] {
        [service(input), hooks(input), notifications(input), loginItem(input)]
    }

    /// Nothing left to do (optional rows don't count).
    static func isReady(_ items: [ReadinessItem]) -> Bool {
        !items.contains { $0.state == .todo }
    }

    private static func service(_ input: Input) -> ReadinessItem {
        let title = String(localized: "Сервис AI")
        if let version = input.claudeVersion {
            // `claude --version` prints «2.1.312 (Claude Code)».
            let number = version.replacingOccurrences(of: "(Claude Code)", with: "").trimmingCharacters(in: .whitespaces)
            let found = number.isEmpty ? "Claude Code" : "Claude Code \(number)"
            let others = input.otherServices.isEmpty ? "" : String(localized: "; ещё: ") + input.otherServices.joined(separator: ", ")
            return ReadinessItem(id: .service, title: title, detail: String(localized: "Найден \(found)") + others + ".", state: .done)
        }
        if !input.servicesChecked, input.otherServices.isEmpty {
            return ReadinessItem(id: .service, title: title, detail: String(localized: "Проверяю…"), state: .optional)
        }
        if !input.otherServices.isEmpty {
            return ReadinessItem(id: .service, title: title,
                                 detail: String(localized: "Найдено: \(input.otherServices.joined(separator: ", ")). Лимиты подписки и список сессий работают только с Claude Code."),
                                 state: .done)
        }
        return ReadinessItem(id: .service, title: title,
                             detail: String(localized: "Ничего не найдено. Установите Claude Code (claude.com/claude-code) или вставьте ключ API в Настройках → «Сервисы AI»."),
                             state: .todo, action: .openServices)
    }

    private static func hooks(_ input: Input) -> ReadinessItem {
        let title = String(localized: "Сессии Claude Code")
        guard input.claudeVersion != nil else {
            return ReadinessItem(id: .hooks, title: title, detail: String(localized: "Понадобятся, когда будет установлен Claude Code."), state: .optional)
        }
        switch input.hooks {
        case .installed:
            return ReadinessItem(id: .hooks, title: title, detail: String(localized: "Hooks установлены: сессии видны в панели."), state: .done)
        case .outdated:
            return ReadinessItem(id: .hooks, title: title, detail: String(localized: "Hooks устарели — обновите их."), state: .todo, action: .updateHooks)
        case .notInstalled:
            return ReadinessItem(id: .hooks, title: title,
                                 detail: String(localized: "Список сессий и «Claude ждёт ответа» работают через hooks: ClaudePult добавит свой в ~/.claude/settings.json, сохранив резервную копию."),
                                 state: .todo, action: .installHooks)
        }
    }

    private static func notifications(_ input: Input) -> ReadinessItem {
        let title = String(localized: "Уведомления")
        switch input.notifications {
        case .allowed:
            return ReadinessItem(id: .notifications, title: title, detail: String(localized: "Разрешены."), state: .done)
        case .notAsked:
            return ReadinessItem(id: .notifications, title: title,
                                 detail: String(localized: "Лимиты, ответы Claude, готовые команды и дедлайны приходят уведомлениями."),
                                 state: .todo, action: .allowNotifications)
        case .denied:
            return ReadinessItem(id: .notifications, title: title,
                                 detail: String(localized: "Выключены в Системных настройках → Уведомления → ClaudePult."),
                                 state: .todo, action: .openNotificationSettings)
        }
    }

    private static func loginItem(_ input: Input) -> ReadinessItem {
        let title = String(localized: "Запуск при входе")
        switch input.loginItem {
        case .enabled:
            return ReadinessItem(id: .loginItem, title: title, detail: String(localized: "ClaudePult запускается сам после входа в систему."), state: .done)
        case .requiresApproval:
            return ReadinessItem(id: .loginItem, title: title, detail: String(localized: "Нужно разрешить ClaudePult в Системных настройках → Основные → Объекты входа."),
                                 state: .todo, action: .openLoginItems)
        case .disabled:
            return ReadinessItem(id: .loginItem, title: title, detail: String(localized: "По желанию: чтобы ClaudePult был в строке меню сразу после входа."),
                                 state: .optional, action: .enableLoginItem)
        }
    }
}
