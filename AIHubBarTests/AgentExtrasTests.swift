import Foundation
import Testing
@testable import AIHubBar

/// Skills, plugins and hooks of Claude Code and Codex (`AgentExtras`).
struct AgentExtrasTests {
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "extras-\(UUID().uuidString)")
        for (folder, text) in [
            (".claude/skills/animate", "---\nname: animate\ndescription: \"Build an animation: from scratch\"\n---\n\n# Body\nname: not this"),
            (".claude/skills.disabled/old-one", "---\ndescription: Old\n---"),
            (".codex/skills/review", "no frontmatter"),
        ] {
            let url = home.appending(path: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try text.write(to: url.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        // A folder without SKILL.md (Claude's `synced`) is not a skill.
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/skills/synced"), withIntermediateDirectories: true)
        return home
    }

    @Test func skillsOfBothAgentsOnAndOff() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let skills = AgentExtras.skills(home: home.path)
        #expect(skills.map(\.id) == ["claude:animate", "claude:old-one", "codex:review"].map { $0.replacingOccurrences(of: "claude:", with: "\(AgentKind.claudeCode.rawValue):").replacingOccurrences(of: "codex:", with: "\(AgentKind.codex.rawValue):") })
        #expect(skills[0].description == "Build an animation: from scratch" && skills[0].isOn)
        #expect(!skills[1].isOn && skills[1].name == "old-one", "the folder's name when the file gives none")
        #expect(skills[2].description.isEmpty)
    }

    @Test func aSkillSwitchedOffMovesAsideAndComesBack() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let animate = try #require(AgentExtras.skills(home: home.path).first { $0.name == "animate" })
        try AgentExtras.move(animate, on: false, home: home.path)
        let off = try #require(AgentExtras.skills(home: home.path).first { $0.name == "animate" })
        #expect(!off.isOn && off.folder.hasSuffix(".claude/skills.disabled/animate"))
        #expect(!FileManager.default.fileExists(atPath: animate.folder))
        #expect(AgentExtras.destination(off, on: false, home: home.path) == nil, "already off")
        try AgentExtras.move(off, on: true, home: home.path)
        #expect(AgentExtras.skills(home: home.path).first { $0.name == "animate" } == animate, "back as it was")
    }

    @Test func pluginsAreOnUnlessSwitchedOff() {
        let installed: [String: Any] = ["version": 2, "plugins": ["b@market": [["version": "1.2.0"]], "a@market": [[:]]]]
        let plugins = AgentExtras.plugins(installed: installed, settings: ["enabledPlugins": ["b@market": false]])
        #expect(plugins.map(\.key) == ["a@market", "b@market"])
        #expect(plugins[0].isOn && !plugins[1].isOn && plugins[1].version == "1.2.0")
        #expect(plugins[1].name == "b" && plugins[1].marketplace == "market")
        let changed = AgentExtras.settings(["theme": "dark", "enabledPlugins": ["b@market": false]], plugin: "a@market", on: false)
        #expect(changed["theme"] as? String == "dark", "the rest of the file stays")
        #expect((changed["enabledPlugins"] as? [String: Bool]) == ["a@market": false, "b@market": false])
        #expect(AgentExtras.plugins(installed: nil, settings: nil).isEmpty)
    }

    @Test func hooksAreListedWithOursMarked() {
        let object: [String: Any] = ["hooks": [
            "Stop": [["hooks": [["type": "command", "command": "/usr/bin/python3 /x/\(HookInstaller.marker).py --agent codex"]]]],
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/bin/true"], ["type": "prompt"]]]],
        ]]
        let hooks = AgentExtras.hooks(object, agent: .codex)
        #expect(hooks.map(\.event) == ["PreToolUse", "Stop"])
        #expect(!hooks[0].isOurs && hooks[1].isOurs)
        #expect(AgentExtras.hooks(nil, agent: .claudeCode).isEmpty)
    }
}
