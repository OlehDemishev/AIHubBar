import Foundation

/// «Сравнение» of a pair («одна задача двум», `TwoServices`): what each service changed in its own worktree, side by
/// side, and the files both of them touched.
enum PairCompare {
    /// The other run of the pair; nil for a run outside a pair or while the partner's record is gone.
    static func partner(of run: BackgroundRun, runs: [BackgroundRun]) -> BackgroundRun? {
        guard let pair = run.pair, run.reviewOf == nil else { return nil }
        return runs.first { $0.pair == pair && $0.id != run.id && $0.reviewOf == nil }
    }

    /// Both runs of a pair, Claude first; nil without two of them.
    static func sides(_ pair: String, runs: [BackgroundRun]) -> [BackgroundRun]? {
        let both = runs.filter { $0.pair == pair && $0.reviewOf == nil }.sorted { ($0.agent ?? "") < ($1.agent ?? "") }
        return both.count == 2 ? both : nil
    }

    /// Paths both sides changed: there the two answers really differ or really agree.
    static func common(_ first: SessionChanges?, _ second: SessionChanges?) -> Set<String> {
        Set(first?.files.map(\.path) ?? []).intersection(second?.files.map(\.path) ?? [])
    }

    /// «Claude Code (cb-export-claude): готово · файлов: 3 +120 −8» — the pair's notification line with the changes.
    static func line(_ run: BackgroundRun, changes: SessionChanges?) -> String {
        let line = TwoServices.lines([run])[0]
        guard let changes, !changes.isEmpty else { return line }
        return line + " · " + changes.summary
    }

    /// `git diff a b` for the two branches, to paste in a terminal in the project; nil without both branches.
    static func diffCommand(_ sides: [BackgroundRun]) -> String? {
        let branches = sides.compactMap(\.worktreeBranch)
        guard branches.count == 2 else { return nil }
        // The app's own branch names are plain slugs; anything else is quoted.
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        let words = branches.map { $0.unicodeScalars.allSatisfy(plain.contains) ? $0 : ShellQuote.quote($0) }
        return "git diff " + words.joined(separator: " ")
    }
}
