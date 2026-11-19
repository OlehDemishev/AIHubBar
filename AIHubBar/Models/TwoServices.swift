import Foundation

/// «Одна задача двум сервисам»: Claude and Codex get the same task at the same time, each in its own worktree of the
/// project, so their changes do not meet and can be compared branch against branch.
enum TwoServices {
    /// The worktree names differ by the service: «claude-export», «codex-export». The service goes first: at the end
    /// a long task's name cut it off, and both branches looked alike (seen live 2026-11-19).
    static func nameSource(_ source: String, codex: Bool) -> String {
        "\(codex ? "codex" : "claude") \(source)"
    }

    /// The pair's runs once both have finished and the pair was not announced yet; nil while one still works.
    static func finishedPair(_ pair: String, runs: [BackgroundRun]) -> [BackgroundRun]? {
        let both = runs.filter { $0.pair == pair && $0.reviewOf == nil }
        guard both.count == 2, both.allSatisfy(\.state.isFinished) else { return nil }
        return both.sorted { ($0.agent ?? "") < ($1.agent ?? "") }
    }

    /// «Claude Code: готово — cb-export-claude» per run, for the notification that both are ready.
    static func lines(_ runs: [BackgroundRun]) -> [String] {
        runs.map { run in
            let folder = (run.folder as NSString).lastPathComponent
            let outcome = RunMessage.outcomeText(run).split(separator: "\n").first.map(String.init) ?? ""
            return "\(run.agentTitle) (\(run.worktreeBranch ?? folder)): \(outcome)"
        }
    }
}
