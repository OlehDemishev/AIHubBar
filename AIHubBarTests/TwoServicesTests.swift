import Foundation
import Testing
@testable import AIHubBar

/// One task given to Claude and Codex at once (`TwoServices`).
struct TwoServicesTests {
    private func run(_ id: String, _ state: BackgroundRun.State, agent: String? = nil, pair: String? = "p", reviewOf: String? = nil) -> BackgroundRun {
        BackgroundRun(
            id: id, project: "Ambo", projectPath: "/P/Ambo", folder: "/P/Ambo/.claude/worktrees/cb-export-\(agent ?? "claude")",
            worktreeBranch: "cb/export-\(agent ?? "claude")", commandTitle: "Своя задача", task: "Add export", startedAt: .now,
            timeLimitMinutes: 90, pid: 1, state: state, finishedAt: state.isFinished ? .now : nil,
            summary: state == .succeeded ? "Done.\nSecond line" : nil, notified: false, agent: agent, reviewOf: reviewOf, pair: pair
        )
    }

    @Test func eachServiceGetsItsOwnWorktreeName() {
        let claude = WorktreePlan.slug(from: TwoServices.nameSource("Добавь экспорт", codex: false))
        let codex = WorktreePlan.slug(from: TwoServices.nameSource("Добавь экспорт", codex: true))
        #expect(claude != codex && claude.hasSuffix("claude") && codex.hasSuffix("codex"))
    }

    @Test func thePairIsAnnouncedWhenBothHaveFinished() throws {
        let claude = run("a", .succeeded), codex = run("b", .running, agent: CodexExec.agent)
        #expect(TwoServices.finishedPair("p", runs: [claude, codex]) == nil, "one still works")
        let done = try #require(TwoServices.finishedPair("p", runs: [run("b", .failed, agent: CodexExec.agent), claude, run("c", .succeeded, pair: nil)]))
        #expect(done.map(\.id) == ["a", "b"], "Claude first")
        // A review of one of them is not a member of the pair.
        #expect(TwoServices.finishedPair("p", runs: [claude, run("b", .failed, agent: CodexExec.agent), run("r", .running, reviewOf: "a")]) != nil)
        #expect(TwoServices.finishedPair("p", runs: [claude]) == nil)

        let lines = TwoServices.lines(done)
        #expect(lines[0] == "\(AgentKind.claudeCode.title) (cb/export-claude): Done.", "the first line of the result")
        #expect(lines[1].hasPrefix("\(AgentKind.codex.title) (cb/export-codex): "))
    }
}
