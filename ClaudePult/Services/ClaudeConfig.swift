import AppKit
import Observation

/// One MCP server Claude Code knows about. Only the name, transport and command or address are shown: `env` and
/// `headers` often hold tokens and never leave the config.
struct MCPServer: Identifiable, Equatable, Sendable {
    enum Scope: Equatable, Hashable, Sendable {
        /// `~/.claude.json` → `mcpServers` (claude mcp add -s user).
        case user
        /// `~/.claude/settings.json` → `mcpServers`.
        case settings
        /// `~/.claude.json` → `projects[path].mcpServers` (claude mcp add -s local).
        case local(String)
        /// `<project>/.mcp.json`, shared through the repository.
        case project(String)

        var key: String {
            switch self {
            case .user: "user"
            case .settings: "settings"
            case let .local(path): "local:\(path)"
            case let .project(path): "project:\(path)"
            }
        }

        var projectPath: String? {
            switch self {
            case let .local(path), let .project(path): path
            case .user, .settings: nil
            }
        }

        var title: String {
            switch self {
            case .user: String(localized: "для всех проектов")
            case .settings: String(localized: "из ~/.claude/settings.json")
            case .local: String(localized: "только у вас в проекте")
            case .project: String(localized: "из .mcp.json проекта")
            }
        }
    }

    enum Status: Equatable, Sendable {
        case on, off
        /// A `.mcp.json` server Claude Code hasn't been allowed to start yet.
        case pending
    }

    var name: String
    var scope: Scope
    var transport: String
    var target: String
    var status: Status
    var id: String { "\(scope.key)|\(name)" }
}

/// Reads the MCP servers out of Claude Code's files; pure, so it's tested on sample files.
enum MCPConfig {
    static func servers(
        claudeJSON: [String: Any]?, settingsJSON: [String: Any]?,
        mcpFiles: [String: [String: Any]], localSettings: [String: [String: Any]], stashed: [MCPStash.Entry]
    ) -> [MCPServer] {
        var servers: [MCPServer] = []
        func add(_ object: Any?, scope: MCPServer.Scope, status: (String) -> MCPServer.Status) {
            for (name, config) in (object as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let (transport, target) = describe(config as? [String: Any] ?? [:])
                servers.append(MCPServer(name: name, scope: scope, transport: transport, target: target, status: status(name)))
            }
        }
        add(claudeJSON?["mcpServers"], scope: .user) { _ in .on }
        add(settingsJSON?["mcpServers"], scope: .settings) { _ in .on }
        let projects = claudeJSON?["projects"] as? [String: Any] ?? [:]
        for (path, value) in projects.sorted(by: { $0.key < $1.key }) {
            add((value as? [String: Any])?["mcpServers"], scope: .local(path)) { _ in .on }
        }
        for (path, file) in mcpFiles.sorted(by: { $0.key < $1.key }) {
            let project = projects[path] as? [String: Any] ?? [:]
            let local = localSettings[path] ?? [:]
            let disabled = Set(strings(project["disabledMcpjsonServers"]) + strings(local["disabledMcpjsonServers"]))
            let enabled = Set(strings(project["enabledMcpjsonServers"]) + strings(local["enabledMcpjsonServers"]))
            let all = (local["enableAllProjectMcpServers"] as? Bool ?? false) || (settingsJSON?["enableAllProjectMcpServers"] as? Bool ?? false)
            add(file["mcpServers"], scope: .project(path)) { name in
                disabled.contains(name) ? .off : (enabled.contains(name) || all ? .on : .pending)
            }
        }
        for entry in stashed where !servers.contains(where: { $0.name == entry.name && $0.scope.key == entry.scopeKey }) {
            guard let scope = entry.scope else { continue }
            let (transport, target) = describe(entry.configObject)
            servers.append(MCPServer(name: entry.name, scope: scope, transport: transport, target: target, status: .off))
        }
        return servers
    }

    /// «stdio · npx -y @x/server», «http · https://mcp.example.com/…» (no query, no secrets).
    static func describe(_ config: [String: Any]) -> (String, String) {
        if let url = config["url"] as? String {
            let transport = config["type"] as? String ?? "http"
            let clean = URL(string: url).map { "\($0.scheme ?? "https")://\($0.host ?? "")\($0.port.map { ":\($0)" } ?? "")\($0.path)" } ?? url
            return (transport, clean)
        }
        let command = ([config["command"] as? String ?? ""] + strings(config["args"])).filter { !$0.isEmpty }.joined(separator: " ")
        return (config["type"] as? String ?? "stdio", command)
    }

    static func strings(_ value: Any?) -> [String] { value as? [String] ?? [] }

    /// `disabledMcpjsonServers` in a project's `.claude/settings.local.json` with `name` switched off or back on.
    static func settingsLocal(_ settings: [String: Any], disabling name: String, _ off: Bool) -> [String: Any] {
        var settings = settings
        var disabled = strings(settings["disabledMcpjsonServers"]).filter { $0 != name }
        var enabled = strings(settings["enabledMcpjsonServers"]).filter { $0 != name }
        if off { disabled.append(name) } else { enabled.append(name) }
        settings["disabledMcpjsonServers"] = disabled.isEmpty ? nil : disabled
        settings["enabledMcpjsonServers"] = enabled.isEmpty ? nil : enabled
        return settings
    }
}

/// Servers switched off from AI Hub Bar keep their config here, to come back exactly as they were (0600: `env` may
/// hold tokens).
enum MCPStash {
    struct Entry: Codable, Equatable, Sendable {
        var name: String
        var scopeKey: String
        var config: String

        var configObject: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [String: Any] ?? [:] }

        var scope: MCPServer.Scope? {
            if scopeKey == "user" { return .user }
            if scopeKey == "settings" { return .settings }
            if scopeKey.hasPrefix("local:") { return .local(String(scopeKey.dropFirst(6))) }
            return nil
        }
    }

    static var url: URL { SessionFiles.supportDirectory.appending(path: "mcp-disabled.json") }

    static func load() -> [Entry] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    static func save(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// One instruction file Claude Code reads: global, the projects folder's, or a project's.
struct InstructionFile: Identifiable, Equatable, Sendable {
    var title: String
    var group: String
    var path: String
    var id: String { path }

    static func all(home: String = NSHomeDirectory(), projectsDirectory: String, projects: [(name: String, path: String)]) -> [InstructionFile] {
        let fm = FileManager.default
        var files: [InstructionFile] = []
        let general = String(localized: "Общие")
        for (title, path) in [("~/.claude/CLAUDE.md", home + "/.claude/CLAUDE.md"),
                              ((projectsDirectory as NSString).abbreviatingWithTildeInPath + "/CLAUDE.md", projectsDirectory + "/CLAUDE.md")]
        where fm.fileExists(atPath: path) {
            files.append(InstructionFile(title: title, group: general, path: path))
        }
        for project in projects.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            for name in ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md", "AGENTS.md"] {
                let path = project.path + "/" + name
                if fm.fileExists(atPath: path) { files.append(InstructionFile(title: name, group: project.name, path: path)) }
            }
        }
        return files
    }

    /// Lines containing `query` (case and diacritics ignored), numbered from 1.
    static func matches(_ text: String, query: String) -> [(line: Int, text: String)] {
        guard !query.isEmpty else { return [] }
        return text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? nil
                : (index + 1, line.trimmingCharacters(in: .whitespaces))
        }
    }
}

/// The «Claude Code» window: instruction files and MCP servers.
@MainActor
@Observable
final class ClaudeConfigStore {
    private(set) var servers: [MCPServer] = []
    private(set) var files: [InstructionFile] = []
    private(set) var texts: [String: String] = [:]
    private(set) var busy: Set<String> = []
    var error: String?

    private let settings: AppSettings
    private let projects: ProjectStore
    private let home = NSHomeDirectory()

    init(settings: AppSettings, projects: ProjectStore) {
        self.settings = settings
        self.projects = projects
    }

    private var claudeJSONURL: URL { URL(fileURLWithPath: home + "/.claude.json") }
    private var settingsURL: URL { URL(fileURLWithPath: home + "/.claude/settings.json") }

    private var projectPaths: [String] {
        var paths = Set(projects.projects.map(\.path))
        if let known = (readJSON(claudeJSONURL)?["projects"] as? [String: Any])?.keys {
            paths.formUnion(known.filter { FileManager.default.fileExists(atPath: $0 + "/.mcp.json") })
        }
        return paths.sorted()
    }

    func reload() {
        let claude = readJSON(claudeJSONURL)
        var mcpFiles: [String: [String: Any]] = [:], local: [String: [String: Any]] = [:]
        for path in projectPaths {
            if let file = readJSON(URL(fileURLWithPath: path + "/.mcp.json")) { mcpFiles[path] = file }
            if let file = readJSON(URL(fileURLWithPath: path + "/.claude/settings.local.json")) { local[path] = file }
        }
        servers = MCPConfig.servers(claudeJSON: claude, settingsJSON: readJSON(settingsURL), mcpFiles: mcpFiles,
                                    localSettings: local, stashed: MCPStash.load())
        files = InstructionFile.all(home: home, projectsDirectory: settings.projectsDirectory,
                                    projects: projects.projects.map { ($0.name, $0.path) })
        texts = Dictionary(uniqueKeysWithValues: files.map { ($0.path, (try? String(contentsOfFile: $0.path, encoding: .utf8)) ?? "") })
    }

    func save(_ text: String, to file: InstructionFile) {
        do {
            try text.write(toFile: file.path, atomically: true, encoding: .utf8)
            texts[file.path] = text
            AppLog.info("Saved \(file.path)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func projectName(_ path: String) -> String {
        projects.projects.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
    }

    // MARK: - Switching servers

    func setEnabled(_ server: MCPServer, _ on: Bool) async {
        busy.insert(server.id)
        defer { busy.remove(server.id); reload() }
        do {
            switch server.scope {
            case let .project(path):
                let url = URL(fileURLWithPath: path + "/.claude/settings.local.json")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writeJSON(MCPConfig.settingsLocal(readJSON(url) ?? [:], disabling: server.name, !on), to: url)
            case .settings:
                try toggleInSettings(server, on)
            case .user, .local:
                try await toggleWithCLI(server, on)
            }
            AppLog.info("MCP «\(server.name)» (\(server.scope.key)) \(on ? "on" : "off")")
        } catch {
            self.error = error.localizedDescription
            AppLog.error("MCP «\(server.name)» switch failed: \(error.localizedDescription)")
        }
    }

    /// `~/.claude/settings.json`: the entry moves to the stash and back (a backup of the file first).
    private func toggleInSettings(_ server: MCPServer, _ on: Bool) throws {
        var json = readJSON(settingsURL) ?? [:]
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        var stash = MCPStash.load()
        if on {
            guard let index = stash.firstIndex(where: { $0.name == server.name && $0.scopeKey == server.scope.key }) else { return }
            servers[server.name] = stash[index].configObject
            stash.remove(at: index)
        } else {
            guard let config = servers.removeValue(forKey: server.name) else { return }
            stash.append(.init(name: server.name, scopeKey: server.scope.key, config: try jsonString(config)))
        }
        try backup(settingsURL)
        try MCPStash.save(stash)
        json["mcpServers"] = servers
        try writeJSON(json, to: settingsURL)
    }

    /// `~/.claude.json` changes all the time while Claude runs, so it's left to `claude mcp remove` / `add-json`.
    private func toggleWithCLI(_ server: MCPServer, _ on: Bool) async throws {
        let claude = ClaudeLocator.resolve(configured: settings.claudePath)
        let scope = server.scope == .user ? "user" : "local"
        let folder = server.scope.projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var stash = MCPStash.load()
        let arguments: [String]
        if on {
            guard let index = stash.firstIndex(where: { $0.name == server.name && $0.scopeKey == server.scope.key }) else { return }
            arguments = ["mcp", "add-json", server.name, stash[index].config, "-s", scope]
            try await runClaude(claude, arguments, in: folder)
            stash.remove(at: index)
        } else {
            let json = readJSON(claudeJSONURL)
            let config: Any? = server.scope == .user
                ? (json?["mcpServers"] as? [String: Any])?[server.name]
                : (((json?["projects"] as? [String: Any])?[server.scope.projectPath ?? ""] as? [String: Any])?["mcpServers"] as? [String: Any])?[server.name]
            guard let config else { return }
            // Kept before removing, so a failed removal loses nothing.
            stash.append(.init(name: server.name, scopeKey: server.scope.key, config: try jsonString(config)))
            try MCPStash.save(stash)
            arguments = ["mcp", "remove", server.name, "-s", scope]
            do {
                try await runClaude(claude, arguments, in: folder)
            } catch {
                stash.removeLast()
                try? MCPStash.save(stash)
                throw error
            }
        }
        try MCPStash.save(stash)
    }

    private func runClaude(_ claude: String, _ arguments: [String], in folder: URL?) async throws {
        let result = try await ProcessRunner.run(claude, arguments, currentDirectory: folder, timeout: .seconds(30))
        guard result.exitCode == 0 else {
            let detail = (result.stderrText + result.stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessError.launchFailed("claude \(arguments.prefix(2).joined(separator: " "))", underlying: detail)
        }
    }

    // MARK: - Files

    private func readJSON(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func jsonString(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let target = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".aihubbar-backup-\(stamp)")
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: url, to: target) }
    }
}
