import Foundation

/// A part of ClaudePult that is installed once and shown by profiles (docs/SPEC-profiles.md §1, §3).
/// The first five are built in: a profile has them when its settings call for them. The rest are optional: installed
/// from Settings → «Модули» and added to a profile by hand (SPEC-profiles §3).
enum ModuleKind: String, Codable, CaseIterable, Sendable {
    case limits, sessions, upcoming, projects, reports
    case resources, keepAwake, quickCommands, toggles, clipboard, notes

    var isBuiltIn: Bool { ![.resources, .keepAwake, .quickCommands, .toggles, .clipboard, .notes].contains(self) }

    var title: String {
        switch self {
        case .limits: String(localized: "Лимиты AI")
        case .sessions: String(localized: "Сессии агентов")
        case .upcoming: String(localized: "Ближайшее")
        case .projects: String(localized: "Проекты")
        case .reports: String(localized: "Отчёты _daily-report")
        case .resources: String(localized: "Ресурсы Mac")
        case .keepAwake: String(localized: "Не спать")
        case .quickCommands: String(localized: "Быстрые команды")
        case .toggles: String(localized: "Быстрые переключатели")
        case .clipboard: String(localized: "История буфера")
        case .notes: String(localized: "Заметки")
        }
    }

    /// What the module does, for Settings → «Модули».
    var summary: String {
        switch self {
        case .limits: String(localized: "Сессия и неделя подписки Claude, прогноз, расход по проектам и по API.")
        case .sessions: String(localized: "Сессии Claude Code на этом Маке и фоновые задачи. Нужны hooks — вкладка «Claude Code».")
        case .upcoming: String(localized: "Дедлайны, публикации и контент-план на 7 дней вперёд — из профилей с календарём.")
        case .projects: String(localized: "Проекты профиля: git-репозитории или папки, карточки, команды. Настраиваются в профиле.")
        case .reports: String(localized: "Команды _daily-report: отчёт, быстрая сводка, очистка сборок.")
        case .resources: String(localized: "Процессор, память, диск, сеть, батарея и самые прожорливые приложения; уведомления о нагрузке, памяти, месте и заряде.")
        case .keepAwake: String(localized: "Mac не засыпает, пока работает Claude, на время, при подключённом питании или мониторе, пока открыты выбранные приложения.")
        case .quickCommands: String(localized: "Свои кнопки: скрипт в фоне или в Терминале, ярлык из «Команд» macOS, ссылка, файл, папка или приложение.")
        case .toggles: String(localized: "Тёмная тема, значки на рабочем столе, блокировка и выключение экрана, извлечение дисков, корзина — в один клик.")
        case .clipboard: String(localized: "Последние копирования: поиск, закрепление, снова в буфер одним кликом. Пароли из менеджеров паролей не запоминаются.")
        case .notes: String(localized: "Заметки в Markdown прямо в панели: вкладки, обычные файлы .md в папке, которую откроет любой редактор.")
        }
    }

    var symbol: String {
        switch self {
        case .limits: "gauge.with.dots.needle.33percent"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .upcoming: "calendar"
        case .projects: "folder"
        case .reports: "doc.text.magnifyingglass"
        case .resources: "cpu"
        case .keepAwake: "cup.and.saucer"
        case .quickCommands: "bolt.square"
        case .toggles: "switch.2"
        case .clipboard: "doc.on.clipboard"
        case .notes: "note.text"
        }
    }
}

/// One module in a profile; its place in the list is its place in the panel.
struct ProfileModule: Codable, Equatable, Sendable {
    var kind: ModuleKind
    var shown: Bool

    init(_ kind: ModuleKind, shown: Bool = true) {
        self.kind = kind
        self.shown = shown
    }
}

extension Mode {
    /// The modules this profile has (SPEC-profiles §1). Which ones it can have follows its settings: limits and
    /// sessions always, «Ближайшее» with the calendar on, «Проекты» with a source, «Отчёты» with `_daily-report`.
    /// Which of them the panel shows, and in what order, is the profile's own choice; a module that becomes possible
    /// goes in its panel place, shown. Files from before profiles (no list) take visibility from the old blocks.
    func normalizedModules(hiddenBlocks: Set<PanelBlock>) -> [ProfileModule] {
        var possible: [ModuleKind] = [.limits, .sessions]
        if calendar != .off { possible.append(.upcoming) }
        if source != .none { possible.append(.projects) }
        if commonCommands == .dailyReport { possible.append(.reports) }

        func legacyShown(_ kind: ModuleKind) -> Bool {
            switch kind {
            case .limits: !hiddenBlocks.contains(.limits)
            case .sessions: !hiddenBlocks.contains(.sessions)
            case .upcoming: !hiddenBlocks.contains(.calendar)
            case .projects: showProjects
            case .reports: showCommonCommands
            case .resources, .keepAwake, .quickCommands, .toggles, .clipboard, .notes: true
            }
        }

        // Optional modules stay where the person put them; built-in ones follow the settings.
        var result = (modules ?? []).filter { possible.contains($0.kind) || !$0.kind.isBuiltIn }
        for kind in possible where !result.contains(where: { $0.kind == kind }) {
            let before = possible.prefix { $0 != kind }
            let index = (result.lastIndex { before.contains($0.kind) }).map { $0 + 1 } ?? 0
            result.insert(ProfileModule(kind, shown: modules == nil ? legacyShown(kind) : true), at: index)
        }
        return result
    }

    /// Shown modules in panel order.
    var panelModules: [ModuleKind] { (modules ?? []).filter(\.shown).map(\.kind) }

    func shows(_ kind: ModuleKind) -> Bool { modules?.contains { $0.kind == kind && $0.shown } ?? false }
}

/// Decodes a profile's modules, skipping kinds this version doesn't know (a file from a newer ClaudePult).
struct ModuleList: Decodable {
    var modules: [ProfileModule]

    init(from decoder: Decoder) throws {
        struct Raw: Decodable { var kind: String?; var shown: Bool? }
        /// Reads nothing, so it accepts any value and the container moves on.
        struct Skip: Decodable { init(from decoder: Decoder) throws {} }
        var container = try decoder.unkeyedContainer()
        var modules: [ProfileModule] = []
        while !container.isAtEnd {
            guard let raw = try? container.decode(Raw.self) else {
                _ = try container.decode(Skip.self)
                continue
            }
            if let kind = raw.kind.flatMap(ModuleKind.init(rawValue:)), !modules.contains(where: { $0.kind == kind }) {
                modules.append(ProfileModule(kind, shown: raw.shown ?? true))
            }
        }
        self.modules = modules
    }
}
