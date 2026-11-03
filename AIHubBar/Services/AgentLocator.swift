import AppKit
import os

/// Finds an AI agent's CLI (`claude`, `codex`, `gemini`, …). It may sit wherever an installer or a Node version
/// manager put it, and an app started from Finder does not get the PATH the user's shell sets up.
enum AgentLocator {
    /// Fixed places: Homebrew, the native installers' `~/.local/bin`, npm/pnpm/yarn/bun prefixes, volta, cargo,
    /// asdf and mise shims.
    static func candidates(_ binary: String, home: String = NSHomeDirectory()) -> [String] {
        [
            "/opt/homebrew/bin/\(binary)",
            "/usr/local/bin/\(binary)",
            "\(home)/.local/bin/\(binary)",
            "\(home)/.npm-global/bin/\(binary)",
            "\(home)/.bun/bin/\(binary)",
            "\(home)/.volta/bin/\(binary)",
            "\(home)/Library/pnpm/\(binary)",
            "\(home)/.yarn/bin/\(binary)",
            "\(home)/.cargo/bin/\(binary)",
            "\(home)/.asdf/shims/\(binary)",
            "\(home)/.local/share/mise/shims/\(binary)",
        ] + (binary == "claude" ? ["\(home)/.claude/local/claude"] : [])
    }

    /// npm installs under nvm and fnm, newest Node version first.
    static func versionManagerCandidates(_ binary: String, home: String = NSHomeDirectory()) -> [String] {
        versioned("\(home)/.nvm/versions/node", tail: "bin/\(binary)")
            + versioned("\(home)/Library/Application Support/fnm/node-versions", tail: "installation/bin/\(binary)")
            + versioned("\(home)/.local/share/fnm/node-versions", tail: "installation/bin/\(binary)")
    }

    /// The `claude` the Claude desktop app keeps for itself (`claude-code/<version>/<hash>/claude.app`), newest
    /// first. Its folder changes with every update, so it is found again each time, never saved.
    static func claudeDesktopCandidates(home: String = NSHomeDirectory()) -> [String] {
        versioned("\(home)/Library/Application Support/Claude/claude-code", tail: "").flatMap { versionFolder in
            subfolders(versionFolder).map { "\(versionFolder)/\($0)/claude.app/Contents/MacOS/claude" }
        }
    }

    /// Bundle ids of the ChatGPT desktop app: `com.openai.codex` is the app that ships the Codex CLI (checked on
    /// 2026-10-31, ChatGPT 26.1027); `com.openai.chat` is its earlier id. Its installer has another id.
    static let chatGPTBundleIDs = ["com.openai.codex", "com.openai.chat"]

    /// The `codex` the ChatGPT desktop app keeps for itself (`Contents/Resources/codex-cli/bin/codex`): every copy
    /// Launch Services knows, wherever it sits, then `/Applications` and `~/Applications`.
    static func chatGPTDesktopCandidates(home: String = NSHomeDirectory(), apps: [String] = chatGPTApps()) -> [String] {
        var seen: Set<String> = []
        return (apps + ["/Applications/ChatGPT.app", "\(home)/Applications/ChatGPT.app"])
            .filter { seen.insert(($0 as NSString).standardizingPath).inserted }
            .map { "\(($0 as NSString).standardizingPath)/Contents/Resources/codex-cli/bin/codex" }
    }

    static func chatGPTApps() -> [String] {
        chatGPTBundleIDs.flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0).map(\.path) }
    }

    /// Fixed places, then what the user's shell finds, then version managers, then (for `claude` and `codex`) the
    /// desktop app's copy.
    static func detect(
        _ binary: String, home: String = NSHomeDirectory(), shellPaths: [String: String] = shellPaths,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        let ordered = candidates(binary, home: home) + [shellPaths[binary]].compactMap { $0 }
            + versionManagerCandidates(binary, home: home)
            + (binary == "claude" ? claudeDesktopCandidates(home: home) : [])
            + (binary == "codex" ? chatGPTDesktopCandidates(home: home) : [])
        return ordered.first(where: isExecutable)
    }

    // MARK: - The user's shell

    private static let shellLookup = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Binary name → path from the user's interactive login shell, once `refreshShellPaths()` has run.
    static var shellPaths: [String: String] { shellLookup.withLock { $0 } }

    /// Asks the user's shell where every agent is (one `command -v` for all): it loads `.zprofile` and `.zshrc`,
    /// where nvm and the like set PATH.
    static func refreshShellPaths() async {
        let shell = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let binaries = AgentKind.allCases.map(\.binary)
        // Not the exit code: `command -v` fails when any one name is missing.
        let result = try? await ProcessRunner.run(shell, ["-ilc", "command -v " + binaries.joined(separator: " ")], timeout: .seconds(10))
        let paths = result.map { shellPaths(fromOutput: $0.stdoutText) } ?? [:]
        shellLookup.withLock { $0 = paths }
        if !paths.isEmpty { AppLog.info("Agents in the login shell: \(paths.values.sorted().joined(separator: ", "))") }
    }

    /// Absolute paths by their last component: an interactive shell may print a greeting first, and an alias
    /// (`alias claude=/…/claude`) is not a path to run.
    static func shellPaths(fromOutput output: String) -> [String: String] {
        var paths: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { continue }
            let name = (path as NSString).lastPathComponent
            if paths[name] == nil { paths[name] = path }
        }
        return paths
    }

    // MARK: - Folders

    /// `<root>/<version>/<tail>` for every version folder, newest version first.
    private static func versioned(_ root: String, tail: String) -> [String] {
        subfolders(root)
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { tail.isEmpty ? "\(root)/\($0)" : "\(root)/\($0)/\(tail)" }
    }

    private static func subfolders(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }
    }
}
