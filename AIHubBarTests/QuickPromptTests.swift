import Foundation
import Testing
@testable import AIHubBar

/// «Быстрый запрос» (docs/specs/SPEC-quick-prompt.md): which project, agent and mode the window starts with, and its keys.
struct QuickPromptTests {
    private let projects = [
        QuickPrompt.Candidate(name: "Cantero", path: "/Users/o/Projects/Cantero", lastActivity: Date(timeIntervalSince1970: 100)),
        QuickPrompt.Candidate(name: "Cantero-l5", path: "/Users/o/Projects/Cantero-l5", lastActivity: nil),
        QuickPrompt.Candidate(name: "ClaudePult", path: "/Users/o/Projects/ClaudePult", lastActivity: Date(timeIntervalSince1970: 300)),
        QuickPrompt.Candidate(name: "AI", path: "/Users/o/Projects/AI", lastActivity: Date(timeIntervalSince1970: 200)),
    ]

    @Test func frontDocumentPicksItsProject() {
        let front = FrontContext(bundleID: "com.apple.dt.Xcode", documentPath: "/Users/o/Projects/Cantero-l5/App/Main.swift", windowTitle: "Main.swift")
        #expect(QuickPrompt.frontProject(projects, front: front) == "/Users/o/Projects/Cantero-l5")
        // A sibling whose name starts the same is not a parent folder.
        let other = FrontContext(documentPath: "/Users/o/Projects/Cantero/README.md")
        #expect(QuickPrompt.frontProject(projects, front: other) == "/Users/o/Projects/Cantero")
    }

    @Test func worktreeInsideAProjectIsTheProjectWhenNotListed() {
        let front = FrontContext(documentPath: "/Users/o/Projects/ClaudePult/.claude/worktrees/feat-x/AIHubBar/App.swift")
        #expect(QuickPrompt.frontProject(projects, front: front) == "/Users/o/Projects/ClaudePult")
        let nested = projects + [QuickPrompt.Candidate(name: "feat-x", path: "/Users/o/Projects/ClaudePult/.claude/worktrees/feat-x")]
        #expect(QuickPrompt.frontProject(nested, front: front) == "/Users/o/Projects/ClaudePult/.claude/worktrees/feat-x")
    }

    @Test func windowTitleNamesTheProject() {
        #expect(QuickPrompt.frontProject(projects, front: FrontContext(windowTitle: "ClaudePult — claude — 120×40")) == "/Users/o/Projects/ClaudePult")
        // The longest name wins, and a name inside another word doesn't count.
        #expect(QuickPrompt.frontProject(projects, front: FrontContext(windowTitle: "cantero-l5 — zsh")) == "/Users/o/Projects/Cantero-l5")
        #expect(QuickPrompt.frontProject(projects, front: FrontContext(windowTitle: "AIHubBar.swift — Edited")) == nil)
        #expect(QuickPrompt.frontProject(projects, front: FrontContext(windowTitle: "Notes on AI")) == "/Users/o/Projects/AI")
        #expect(QuickPrompt.frontProject(projects, front: FrontContext(bundleID: "com.apple.Safari")) == nil)
    }

    @Test func defaultProjectOrder() {
        let terminal = FrontContext(windowTitle: "Cantero — zsh")
        #expect(QuickPrompt.defaultProject(projects, front: terminal, last: "/Users/o/Projects/AI") == "/Users/o/Projects/Cantero")
        #expect(QuickPrompt.defaultProject(projects, front: FrontContext(windowTitle: "Mail"), last: "/Users/o/Projects/AI") == "/Users/o/Projects/AI")
        // A last project that is gone: the most recently active one.
        #expect(QuickPrompt.defaultProject(projects, front: nil, last: "/Users/o/Projects/Gone") == "/Users/o/Projects/ClaudePult")
        let quiet = projects.map { QuickPrompt.Candidate(name: $0.name, path: $0.path) }
        #expect(QuickPrompt.defaultProject(quiet, front: nil, last: nil) == "/Users/o/Projects/Cantero")
        #expect(QuickPrompt.defaultProject([], front: terminal, last: "/x") == nil)
    }

    @Test func agentsAndModes() {
        #expect(QuickPrompt.agents(installed: []) == [.claudeCode])
        #expect(QuickPrompt.agents(installed: [.cursor, .codex, .claudeCode]) == [.claudeCode, .codex, .cursor])
        #expect(QuickPrompt.modes(for: .claudeCode) == [.background, .terminal])
        #expect(QuickPrompt.modes(for: .codex) == [.terminal])
        #expect(QuickPrompt.mode(for: .claudeCode, last: nil, preferred: nil) == .background)
        #expect(QuickPrompt.mode(for: .claudeCode, last: nil, preferred: .terminal) == .terminal)
        #expect(QuickPrompt.mode(for: .claudeCode, last: .background, preferred: .terminal) == .background)
        #expect(QuickPrompt.mode(for: .gemini, last: .background, preferred: .background) == .terminal)
    }

    @Test func sendNeedsTextAndProject() {
        #expect(!QuickPrompt.canSend("  \n", project: "/p"))
        #expect(!QuickPrompt.canSend("Fix it", project: nil))
        #expect(QuickPrompt.canSend("Fix it", project: "/p"))
    }

    @Test func hotKeysDontTakeOtherKeys() {
        let own = QuickPromptHotKey.allCases.filter { $0 != .off }.map { "\($0.keyCode)-\($0.modifiers)" }
        let search = PanelHotKey.allCases.filter { $0 != .off }.map { "\($0.keyCode)-\($0.modifiers)" }
        #expect(Set(own).count == own.count)
        #expect(Set(own).isDisjoint(with: search))
        #expect(QuickPromptHotKey.off.keyCode == 0 && QuickPromptSettings().hotKey == .controlOptionP)
    }

    @Test func settingsDecodeOldAndPartialData() throws {
        let decoded = try JSONDecoder().decode(QuickPromptSettings.self, from: Data(#"{"hotKey":"nope","lastProject":"/p"}"#.utf8))
        #expect(decoded.hotKey == .controlOptionP && decoded.lastProject == "/p" && decoded.lastMode == nil)
        var settings = QuickPromptSettings()
        settings.hotKey = .off
        settings.lastMode = "terminal"
        #expect(try JSONDecoder().decode(QuickPromptSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func wordMatching() {
        #expect(QuickPrompt.containsWord("Ambo", in: "~/Projects/ambo"))
        #expect(!QuickPrompt.containsWord("Ambo", in: "Ambos"))
        #expect(QuickPrompt.containsWord("Ambo", in: "x Ambos Ambo"))
    }
}
