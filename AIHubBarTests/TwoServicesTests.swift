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

    @Test func theComparisonFindsThePartnerAndTheFilesBothChanged() throws {
        let claude = run("a", .succeeded), codex = run("b", .succeeded, agent: CodexExec.agent)
        let review = run("r", .succeeded, agent: CodexExec.agent, reviewOf: "a")
        let all = [review, codex, claude, run("c", .succeeded, pair: nil)]
        #expect(PairCompare.partner(of: claude, runs: all)?.id == "b" && PairCompare.partner(of: codex, runs: all)?.id == "a")
        #expect(PairCompare.partner(of: all[3], runs: all) == nil && PairCompare.partner(of: review, runs: all) == nil)
        #expect(PairCompare.sides("p", runs: all)?.map(\.id) == ["a", "b"], "Claude first, the review left out")
        #expect(PairCompare.sides("p", runs: [claude]) == nil)

        let first = SessionChanges.parse(numstat: "12\t3\tA.swift\n1\t0\tB.swift", untracked: "new.txt")
        let second = SessionChanges.parse(numstat: "4\t4\tA.swift", untracked: "new.txt\nother.txt")
        #expect(PairCompare.common(first, second) == ["A.swift", "new.txt"])
        #expect(PairCompare.common(first, nil).isEmpty)
        #expect(PairCompare.line(claude, changes: first).hasSuffix(" · " + first.summary))
        #expect(PairCompare.line(claude, changes: SessionChanges(files: [])) == TwoServices.lines([claude])[0])
        #expect(PairCompare.diffCommand([claude, codex]) == "git diff cb/export-claude cb/export-codex")
    }
}
