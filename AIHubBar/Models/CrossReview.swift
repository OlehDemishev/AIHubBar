import Foundation

/// «Проверка вторым сервисом»: after a background run one service did, the other reads the changes and says what is
/// wrong — Codex reads Claude's work, Claude reads Codex's. The review is a background run of its own that can only
/// read (Codex's `read-only` sandbox, Claude's `BackgroundPermissions.reviewRules`).
enum CrossReview {
    /// A finished run that changed something can be reviewed once; a review is not reviewed again.
    static func canReview(_ run: BackgroundRun, runs: [BackgroundRun]) -> Bool {
        run.state == .succeeded && run.reviewOf == nil && !runs.contains { $0.reviewOf == run.id && $0.state != .failed }
    }

    /// Who reads: the service that did not write. True — Codex.
    static func reviewerIsCodex(_ run: BackgroundRun) -> Bool { run.agent != CodexExec.agent }

    /// English, as it is read by the agent; the answer comes in the task's language.
    static func prompt(task: String, author: String) -> String {
        """
        Review the work another agent (\(author)) did in this folder. Do not change, create or delete any file and do \
        not commit: only read. Look at `git status`, `git diff` for uncommitted changes, and the branch's own commits \
        (`git log --oneline -15`, then `git show` or a diff against the branch it started from).

        Check against the task below: does the change do what was asked, are there bugs, broken edge cases, missing \
        tests, leftovers or unrelated edits? Start your answer with one line — «OK» if nothing must be fixed, else \
        «Fix: N» with the number of problems. Then list the problems, most serious first, each with file and line and \
        one sentence on what is wrong. Be brief; no praise. Answer in the language of the task.

        The task:
        \(task)
        """
    }
}
