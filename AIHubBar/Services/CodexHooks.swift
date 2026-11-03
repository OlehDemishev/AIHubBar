import Foundation

/// Codex CLI session states through AI Hub Bar's hook (SPEC-ai-services stage 7). Codex reads user hooks from
/// `~/.codex/hooks.json` — the same shape as Claude Code's `hooks` in settings.json, with a Claude-style snake_case
/// payload (`session_id`, `cwd`, `hook_event_name`, `prompt`, `tool_name`, `tool_input`), so the same hook script
/// writes `sessions/<id>.json` with `agent: codex` (learn.chatgpt.com/docs/hooks, read 2026-11-03; Codex
/// 0.166.0-alpha.5.1 lists `hooks` as a stable feature, on by default). The file is shared with the person's own
/// hooks: our entries are merged in and taken out like Claude's (`HookInstaller`), with a backup first.
/// `PermissionRequest` runs when Codex is about to show an approval prompt; `Stop` ends a turn, `Interrupt` is Esc.
/// Codex runs a new or changed hook only after the person trusts it in `/hooks` (it keeps that in its own
/// `config.toml`, which AI Hub Bar never writes); the command doesn't change between versions, so trusting is once.
struct CodexHooks {
    static let events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]

    /// Codex allows `SessionEnd` and `Interrupt` 3 seconds at most (it clamps a longer timeout with a warning).
    static func timeout(for event: String) -> Int {
        ["SessionEnd", "Interrupt"].contains(event) ? 3 : HookInstaller.timeoutSeconds
    }

    var fileURL: URL
    var scriptURL: URL
    var projectsDirectory: String

    static func live(projectsDirectory: String) -> CodexHooks {
        CodexHooks(
            fileURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/hooks.json"),
            scriptURL: SessionFiles.hookScriptURL,
            projectsDirectory: projectsDirectory
        )
    }

    var command: String {
        "\(HookInstaller.singleQuote(scriptURL.path)) --agent codex --projects-dir \(HookInstaller.singleQuote(projectsDirectory))"
    }

    private var file: HookJSONFile { HookJSONFile(url: fileURL, shownAs: "~/.codex/hooks.json") }

    func status() -> HookStatus {
        guard let hooks = try? file.read() else { return .notInstalled }
        let status = HookInstaller.status(of: hooks, expectedCommand: command, events: Self.events, timeout: Self.timeout(for:))
        return status == .installed && !scriptIsCurrent ? .outdated : status
    }

    /// Writes the script and merges our entries into hooks.json; returns the backup (nil when there was no file).
    @discardableResult
    func install() throws -> URL? {
        try HookScript.write(to: scriptURL)
        let current = try file.read()
        let hooks = HookInstaller.merged(current ?? [:], command: command, events: Self.events, timeout: Self.timeout(for:))
        if let current, NSDictionary(dictionary: current).isEqual(to: hooks) { return nil }
        let backup = try file.backup()
        try file.write(hooks)
        AppLog.info("Codex hooks installed into \(fileURL.path)" + (backup.map { ", backup \($0.lastPathComponent)" } ?? ""))
        return backup
    }

    /// Takes our entries out; a file left with nothing else in it is removed (AI Hub Bar made it).
    @discardableResult
    func uninstall() throws -> URL? {
        guard let current = try file.read() else { return nil }
        let hooks = HookInstaller.removed(current)
        if NSDictionary(dictionary: current).isEqual(to: hooks) { return nil }
        let backup = try file.backup()
        if hooks.isEmpty {
            try FileManager.default.removeItem(at: fileURL)
        } else {
            try file.write(hooks)
        }
        AppLog.info("Codex hooks removed from \(fileURL.path)" + (backup.map { ", backup \($0.lastPathComponent)" } ?? ""))
        return backup
    }

    /// While our entries are there, keeps the script this version ships (the Claude hook may not be installed).
    @discardableResult
    func updateScriptIfNeeded() throws -> Bool {
        guard !scriptIsCurrent, let hooks = try? file.read(),
              HookInstaller.status(of: hooks, expectedCommand: command, checkTimeouts: false, events: Self.events) == .installed
        else { return false }
        try HookScript.write(to: scriptURL)
        return true
    }

    private var scriptIsCurrent: Bool {
        (try? String(contentsOf: scriptURL, encoding: .utf8)) == HookScript.source
    }
}
