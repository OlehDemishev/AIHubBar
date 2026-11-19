import Foundation

/// «Сравнение» of a pair («одна задача двум», `TwoServices`): what each service changed in its own worktree, side by
/// side, and the files both of them touched.
enum PairCompare {
    /// The other run of the pair; nil for a run outside a pair or while the partner's record is gone.
    static func partner(of run: BackgroundRun, runs: [BackgroundRun]) -> BackgroundRun? {
        guard let pair = run.pair, run.reviewOf == nil else { return nil }
        guard run.discarded != true else { return nil }
        return runs.first { $0.pair == pair && $0.id != run.id && $0.reviewOf == nil && $0.discarded != true }
    }

    /// «Оставить этот вариант» can be offered for `keep`: both have finished, the other one is still there and its
    /// folder is a worktree the app made inside the project — nothing else is ever removed by this.
    static func canKeep(_ keep: BackgroundRun, sides: [BackgroundRun]) -> Bool {
        guard sides.count == 2, sides.allSatisfy(\.state.isFinished), sides.allSatisfy({ $0.discarded != true }),
              let other = sides.first(where: { $0.id != keep.id }), sides.contains(where: { $0.id == keep.id }) else { return false }
        return removable(other)
    }

    /// Only a worktree under `<project>/.claude/worktrees/` on a branch of its own.
    static func removable(_ run: BackgroundRun) -> Bool {
        let root = (run.projectPath as NSString).appendingPathComponent(".claude/worktrees") + "/"
        let folder = (run.folder as NSString).standardizingPath
        return folder.hasPrefix(root) && folder.count > root.count && !folder.dropFirst(root.count).contains("/")
            && run.worktreeBranch?.isEmpty == false
    }

    /// What the confirmation says before a variant is removed.
    static func removalWarning(_ run: BackgroundRun) -> String {
        String(localized: "Вариант «\(run.agentTitle)» будет удалён: папка \((run.folder as NSString).lastPathComponent) и ветка \(run.worktreeBranch ?? ""). Его изменения пропадут, отменить нельзя.")
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

    /// One line of a `git diff`, for colouring.
    struct DiffLine: Equatable, Identifiable, Sendable {
        enum Kind: Equatable, Sendable { case file, hunk, added, removed, context }
        var id: Int
        var kind: Kind
        var text: String
    }

    /// A long diff is cut here: the window is for a look, the whole thing is in a terminal.
    static let diffLimit = 1500

    /// `git diff` output as lines to show: the «diff --git», «index», «---», «+++» lines become one file line.
    static func diffLines(_ text: String, limit: Int = diffLimit) -> (lines: [DiffLine], cut: Bool) {
        var lines: [DiffLine] = []
        var cut = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let kind: DiffLine.Kind
            if line.hasPrefix("diff --git ") {
                // «diff --git a/x b/x» → «x»
                let path = line.range(of: " b/").map { String(line[$0.upperBound...]) } ?? line
                lines.append(DiffLine(id: lines.count, kind: .file, text: path))
                continue
            } else if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                        || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") || line.hasPrefix("similarity index")
                        || line.hasPrefix("rename ") || line.hasPrefix("old mode") || line.hasPrefix("new mode") {
                continue
            } else if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            if lines.count >= limit { cut = true; break }
            lines.append(DiffLine(id: lines.count, kind: kind, text: line))
        }
        while lines.last?.kind == .context, lines.last?.text.isEmpty == true { lines.removeLast() }
        return (lines, cut)
    }

    /// What one side changed in `path` since its run started; a new, untracked file is shown whole as added lines.
    static func fileDiff(_ run: BackgroundRun, path: String) async -> String {
        let base = await SessionChangesStore.base(folder: run.folder, since: run.startedAt)
        let tracked = (try? await GitService.run(["diff", base, "--", path], in: run.folder, timeout: .seconds(20))) ?? ""
        if !tracked.isEmpty { return tracked }
        let url = URL(fileURLWithPath: run.folder).appending(path: path)
        guard let data = try? Data(contentsOf: url), data.count < 400_000, let text = String(data: data, encoding: .utf8) else { return "" }
        return "diff --git a/\(path) b/\(path)\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
    }

    /// The second side against the first, branch against branch: what is committed on both.
    static func betweenDiff(_ sides: [BackgroundRun]) async -> String {
        let branches = sides.compactMap(\.worktreeBranch)
        guard branches.count == 2 else { return "" }
        return (try? await GitService.run(["diff", branches[0], branches[1]], in: sides[0].projectPath, timeout: .seconds(30))) ?? ""
    }
}
