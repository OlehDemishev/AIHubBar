import Foundation
import Testing
@testable import AIHubBar

/// A task handed from Claude to Codex at the limit (`Handover`).
struct HandoverTests {
    private func run(_ state: BackgroundRun.State, paused: Bool = false, agent: String? = nil, prompt: String? = "Add export") -> BackgroundRun {
        BackgroundRun(
            id: "r1", project: "Ambo", projectPath: "/P/Ambo", folder: "/P/Ambo", worktreeBranch: nil,
            commandTitle: "Своя задача", task: "Add export", startedAt: .now, timeLimitMinutes: 90, pid: 1,
            state: state, notified: false, pausedAt: paused ? .now : nil, agent: agent, prompt: prompt
        )
    }

    @Test func aRunStuckAtTheLimitCanGoToCodex() {
        #expect(Handover.canHandOver(run(.running, paused: true)), "paused by the limit guard")
        #expect(Handover.canHandOver(run(.failed)) && Handover.canHandOver(run(.stopped)))
        #expect(!Handover.canHandOver(run(.running)), "a run that works is left alone")
        #expect(!Handover.canHandOver(run(.succeeded)))
        #expect(!Handover.canHandOver(run(.failed, agent: CodexExec.agent)), "Codex's own run has nowhere to go")
        #expect(!Handover.canHandOver(run(.failed, prompt: nil)), "a run started before tasks were kept")
    }

    @Test func theNextAgentIsToldToLookFirst() {
        let prompt = Handover.prompt(task: "Add export\nwith tests", from: "Claude Code")
        #expect(prompt.contains("git status") && prompt.contains("git diff"))
        #expect(prompt.contains("Claude Code") && prompt.hasSuffix("Add export\nwith tests"))
    }

    @Test func oldRunFilesStillLoad() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(run(.failed))) as? [String: Any])
        for key in ["prompt", "agent", "threadID"] { object[key] = nil }
        let old = try decoder.decode(BackgroundRun.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.prompt == nil && old.agent == nil && old.agentTitle == AgentKind.claudeCode.title)
    }
}
