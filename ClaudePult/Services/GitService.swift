import Foundation

enum GitError: LocalizedError {
    case failed(String, stderr: String)

    var errorDescription: String? {
        switch self {
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

    /// `git worktree remove` without `--force`: git itself refuses if anything is uncommitted.
    static func removeWorktree(_ worktreePath: String, projectPath: String) async throws {
        try await run(["worktree", "remove", worktreePath], in: projectPath)
        AppLog.info("Removed worktree \(worktreePath)")
    }
}
