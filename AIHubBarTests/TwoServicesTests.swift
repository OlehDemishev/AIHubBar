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
        #expect(claude != codex && claude.hasPrefix("claude-") && codex.hasPrefix("codex-"))
        let long = "In greet.py add a function farewell(name) that returns a goodbye string"
        #expect(WorktreePlan.slug(from: TwoServices.nameSource(long, codex: true)).hasPrefix("codex-in-greet"), "the service survives the cut")
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

    @Test func aDiffBecomesLinesToShow() {
        let text = """
        diff --git a/greet.py b/greet.py
        index d282150..9e43d32 100644
        --- a/greet.py
        +++ b/greet.py
        @@ -1,2 +1,6 @@
         def greet(name):
        -    return "Hi"
        +    return "Hello"

        """
        let parsed = PairCompare.diffLines(text)
        #expect(parsed.lines.map(\.kind) == [.file, .hunk, .context, .removed, .added] && !parsed.cut)
        #expect(parsed.lines[0].text == "greet.py" && parsed.lines[4].text == "+    return \"Hello\"")
        let long = PairCompare.diffLines("diff --git a/x b/x\n" + Array(repeating: "+line", count: 20).joined(separator: "\n"), limit: 5)
        #expect(long.cut && long.lines.count == 5)
        #expect(PairCompare.diffLines("").lines.isEmpty)
    }

    @Test func oneVariantIsKeptOnlyWhenTheOtherIsAWorktreeOfTheProject() {
        let claude = run("a", .succeeded), codex = run("b", .succeeded, agent: CodexExec.agent)
        #expect(PairCompare.canKeep(claude, sides: [claude, codex]) && PairCompare.canKeep(codex, sides: [claude, codex]))
        #expect(!PairCompare.canKeep(claude, sides: [claude, run("b", .running, agent: CodexExec.agent)]), "not while one still works")
        var elsewhere = codex
        elsewhere.folder = "/P/Other/.claude/worktrees/x"
        var nested = codex
        nested.folder = "/P/Ambo/.claude/worktrees/x/sub"
        var project = codex
        project.folder = "/P/Ambo"
        for other in [elsewhere, nested, project] {
            #expect(!PairCompare.removable(other) && !PairCompare.canKeep(claude, sides: [claude, other]))
        }
        var symlinked = codex
        symlinked.projectPath = "/private/tmp/Ambo"
        symlinked.folder = "/private/tmp/Ambo/.claude/worktrees/x"
        #expect(PairCompare.removable(symlinked), "a project under a symlinked folder")
        var gone = codex
        gone.discarded = true
        #expect(!PairCompare.canKeep(claude, sides: [claude, gone]), "already removed")
        #expect(PairCompare.partner(of: claude, runs: [claude, gone]) == nil, "nothing left to compare with")
        #expect(PairCompare.removalWarning(codex).contains("cb/export-codex"))
    }

    @Test func aVariantIsMergedOnlyWhenItFinishedWellAndIsStillThere() {
        let claude = run("a", .succeeded), codex = run("b", .succeeded, agent: CodexExec.agent)
        #expect(PairCompare.canMerge(claude, sides: [claude, codex], target: "main"))
        #expect(!PairCompare.canMerge(claude, sides: [claude, codex], target: nil), "the project's branch is not known")
        #expect(!PairCompare.canMerge(claude, sides: [claude, codex], target: "cb/export-claude"), "not into itself")
        #expect(!PairCompare.canMerge(claude, sides: [claude, run("b", .running, agent: CodexExec.agent)], target: "main"))
        #expect(!PairCompare.canMerge(run("a", .failed), sides: [run("a", .failed), codex], target: "main"))
        var gone = claude
        gone.discarded = true
        var merged = claude
        merged.mergedInto = "main"
        #expect(!PairCompare.canMerge(gone, sides: [gone, codex], target: "main") && !PairCompare.canMerge(merged, sides: [merged, codex], target: "main"))
        #expect(PairCompare.canMerge(codex, sides: [gone, codex], target: "main"), "the kept one after the other was removed")
        #expect(PairCompare.mergeWarning(codex, target: "main").contains("cb/export-codex"))
    }

    @Test func aMergedVariantCanBeTidiedOnce() {
        var merged = run("a", .succeeded)
        #expect(!PairCompare.canTidy(merged), "not before it is merged")
        merged.mergedInto = "main"
        #expect(PairCompare.canTidy(merged))
        #expect(PairCompare.tidyWarning(merged).contains("cb/export-claude") && PairCompare.tidyWarning(merged).contains("main"))
        var project = merged
        project.folder = "/P/Ambo"
        #expect(!PairCompare.canTidy(project), "only the app's own worktree")
        merged.discarded = true
        #expect(!PairCompare.canTidy(merged), "already removed")
    }
}
