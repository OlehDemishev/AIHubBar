import Foundation

/// A part of ClaudePult that is installed once and shown by profiles (docs/SPEC-profiles.md §1, §3).
/// Stage 1 knows the modules that already exist; Ресурсы Mac, Не спать and the quick tools come with their stages.
enum ModuleKind: String, Codable, CaseIterable, Sendable {
    case limits, sessions, upcoming, projects, reports

    var title: String {
        switch self {
        case .limits: String(localized: "Лимиты AI")
        case .sessions: String(localized: "Сессии агентов")
        case .upcoming: String(localized: "Ближайшее")
        case .projects: String(localized: "Проекты")
        case .reports: String(localized: "Отчёты _daily-report")
        }
    }

    var symbol: String {
        switch self {
        case .limits: "gauge.with.dots.needle.33percent"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .upcoming: "calendar"
        case .projects: "folder"
        case .reports: "doc.text.magnifyingglass"
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
    /// The modules this profile has, built from its blocks (SPEC-profiles §7). Until stage 2 the blocks decide
    /// what the panel shows, so the list follows them: kinds keep the place they have, new ones are added in panel
    /// order, kinds the blocks no longer use are dropped.
    func syncedModules(hiddenBlocks: Set<PanelBlock>) -> [ProfileModule] {
        var wanted: [ProfileModule] = [
            ProfileModule(.limits, shown: !hiddenBlocks.contains(.limits)),
            ProfileModule(.sessions, shown: !hiddenBlocks.contains(.sessions)),
        ]
        if calendar != .off { wanted.append(ProfileModule(.upcoming, shown: !hiddenBlocks.contains(.calendar))) }
        if source != .none { wanted.append(ProfileModule(.projects, shown: showProjects)) }
        if commonCommands == .dailyReport { wanted.append(ProfileModule(.reports, shown: showCommonCommands)) }

        var result = (modules ?? []).compactMap { existing in wanted.first { $0.kind == existing.kind } }
        for module in wanted where !result.contains(where: { $0.kind == module.kind }) {
            let before = wanted.prefix { $0.kind != module.kind }.map(\.kind)
            let index = (result.lastIndex { before.contains($0.kind) }).map { $0 + 1 } ?? 0
            result.insert(module, at: index)
        }
        return result
    }
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
