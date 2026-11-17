import Foundation

/// What is added to an agent besides MCP servers: its skills, plugins and hooks (seen on disk 2026-11-17, Claude Code
/// 2.1.325 and Codex 0.166). Skills are folders with a `SKILL.md` in `~/.claude/skills`, and for Codex in `~/.codex/skills` and the shared
/// `~/.agents/skills` (both paths are in Codex's binary; on Oleh's Mac only the second exists); Claude
/// Code's plugins are listed in `~/.claude/plugins/installed_plugins.json` and switched by `enabledPlugins` in
/// `~/.claude/settings.json`; hooks are `hooks` in that file and `~/.codex/hooks.json`.
struct AgentSkill: Identifiable, Equatable, Sendable {
    var agent: AgentKind
    var name: String
    var description: String
    /// The skill's folder, where it is now (the skills folder, or the one for switched-off skills).
    var folder: String
    var isOn: Bool
    var id: String { "\(agent.rawValue):\(name)" }
}

struct AgentPlugin: Identifiable, Equatable, Sendable {
    /// `name@marketplace`, the key in both files.
    var key: String
    var version: String
    var isOn: Bool
    var id: String { key }
    var name: String { key.split(separator: "@").first.map(String.init) ?? key }
    var marketplace: String { key.split(separator: "@").dropFirst().first.map(String.init) ?? "" }
}

struct AgentHook: Identifiable, Equatable, Sendable {
    var agent: AgentKind
    var event: String
    var command: String
    /// AI Hub Bar's own entry (session tracking).
    var isOurs: Bool
    var id: String { "\(agent.rawValue):\(event):\(command)" }
}

enum AgentExtras {
    /// A switched-off skill is moved here whole and moved back as it was: nothing in it is edited.
    static let offSuffix = ".disabled"

    /// Where an agent looks for the person's skills, in the order they are listed.
    static func skillsFolders(_ agent: AgentKind, home: String) -> [String] {
        switch agent {
        case .claudeCode: [home + "/.claude/skills"]
        case .codex: [home + "/.codex/skills", home + "/.agents/skills"]
        default: []
        }
    }

    static func skills(home: String = NSHomeDirectory()) -> [AgentSkill] {
        var found: [AgentSkill] = []
        for agent in [AgentKind.claudeCode, .codex] {
            for folder in skillsFolders(agent, home: home) {
                for (root, isOn) in [(folder, true), (folder + offSuffix, false)] {
                    let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
                    for name in names where !name.hasPrefix(".") {
                        let path = root + "/" + name
                        guard let text = try? String(contentsOfFile: path + "/SKILL.md", encoding: .utf8) else { continue }
                        let meta = frontmatter(text)
                        let skill = AgentSkill(agent: agent, name: meta["name"] ?? name, description: meta["description"] ?? "", folder: path, isOn: isOn)
                        // The same skill in both of Codex's folders is listed once: the first folder wins.
                        if !found.contains(where: { $0.id == skill.id }) { found.append(skill) }
                    }
                }
            }
        }
        return found
    }

    /// `key: value` lines between the first two `---` lines; quotes around a value are dropped.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            values[String(line[..<colon])] = value
        }
        return values
    }

    /// Where the skill's folder goes when it is switched: out of the folder it is in to the one beside it, or back.
    /// Nil when it is already there or a folder of that name is in the way.
    static func destination(_ skill: AgentSkill, on: Bool) -> String? {
        guard skill.isOn != on else { return nil }
        let root = (skill.folder as NSString).deletingLastPathComponent
        guard on ? root.hasSuffix(offSuffix) : true else { return nil }
        let target = (on ? String(root.dropLast(offSuffix.count)) : root + offSuffix) + "/" + (skill.folder as NSString).lastPathComponent
        return FileManager.default.fileExists(atPath: target) ? nil : target
    }

    static func move(_ skill: AgentSkill, on: Bool) throws {
        guard let target = destination(skill, on: on) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: skill.folder, toPath: target)
    }

    /// Installed plugins; one that `enabledPlugins` does not name is on, as Claude Code takes it.
    static func plugins(installed: [String: Any]?, settings: [String: Any]?) -> [AgentPlugin] {
        let enabled = settings?["enabledPlugins"] as? [String: Any] ?? [:]
        let plugins = installed?["plugins"] as? [String: Any] ?? [:]
        return plugins.keys.sorted().map { key in
            let entry = (plugins[key] as? [[String: Any]])?.first
            return AgentPlugin(key: key, version: entry?["version"] as? String ?? "", isOn: enabled[key] as? Bool ?? true)
        }
    }

    static func settings(_ settings: [String: Any], plugin key: String, on: Bool) -> [String: Any] {
        var changed = settings
        var enabled = changed["enabledPlugins"] as? [String: Any] ?? [:]
        enabled[key] = on
        changed["enabledPlugins"] = enabled
        return changed
    }

    /// Command hooks of a `hooks` object (event → groups → `hooks` → `command`), Claude's and Codex's shape alike.
    static func hooks(_ object: [String: Any]?, agent: AgentKind) -> [AgentHook] {
        let events = (object?["hooks"] as? [String: Any]) ?? [:]
        return events.keys.sorted().flatMap { event -> [AgentHook] in
            (events[event] as? [[String: Any]] ?? []).flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).compactMap { hook in
                    (hook["command"] as? String).map {
                        AgentHook(agent: agent, event: event, command: $0, isOurs: $0.contains(HookInstaller.marker))
                    }
                }
            }
        }
    }
}
