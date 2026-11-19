import Foundation

enum GitError: LocalizedError {
    case failed(String, stderr: String)
    /// A step the app refused to take, in the person's words.
    case refused(String)

    var errorDescription: String? {
        switch self {
        case let .refused(reason):
            return reason
        case let .failed(command, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? String(localized: "git \(command) завершился с ошибкой") : "git \(command): \(detail)"
        }
    }
}

/// Whether a worktree may be removed: no uncommitted changes and its branch pushed (or merged into the base).
enum WorktreeRemoval: Equatable, Sendable {
    case allowed
    case blocked(String)
}

enum GitService {
    static let git = "/usr/bin/git"

    @discardableResult
    static func run(_ arguments: [String], in directory: String, timeout: Duration = .seconds(60)) async throws -> String {
        let result = try await ProcessRunner.run(git, ["-C", directory] + arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw GitError.failed(arguments.first ?? "", stderr: result.stderrText)
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    static func localBranches(in repo: String) async throws -> Set<String> {
        let output = try await run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repo)
        return Set(output.split(separator: "\n").map(String.init))
    }

    /// Splits `origin/main` into remote and branch for `git fetch`.
    static func remoteAndBranch(_ ref: String) -> (remote: String, branch: String)? {
        guard let slash = ref.firstIndex(of: "/") else { return nil }
        let remote = String(ref[..<slash]), branch = String(ref[ref.index(after: slash)...])
        return remote.isEmpty || branch.isEmpty ? nil : (remote, branch)
    }

    /// Creates `<project>/.claude/worktrees/cb-<slug>` on a new branch from `baseRef` (fetched first).
    static func createWorktree(projectPath: String, nameSource: String, baseRef: String) async throws -> WorktreePlan {
        if let (remote, branch) = remoteAndBranch(baseRef) {
            do {
                try await run(["fetch", remote, branch], in: projectPath, timeout: .seconds(120))
            } catch {
                // Offline: the last fetched state of the base branch is still a valid start.
                AppLog.error("git fetch before worktree failed, using local \(baseRef): \(error.localizedDescription)")
            }
        }
        let branches = try await localBranches(in: projectPath)
        let plan = WorktreePlan.make(projectPath: projectPath, from: nameSource) { path, branch in
            FileManager.default.fileExists(atPath: path) || branches.contains(branch)
        }
        try await run(["worktree", "add", "-b", plan.branch, plan.path, baseRef], in: projectPath)
        AppLog.info("Created worktree \(plan.path) on \(plan.branch) from \(baseRef)")
        return plan
    }

    static func removalCheck(worktreePath: String, baseRef: String) async -> WorktreeRemoval {
        guard FileManager.default.fileExists(atPath: worktreePath) else {
            return .blocked(String(localized: "Папки worktree нет — выполните `git worktree prune` в проекте."))
        }
        do {
            let status = try await run(["status", "--porcelain"], in: worktreePath)
            if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .blocked(String(localized: "В worktree есть незакоммиченные изменения."))
            }
            // Merged into the base branch: nothing would be lost.
            if (try? await run(["merge-base", "--is-ancestor", "HEAD", baseRef], in: worktreePath)) != nil {
                return .allowed
            }
            guard let ahead = try? await run(["rev-list", "--count", "@{upstream}..HEAD"], in: worktreePath) else {
                return .blocked(String(localized: "Ветка worktree не запушена."))
            }
            return Int(ahead.trimmingCharacters(in: .whitespacesAndNewlines)) == 0
                ? .allowed
                : .blocked(String(localized: "В ветке worktree есть незапушенные коммиты."))
        } catch {
            return .blocked(error.localizedDescription)
        }
    }

    /// The variant of a pair the person chose not to keep (`PairCompare`): the worktree goes with whatever is in it,
    /// and its branch with it. Asked for and confirmed by the person; nothing else in the app removes with `--force`.
    static func discardWorktree(_ worktreePath: String, branch: String, projectPath: String) async throws {
        if FileManager.default.fileExists(atPath: worktreePath) {
            try await run(["worktree", "remove", "--force", worktreePath], in: projectPath)
        } else {
            try await run(["worktree", "prune"], in: projectPath)
        }
        try await run(["branch", "-D", branch], in: projectPath)
        AppLog.info("Discarded worktree \(worktreePath) and branch \(branch)")
    }

    /// The branch the project's own folder is on; nil for a detached HEAD or outside a repository.
    static func currentBranch(in projectPath: String) async -> String? {
        let name = (try? await run(["rev-parse", "--abbrev-ref", "HEAD"], in: projectPath, timeout: .seconds(10)))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false && name != "HEAD" ? name : nil
    }

    /// The kept variant of a pair goes into the branch the project's folder is on: a local `git merge --no-ff`, no
    /// push. Refused while that folder has uncommitted changes to tracked files; a merge that stops on conflicts is
    /// taken back (`merge --abort`), so the folder is left as it was.
    static func mergeBranch(_ branch: String, into target: String, projectPath: String) async throws {
        guard await currentBranch(in: projectPath) == target else {
            throw GitError.refused(String(localized: "Папка проекта уже на другой ветке — откройте сравнение заново."))
        }
        let status = try await run(["status", "--porcelain", "--untracked-files=no"], in: projectPath)
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.refused(String(localized: "В папке проекта есть незакоммиченные изменения — сначала закоммитьте или уберите их."))
        }
        do {
            try await run(["merge", "--no-ff", "--no-edit", branch], in: projectPath, timeout: .seconds(120))
        } catch {
            _ = try? await run(["merge", "--abort"], in: projectPath)
            throw GitError.refused(String(localized: "Слияние остановилось на конфликтах и отменено: влейте ветку \(branch) вручную."))
        }
        AppLog.info("Merged \(branch) into \(target) in \(projectPath)")
    }

    /// `git worktree remove` without `--force`: git itself refuses if anything is uncommitted.
    static func removeWorktree(_ worktreePath: String, projectPath: String) async throws {
        try await run(["worktree", "remove", worktreePath], in: projectPath)
        AppLog.info("Removed worktree \(worktreePath)")
    }
}
