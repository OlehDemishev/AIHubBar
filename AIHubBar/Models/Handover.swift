import Foundation

/// A task handed from one service to another when the first is at its limit: «продолжить в Codex». The other agent
/// gets the same task and is told that work may already be there, so it reads the folder before it writes.
enum Handover {
    /// What the next agent is asked. English: it is read by the agent, and both Claude and Codex take it.
    static func prompt(task: String, from agent: String) -> String {
        """
        Another agent (\(agent)) started this task in this folder and stopped at its usage limit. Before changing anything, \
        look at what is already done: run `git status`, `git diff` and `git log -5 --oneline`. Keep that work and \
        finish the task; do not start over.

        The task:
        \(task)
        """
    }

    /// A Claude run can be handed over while it has not finished well and its task was kept.
    static func canHandOver(_ run: BackgroundRun) -> Bool {
        run.agent == nil && run.prompt?.isEmpty == false && (run.isPaused || run.state == .failed || run.state == .stopped)
    }
}
