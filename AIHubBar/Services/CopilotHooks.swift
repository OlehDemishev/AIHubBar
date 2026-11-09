import Foundation

/// Copilot CLI session states through AI Hub Bar's own hook (SPEC-ai-services: «waiting» for agents without hooks).
/// Copilot reads every `*.json` in `~/.copilot/hooks/`; ours is a file of its own, so installing never touches the
/// person's other hooks and removing is deleting that file. The events are given in their Claude-style PascalCase
/// names, so Copilot sends Claude Code's snake_case payload and the same hook script writes `sessions/<id>.json`
/// with `agent: copilot` (docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference, read
/// 2026-11-03). No PermissionRequest: Copilot runs it before its own rules, so it doesn't mean a prompt is shown —
/// the `permission_prompt` notification does.
struct CopilotHooks {
    static let events = ["SessionStart", "UserPromptSubmit", "Notification", "PostToolUse", "Stop", "SessionEnd"]

    var fileURL: URL
    var scriptURL: URL
    var projectsDirectory: String

    static func live(projectsDirectory: String) -> CopilotHooks {
        CopilotHooks(
            fileURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".copilot/hooks/aihubbar.json"),
            scriptURL: SessionFiles.hookScriptURL,
            projectsDirectory: projectsDirectory
        )
    }

    var command: String {
        "\(HookInstaller.singleQuote(scriptURL.path)) --agent copilot --projects-dir \(HookInstaller.singleQuote(projectsDirectory))"
    }

    /// The whole hook file, as written.
    var configuration: [String: Any] {
        let entry: [String: Any] = ["type": "command", "bash": command, "timeoutSec": HookInstaller.timeoutSeconds]
        return ["version": 1, "hooks": Dictionary(uniqueKeysWithValues: Self.events.map { ($0, [entry]) })]
    }

    func status() -> HookStatus {
        guard let data = try? Data(contentsOf: fileURL) else { return .notInstalled }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              NSDictionary(dictionary: object).isEqual(to: configuration), scriptIsCurrent else { return .outdated }
        return .installed
    }

    func install() throws {
        try HookScript.write(to: scriptURL)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL.resolvingSymlinksInPath(), options: .atomic)
    }

    func uninstall() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// While our file is there, keeps the script this version ships (the Claude hook may not be installed).
    @discardableResult
    func updateScriptIfNeeded() throws -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path), !scriptIsCurrent else { return false }
        try HookScript.write(to: scriptURL)
        return true
    }

    private var scriptIsCurrent: Bool {
        (try? String(contentsOf: scriptURL, encoding: .utf8)) == HookScript.source
    }
}
