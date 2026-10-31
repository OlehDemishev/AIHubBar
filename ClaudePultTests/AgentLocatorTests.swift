import Foundation
import Testing
@testable import ClaudePult

struct AgentLocatorTests {
    /// A fake home folder with an executable file at each of `paths` (relative to it).
    private func home(with paths: [String]) throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)").path
        for path in paths {
            let file = "\(home)/\(path)"
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        return home
    }

    /// Only files in the fake home count: this Mac's own `/opt/homebrew/bin/claude` must not answer.
    private func detect(_ binary: String, _ home: String, shell: [String: String] = [:]) -> String? {
        AgentLocator.detect(binary, home: home, shellPaths: shell) { $0.hasPrefix(home) && FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test func nothingInstalled() throws {
        let home = try home(with: [])
        for kind in AgentKind.allCases { #expect(detect(kind.binary, home) == nil) }
    }

    @Test func findsNewestNvmVersion() throws {
        let home = try home(with: [".nvm/versions/node/v9.11.2/bin/claude", ".nvm/versions/node/v20.11.0/bin/claude"])
        #expect(detect("claude", home) == "\(home)/.nvm/versions/node/v20.11.0/bin/claude")
    }

    @Test func otherAgentsInVersionManagers() throws {
        let home = try home(with: [
            ".nvm/versions/node/v22.1.0/bin/gemini",
            "Library/Application Support/fnm/node-versions/v20.0.0/installation/bin/copilot",
            ".volta/bin/codex",
            "Library/pnpm/cursor-agent",
        ])
        #expect(detect("gemini", home) == "\(home)/.nvm/versions/node/v22.1.0/bin/gemini")
        #expect(detect("copilot", home) == "\(home)/Library/Application Support/fnm/node-versions/v20.0.0/installation/bin/copilot")
        #expect(detect("codex", home) == "\(home)/.volta/bin/codex")
        #expect(detect("cursor-agent", home) == "\(home)/Library/pnpm/cursor-agent")
    }

    @Test func desktopAppCopyIsOnlyForClaude() throws {
        let copy = "Library/Application Support/Claude/claude-code/2.1.309/5af865b9901c/claude.app/Contents/MacOS/claude"
        let home = try home(with: [
            "Library/Application Support/Claude/claude-code/2.1.99/a93ded4b1b47/claude.app/Contents/MacOS/claude", copy,
        ])
        #expect(detect("claude", home) == "\(home)/\(copy)")
        #expect(detect("codex", home) == nil)
    }

    @Test func orderOfPlaces() throws {
        let desktop = "Library/Application Support/Claude/claude-code/2.1.309/x/claude.app/Contents/MacOS/claude"
        let home = try home(with: [desktop, ".nvm/versions/node/v20.0.0/bin/claude", "shell/claude", ".local/bin/claude"])
        let shell = ["claude": "\(home)/shell/claude"]
        #expect(detect("claude", home, shell: shell) == "\(home)/.local/bin/claude")
        try FileManager.default.removeItem(atPath: "\(home)/.local/bin/claude")
        #expect(detect("claude", home, shell: shell) == "\(home)/shell/claude")
        #expect(detect("claude", home) == "\(home)/.nvm/versions/node/v20.0.0/bin/claude")
        // A shell answer that no longer exists is skipped.
        #expect(detect("claude", home, shell: ["claude": "\(home)/gone/claude"]) == "\(home)/.nvm/versions/node/v20.0.0/bin/claude")
    }

    @Test func shellOutput() {
        #expect(AgentLocator.shellPaths(fromOutput: "/opt/homebrew/bin/claude\n") == ["claude": "/opt/homebrew/bin/claude"])
        #expect(AgentLocator.shellPaths(fromOutput: "Welcome back!\n  /Users/a/.nvm/versions/node/v22.1.0/bin/gemini  \n/Users/a/.local/bin/agy\n")
            == ["gemini": "/Users/a/.nvm/versions/node/v22.1.0/bin/gemini", "agy": "/Users/a/.local/bin/agy"])
        #expect(AgentLocator.shellPaths(fromOutput: "alias claude=/Users/a/.claude/local/claude").isEmpty)
        #expect(AgentLocator.shellPaths(fromOutput: "").isEmpty)
    }

    /// The real shell answers on this Mac; whatever it names exists.
    @Test func refreshAsksTheShell() async {
        await AgentLocator.refreshShellPaths()
        for (name, path) in AgentLocator.shellPaths {
            #expect((path as NSString).lastPathComponent == name)
            #expect(FileManager.default.isExecutableFile(atPath: path))
        }
    }
}
