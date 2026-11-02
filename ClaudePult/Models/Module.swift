import Foundation

/// A part of ClaudePult that is installed once and shown by profiles (docs/SPEC-profiles.md §1, §3).
/// The first five are built in: a profile has them when its settings call for them. The rest are optional: installed
/// from Settings → «Модули» and added to a profile by hand (SPEC-profiles §3).
enum ModuleKind: String, Codable, CaseIterable, Sendable {
    case limits, sessions, upcoming, projects, reports
    case resources, keepAwake, quickCommands, toggles, clipboard, notes, notch, layout

    var isBuiltIn: Bool { ![.resources, .keepAwake, .quickCommands, .toggles, .clipboard, .notes, .notch, .layout].contains(self) }

    /// Still in beta testing: offered and working only with Settings → General → «Бета-версии» on (docs/RELEASE.md).
    var isBeta: Bool { self == .layout }

    /// «Остров у чёлки» lives at the top of the screen and «Раскладка» in the keyboard, not in the panel: no profile
    /// shows them (SPEC-notch §6, SPEC-layout §4).
    var isPanelBlock: Bool { ![.notch, .layout].contains(self) }

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
        case .notch: String(localized: "Остров у чёлки")
        case .layout: String(localized: "Раскладка")
        }
    }

    /// What the module does, for Settings → «Модули».
    var summary: String {
        switch self {
        case .limits: String(localized: "Сессия и неделя подписки Claude, прогноз, расход по проектам и по API.")
        case .sessions: String(localized: "Сессии Claude Code на этом Маке и фоновые задачи. Нужны hooks — «Сервисы AI» → Claude Code.")
        case .upcoming: String(localized: "Дедлайны, публикации и контент-план на 7 дней вперёд — из профилей с календарём.")
        case .projects: String(localized: "Проекты профиля: git-репозитории или папки, карточки, команды. Настраиваются в профиле.")
        case .reports: String(localized: "Команды _daily-report: отчёт, быстрая сводка, очистка сборок.")
        case .resources: String(localized: "Процессор, память, диск, сеть, батарея и самые прожорливые приложения; уведомления о нагрузке, памяти, месте и заряде.")
        case .keepAwake: String(localized: "Mac не засыпает, пока работает Claude, на время, при подключённом питании или мониторе, пока открыты выбранные приложения.")
        case .quickCommands: String(localized: "Свои кнопки: скрипт в фоне или в Терминале, ярлык из «Команд» macOS, ссылка, файл, папка или приложение.")
        case .toggles: String(localized: "Тёмная тема, значки на рабочем столе, блокировка и выключение экрана, извлечение дисков, корзина — в один клик.")
        case .clipboard: String(localized: "Последние копирования: поиск, закрепление, снова в буфер одним кликом. Пароли из менеджеров паролей не запоминаются.")
        case .notes: String(localized: "Заметки в Markdown прямо в панели: вкладки, обычные файлы .md в папке, которую откроет любой редактор.")
        case .notch: String(localized: "Чёрный остров вокруг чёлки MacBook: лимит и сессии по бокам от неё, по наведению — карточка с лимитами и тем, что делает Claude.")
        case .layout: String(localized: "Слово, набранное не в той раскладке («ghbdtn»), исправляется само («привет»), и раскладка переключается. Двойной Shift — последнее слово, ⌥⇧ — выделенный текст. Язык — в строке меню.")
        }
    }

    /// The Settings sidebar section the module sits in (SPEC-settings §2).
    var group: ModuleGroup {
        switch self {
        case .limits, .sessions: .ai
        case .upcoming, .projects, .reports, .quickCommands, .notes, .clipboard: .work
        case .resources, .keepAwake, .toggles, .layout, .notch: .mac
        }
    }

    /// One line for the module's tile in Settings → «Модули».
    var tagline: String {
        switch self {
        case .limits: String(localized: "Сессия, неделя, прогноз, другие AI")
        case .sessions: String(localized: "Claude Code, фоновые задачи, очередь")
        case .upcoming: String(localized: "Дедлайны и публикации на 7 дней")
        case .projects: String(localized: "Репозитории и папки, PR, команды")
        case .reports: String(localized: "Отчёт, сводка, очистка сборок")
        case .resources: String(localized: "Процессор, память, диск, батарея")
        case .keepAwake: String(localized: "Mac не засыпает по правилам")
        case .quickCommands: String(localized: "Скрипты, ярлыки, ссылки, файлы")
        case .toggles: String(localized: "Тема, экран, диски, корзина")
        case .clipboard: String(localized: "Последние копирования, поиск")
        case .notes: String(localized: "Markdown прямо в панели")
        case .notch: String(localized: "Лимит и сессии у чёлки")
        case .layout: String(localized: "ghbdtn → привет, сам")
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
        case .notch: "laptopcomputer"
        case .layout: "keyboard"
        }
    }
}

/// The sections of modules in the Settings sidebar and the «Модули» tiles (SPEC-settings §2).
enum ModuleGroup: String, CaseIterable, Sendable {
    case ai, work, mac

    var title: String {
        switch self {
        case .ai: "AI"
        case .work: String(localized: "Работа")
        case .mac: "Mac"
        }
    }

    /// Modules in sidebar order.
    var modules: [ModuleKind] {
        switch self {
        case .ai: [.limits, .sessions]
        case .work: [.upcoming, .projects, .reports, .quickCommands, .notes, .clipboard]
        case .mac: [.resources, .keepAwake, .toggles, .layout, .notch]
        }
    }
}

/// One module in a profile; its place in the list is its place in the panel.
struct ProfileModule: Codable, Equatable, Sendable {
    var kind: ModuleKind
    var shown: Bool
    /// The profile's own choices inside a module (SPEC-profiles §3, «в профиле»); nil everywhere = show everything,
    /// as before these existed. «Ресурсы Mac»: `ResourceMetric` raw values.
    var metrics: [String]?
    /// «Быстрые команды»: ids from the shared library.
    var commands: [String]?
    /// «Быстрые переключатели»: `QuickToggle` raw values; nil = the ones chosen in Settings → «Модули».
    var toggles: [String]?
    /// «Не спать»: the 15 min / 1 h / 2 h buttons.
    var showTimers: Bool?

    init(_ kind: ModuleKind, shown: Bool = true) {
        self.kind = kind
        self.shown = shown
    }

    /// Switches one item on or off in a «nil = all» list; back to nil once everything is on again.
    static func toggled(_ id: String, in current: [String]?, all: [String]) -> [String]? {
        var chosen = current ?? all
        if chosen.contains(id) { chosen.removeAll { $0 == id } } else { chosen.append(id) }
        let ordered = all.filter(chosen.contains)
        return ordered == all ? nil : ordered
    }

    static func includes(_ id: String, in list: [String]?) -> Bool { list?.contains(id) ?? true }
}

/// What «Ресурсы Mac» can show; a profile picks some of them.
enum ResourceMetric: String, CaseIterable, Sendable {
    case cpu, memory, gpu, disk, network, battery, processes

    var title: String {
        switch self {
        case .cpu: String(localized: "Процессор")
        case .memory: String(localized: "Память")
        case .gpu: String(localized: "Графика")
        case .disk: String(localized: "Диск")
        case .network: String(localized: "Сеть")
        case .battery: String(localized: "Батарея")
        case .processes: String(localized: "Самые прожорливые")
        }
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
            case .resources, .keepAwake, .quickCommands, .toggles, .clipboard, .notes, .notch, .layout: true
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

    func module(_ kind: ModuleKind) -> ProfileModule? { modules?.first { $0.kind == kind } }

    func shows(_ kind: ModuleKind) -> Bool { modules?.contains { $0.kind == kind && $0.shown } ?? false }
}

/// Decodes a profile's modules, skipping kinds this version doesn't know (a file from a newer ClaudePult).
struct ModuleList: Decodable {
    var modules: [ProfileModule]

    init(from decoder: Decoder) throws {
        struct Raw: Decodable {
            var kind: String?
            var shown: Bool?
            var metrics: [String]?
            var commands: [String]?
            var toggles: [String]?
            var showTimers: Bool?
        }
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
                var module = ProfileModule(kind, shown: raw.shown ?? true)
                module.metrics = raw.metrics
                module.commands = raw.commands
                module.toggles = raw.toggles
                module.showTimers = raw.showTimers
                modules.append(module)
            }
        }
        self.modules = modules
    }
}
