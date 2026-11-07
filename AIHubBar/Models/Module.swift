import Foundation

/// A part of AI Hub Bar that is installed once and shown by profiles (docs/specs/SPEC-profiles.md §1, §3).
/// The first five are built in: a profile has them when its settings call for them. The rest are optional: installed
/// from Settings → «Модули» and added to a profile by hand (SPEC-profiles §3).
enum ModuleKind: String, Codable, CaseIterable, Sendable {
    case limits, sessions, upcoming, projects, reports
    case resources, keepAwake, quickCommands, toggles, clipboard, notes, notch, layout, quickPrompt, telegram
    // What each module is — title, symbol, section, places… — lives in its file in `Modules/` (`definition`).
}

/// The sections of modules in the Settings sidebar and the «Модули» tiles (SPEC-settings §2).
enum ModuleGroup: String, CaseIterable, Sendable {
    case ai, work, mac

    var title: String {
        switch self {
        case .ai: String(localized: "AI")
        case .work: String(localized: "Работа")
        case .mac: "Mac"
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

extension Profile {
    /// The modules this profile has (SPEC-profiles §1). Which ones it can have follows its settings: limits and
    /// sessions always, «Ближайшее» with the calendar on, «Проекты» with a source, «Отчёты» with `_daily-report`.
    /// Which of them the panel shows, and in what order, is the profile's own choice; a module that becomes possible
    /// goes in its panel place, shown. Files from before profiles (no list) take visibility from the old blocks.
    func normalizedModules(hiddenBlocks: Set<PanelBlock>) -> [ProfileModule] {
        normalizedModules(hidden: Set(hiddenBlocks.compactMap(\.module)))
    }

    /// The same with the hidden built-in modules given directly (the assistant's draft; SPEC-refactor §4).
    func normalizedModules(hidden: Set<ModuleKind>) -> [ProfileModule] {
        var possible: [ModuleKind] = [.limits, .sessions]
        // The same rule as `CalendarStore`: dates come from folder projects, so only those have the block.
        if calendar != .off, source.isFolders { possible.append(.upcoming) }
        if source != .none { possible.append(.projects) }
        if commonCommands == .dailyReport { possible.append(.reports) }

        func legacyShown(_ kind: ModuleKind) -> Bool {
            switch kind {
            case .limits: !hidden.contains(.limits)
            case .sessions: !hidden.contains(.sessions)
            case .upcoming: !hidden.contains(.upcoming)
            case .projects: showProjects
            case .reports: showCommonCommands
            case .resources, .keepAwake, .quickCommands, .toggles, .clipboard, .notes, .notch, .layout, .quickPrompt, .telegram: true
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

    /// The profile's modules as stored — normalized on every save — or worked out for a draft that has none yet.
    var moduleList: [ProfileModule] { modules ?? normalizedModules(hidden: []) }

    /// Shown modules in panel order.
    var panelModules: [ModuleKind] { (modules ?? []).filter(\.shown).map(\.kind) }

    func module(_ kind: ModuleKind) -> ProfileModule? { modules?.first { $0.kind == kind } }

    func shows(_ kind: ModuleKind) -> Bool { modules?.contains { $0.kind == kind && $0.shown } ?? false }
}

/// Decodes a profile's modules, skipping kinds this version doesn't know (a file from a newer AI Hub Bar).
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
