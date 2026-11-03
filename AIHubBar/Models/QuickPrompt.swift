import Carbon.HIToolbox
import Foundation

/// «Быстрый запрос»'s hot key (docs/specs/SPEC-quick-prompt.md §4). None of them is a key of the search or the island.
enum QuickPromptHotKey: String, CaseIterable, Codable, Sendable {
    case off, controlOptionP, controlOptionA, controlShiftSpace

    var title: String {
        switch self {
        case .off: String(localized: "Выключено")
        case .controlOptionP: "⌃⌥P"
        case .controlOptionA: "⌃⌥A"
        case .controlShiftSpace: String(localized: "⌃⇧Пробел")
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionP: UInt32(kVK_ANSI_P)
        case .controlOptionA: UInt32(kVK_ANSI_A)
        case .controlShiftSpace: UInt32(kVK_Space)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionP, .controlOptionA: UInt32(controlKey | optionKey)
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        }
    }
}

/// The module's settings and what the window remembers between requests.
struct QuickPromptSettings: Codable, Equatable, Sendable {
    var hotKey: QuickPromptHotKey = .controlOptionP
    /// The project of the last request (its path).
    var lastProject: String?
    /// Where the last request went; nil — the launch mode from Settings, else the background.
    var lastMode: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = QuickPromptSettings()
        hotKey = (try? c.decodeIfPresent(QuickPromptHotKey.self, forKey: .hotKey)) ?? defaults.hotKey
        lastProject = try? c.decodeIfPresent(String.self, forKey: .lastProject)
        lastMode = try? c.decodeIfPresent(String.self, forKey: .lastMode)
    }
}

/// What was in front when the hot key was pressed: read before AI Hub Bar comes forward.
struct FrontContext: Equatable, Sendable {
    var bundleID: String?
    /// The front window's document (`AXDocument`), a path.
    var documentPath: String?
    var windowTitle: String?
}

/// The window's choices (SPEC-quick-prompt §2–3), apart from the window.
enum QuickPrompt {
    struct Candidate: Equatable, Sendable {
        var name: String
        var path: String
        var lastActivity: Date?
    }

    /// The project chosen when the window opens: the one in front, the last one, the most recently active one.
    static func defaultProject(_ projects: [Candidate], front: FrontContext?, last: String?) -> String? {
        if let front, let path = frontProject(projects, front: front) { return path }
        if let last, projects.contains(where: { $0.path == last }) { return last }
        let active = projects.compactMap { project in project.lastActivity.map { (project.path, $0) } }.max { $0.1 < $1.1 }
        return active?.0 ?? projects.first?.path
    }

    /// The front window's project: its document inside a project folder (the deepest folder wins, so a worktree
    /// inside a project is not taken for the project), else a project name in its title as a whole word (the
    /// longest name wins: «Cantero-l5» before «Cantero»).
    static func frontProject(_ projects: [Candidate], front: FrontContext) -> String? {
        if let document = front.documentPath.map(standardized), !document.isEmpty {
            let containing = projects.filter { document == standardized($0.path) || document.hasPrefix(standardized($0.path) + "/") }
            if let deepest = containing.max(by: { $0.path.count < $1.path.count }) { return deepest.path }
        }
        guard let title = front.windowTitle, !title.isEmpty else { return nil }
        let named = projects.filter { !$0.name.isEmpty && containsWord($0.name, in: title) }
        return named.max { $0.name.count < $1.name.count }?.path
    }

    /// Claude Code first, then the other installed agents in their usual order.
    static func agents(installed: Set<AgentKind>) -> [AgentKind] {
        AgentKind.allCases.filter { $0 == .claudeCode || installed.contains($0) }
    }

    /// Only Claude Code runs in the background (SPEC-modes §11); the others open in Terminal.
    static func modes(for agent: AgentKind) -> [LaunchMode] {
        agent == .claudeCode ? [.background, .terminal] : [.terminal]
    }

    /// The mode the window starts with for an agent: the last one if the agent can, else Settings', else the background.
    static func mode(for agent: AgentKind, last: LaunchMode?, preferred: LaunchMode?) -> LaunchMode {
        let allowed = modes(for: agent)
        return [last, preferred].compactMap { $0 }.first(where: allowed.contains) ?? allowed[0]
    }

    static func canSend(_ text: String, project: String?) -> Bool {
        project != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func standardized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return url.hasSuffix("/") && url.count > 1 ? String(url.dropLast()) : url
    }

    /// `name` in `text` with no letter, digit, «-» or «_» right before or after it, ignoring case.
    static func containsWord(_ name: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: name, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !isNamePart(before), !isNamePart(after) { return true }
            searchRange = text.index(after: range.lowerBound)..<text.endIndex
        }
        return false
    }

    private static func isNamePart(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "-" || character == "_"
    }
}
