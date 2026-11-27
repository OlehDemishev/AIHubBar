import Foundation

/// Where the agents keep skills on this Mac, by their own documentation (checked 2026-11-26):
///
/// | Agent | For the person | In a project |
/// |---|---|---|
/// | Claude Code | `~/.claude/skills`, plugins by `~/.claude/plugins/installed_plugins.json` | `.claude/skills` |
/// | Codex | `~/.agents/skills`; `~/.codex/skills` (older, still on disk) | `.agents/skills` |
/// | Cursor | `~/.cursor/skills`, `~/.agents/skills`, and it reads `~/.claude/skills`, `~/.codex/skills` | the same four |
/// | Gemini CLI | `~/.gemini/skills`, `~/.agents/skills`, extensions in `~/.gemini/extensions` | `.gemini/skills`, `.agents/skills` |
///
/// Claude Code also keeps the skills of the person's Claude account, synced from claude.ai, two levels down:
/// `~/.claude/skills/synced/<id>/<skill>/SKILL.md`, with a `manifest.json` beside (seen on this Mac on 2026-11-27,
/// Claude Code 2.1.330: pdf, docx, skill-creator and ten more). They are listed with the scope `synced`: checked like
/// the rest, but the catalog doesn't switch them off or remove them — the account's sync would put them back.
///
/// Port of `desktop/skill-catalog/src/local.rs`. Only lists folders: nothing is opened for writing.
enum SkillAgent: String, CaseIterable, Codable, Sendable {
    case claude, codex, cursor, gemini
}

struct SkillRoots: Sendable {
    var home: URL
    /// `~/.claude`, or `CLAUDE_CONFIG_DIR`.
    var claudeDir: URL
    /// `~/.codex`, or `CODEX_HOME`.
    var codexDir: URL
    /// The folder whose subfolders are projects (`~/Projects`).
    var projectsDir: URL?

    /// Everything under one folder, as on a fresh computer: for tests and for trying things without the real ones.
    static func under(_ home: URL) -> SkillRoots {
        SkillRoots(home: home, claudeDir: home.appending(path: ".claude"), codexDir: home.appending(path: ".codex"), projectsDir: home.appending(path: "Projects"))
    }

    /// The person's own skills folders, each with the agents that read it.
    var userSkillFolders: [(URL, [SkillAgent])] {
        [
            (claudeDir.appending(path: "skills"), [.claude, .cursor]),
            (codexDir.appending(path: "skills"), [.codex, .cursor]),
            (home.appending(path: ".agents/skills"), [.codex, .cursor, .gemini]),
            (home.appending(path: ".cursor/skills"), [.cursor]),
            (home.appending(path: ".gemini/skills"), [.gemini]),
        ]
    }
}

struct SkillPlace: Equatable, Sendable {
    var agent: SkillAgent
    /// The folder as the agent sees it (it may be a link).
    var installPath: String
    /// `user`, `project`, `plugin` or `extension`.
    var scope: String
    var project: String?
    var isEnabled: Bool
}

struct FoundSkill: Equatable, Sendable {
    /// `skill` or `plugin`.
    var kind: String
    /// The real folder, links resolved: the same skill linked into several agents is one entry.
    var folder: String
    /// A plugin's name as its agent lists it (`name@marketplace`).
    var listedName: String?
    var places: [SkillPlace]
}

enum SkillDiscovery {
    /// A skill switched off in the «инструкции и MCP» window is moved to the folder beside, with this suffix.
    static let offSuffix = ".disabled"

    private static func subfolders(_ folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().filter { !$0.hasPrefix(".") }.map { folder.appending(path: $0) }.filter { url in
            var isFolder: ObjCBool = false
            // Follows a link: a skill linked from a shared folder counts.
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        }
    }

    private static func hasSkillMD(_ folder: URL) -> Bool { FileManager.default.fileExists(atPath: folder.appending(path: "SKILL.md").path) }

    /// The skills of one skills folder: every subfolder with a SKILL.md, and one level deeper for a group folder.
    private static func skills(in folder: URL) -> [URL] {
        subfolders(folder).flatMap { child in hasSkillMD(child) ? [child] : subfolders(child).filter(hasSkillMD) }
    }

    static func offFolder(_ skillsFolder: URL) -> URL {
        skillsFolder.deletingLastPathComponent().appending(path: skillsFolder.lastPathComponent + offSuffix)
    }

    /// Claude Code's installed plugins: `{"plugins": {"name@marketplace": [{"installPath": …}]}}`.
    private static func claudePlugins(_ claudeDir: URL) -> [(String, URL)] {
        guard let data = try? Data(contentsOf: claudeDir.appending(path: "plugins/installed_plugins.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        var found: [(String, URL)] = []
        for (name, value) in plugins.sorted(by: { $0.key < $1.key }) {
            // Version 1 of the file had one object, version 2 a list.
            let installs = (value as? [Any]) ?? [value]
            for install in installs {
                if let path = (install as? [String: Any])?["installPath"] as? String { found.append((name, URL(fileURLWithPath: path))) }
            }
        }
        return found
    }

    /// Every skill and plugin the agents on this Mac would load, each real folder once.
    static func discover(_ roots: SkillRoots) -> [FoundSkill] {
        var byFolder: [String: FoundSkill] = [:]
        var order: [String] = []

        func add(_ kind: String, _ url: URL, listedName: String? = nil, agents: [SkillAgent], scope: String, project: String? = nil, enabled: Bool = true) {
            let real = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: real) else { return }
            if byFolder[real] == nil {
                byFolder[real] = FoundSkill(kind: kind, folder: real, listedName: listedName, places: [])
                order.append(real)
            }
            for agent in agents {
                let place = SkillPlace(agent: agent, installPath: url.standardizedFileURL.path, scope: scope, project: project, isEnabled: enabled)
                if !(byFolder[real]?.places.contains { $0.agent == agent && $0.installPath == place.installPath } ?? true) {
                    byFolder[real]?.places.append(place)
                }
            }
        }

        func skillsFolder(_ folder: URL, _ agents: [SkillAgent], scope: String, project: String? = nil) {
            for skill in skills(in: folder) { add("skill", skill, agents: agents, scope: scope, project: project) }
            for skill in skills(in: offFolder(folder)) { add("skill", skill, agents: agents, scope: scope, project: project, enabled: false) }
        }

        for (folder, agents) in roots.userSkillFolders { skillsFolder(folder, agents, scope: "user") }
        for account in subfolders(roots.claudeDir.appending(path: "skills/synced")) {
            for skill in subfolders(account).filter(hasSkillMD) { add("skill", skill, agents: [.claude], scope: "synced") }
        }
        for (name, path) in claudePlugins(roots.claudeDir) where FileManager.default.fileExists(atPath: path.path) {
            add("plugin", path, listedName: name, agents: [.claude], scope: "plugin")
        }
        for extensionFolder in subfolders(roots.home.appending(path: ".gemini/extensions"))
        where FileManager.default.fileExists(atPath: extensionFolder.appending(path: "gemini-extension.json").path) {
            add("plugin", extensionFolder, agents: [.gemini], scope: "extension")
        }
        for project in roots.projectsDir.map(subfolders) ?? [] {
            let name = project.lastPathComponent
            skillsFolder(project.appending(path: ".claude/skills"), [.claude, .cursor], scope: "project", project: name)
            skillsFolder(project.appending(path: ".agents/skills"), [.codex, .cursor, .gemini], scope: "project", project: name)
            skillsFolder(project.appending(path: ".cursor/skills"), [.cursor], scope: "project", project: name)
            skillsFolder(project.appending(path: ".codex/skills"), [.cursor], scope: "project", project: name)
            skillsFolder(project.appending(path: ".gemini/skills"), [.gemini], scope: "project", project: name)
        }
        return order.sorted().compactMap { byFolder[$0] }
    }
}
