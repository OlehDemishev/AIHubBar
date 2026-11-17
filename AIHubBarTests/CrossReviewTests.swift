import Foundation
import Testing
@testable import AIHubBar

/// One service reads what the other did (`CrossReview`).
struct CrossReviewTests {
    private func run(_ id: String, _ state: BackgroundRun.State = .succeeded, agent: String? = nil, reviewOf: String? = nil) -> BackgroundRun {
        BackgroundRun(
            id: id, project: "Ambo", projectPath: "/P/Ambo", folder: "/P/Ambo", worktreeBranch: nil,
            commandTitle: "Своя задача", task: "Add export", startedAt: .now, timeLimitMinutes: 90, pid: 1,
            state: state, notified: false, agent: agent, prompt: "Add export", reviewOf: reviewOf
        )
    }

    @Test func theOtherServiceReads() {
        #expect(CrossReview.reviewerIsCodex(run("a")), "Claude wrote, Codex reads")
        #expect(!CrossReview.reviewerIsCodex(run("a", agent: CodexExec.agent)), "Codex wrote, Claude reads")
    }

    @Test func aFinishedRunIsReviewedOnce() {
        let done = run("a")
        #expect(CrossReview.canReview(done, runs: [done]))
        #expect(!CrossReview.canReview(run("a", .failed), runs: []))
        #expect(!CrossReview.canReview(run("a", .running), runs: []))
        let review = run("b", .running, agent: CodexExec.agent, reviewOf: "a")
        #expect(!CrossReview.canReview(done, runs: [done, review]), "a review is already under way")
        #expect(!CrossReview.canReview(run("b", agent: CodexExec.agent, reviewOf: "a"), runs: []), "a review is not reviewed")
        #expect(CrossReview.canReview(done, runs: [done, run("b", .failed, agent: CodexExec.agent, reviewOf: "a")]), "a failed review can be asked again")
    }

    @Test func aReviewCanOnlyRead() throws {
        let codex = CodexExec.arguments(prompt: "p", gitDirectory: "/r/.git", readOnly: true)
        #expect(codex.contains("read-only") && !codex.contains("workspace-write") && !codex.contains("--add-dir"))

        let claude = BackgroundPermissions.arguments(prompt: "p", sessionID: "s", readOnly: true)
        let settings = try #require(claude.firstIndex(of: "--settings").map { claude[$0 + 1] })
        let permissions = try #require((JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])?["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String]), deny = try #require(permissions["deny"] as? [String])
        #expect(allow.contains("Read") && allow.contains("Bash(git diff *)"))
        #expect(!allow.contains { $0.hasPrefix("Edit") || $0.contains("commit") || $0.contains("push") })
        #expect(deny.contains("Edit") && deny.contains("Write") && deny.contains("Bash(rm *)"))

        let prompt = CrossReview.prompt(task: "Add export", author: "Codex")
        #expect(prompt.contains("Do not change") && prompt.contains("Codex") && prompt.hasSuffix("Add export"))
    }
}
