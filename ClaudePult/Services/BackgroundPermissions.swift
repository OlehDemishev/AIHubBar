import Foundation

/// Command line and permission rules for unattended `claude -p` runs (docs/SPEC.md §2.4, «Права в фоне»).
/// Rules follow code.claude.com/docs/en/permissions (checked 2026-10-29): `dontAsk` + `--permission-prompts none`
/// deny everything that is not allowed; deny rules win over allow rules from any settings level; each part of a
/// compound command (`&&`, `|`, `;`, `$()`) must be allowed, and deny rules match any part.
/// Bash rules are pattern matching, not a sandbox — see DECISIONS.md.
enum BackgroundPermissions {
    static func arguments(prompt: String, sessionID: String, profile: PermissionProfile = .code) -> [String] {
        [
            "-p", prompt,
            "--session-id", sessionID,
            "--output-format", "stream-json", "--verbose",
            "--permission-mode", "dontAsk",
            "--permission-prompts", "none",
            "--settings", settingsJSON(profile),
        ]
    }

    /// «Только файлы» (SPEC-modes §3): read, search and write inside the project folder; no shell, no network.
    /// «Файлы + поиск в интернете» adds web search and page fetching.
    static func rules(_ profile: PermissionProfile) -> (allow: [String], deny: [String]) {
        let files = ["Read", "Glob", "Grep", "Edit(./**)", "TodoWrite"]
        let secrets = deny.filter { $0.hasPrefix("Read(") }
        switch profile {
        case .code: return (allow, deny)
        case .filesOnly: return (files, ["Bash", "WebFetch", "WebSearch", "NotebookEdit"] + secrets)
        case .filesAndWeb: return (files + ["WebSearch", "WebFetch"], ["Bash", "NotebookEdit"] + secrets)
        }
    }

    static let allow: [String] = {
        var rules = [
            // Files: read anywhere in the working folder, edit/write only inside it (`Edit` rules also cover Write).
            "Read", "Glob", "Grep", "Edit(./**)", "TodoWrite",
            // Git, without anything that rewrites or discards history.
            "Bash(git status)", "Bash(git status *)", "Bash(git diff)", "Bash(git diff *)", "Bash(git log *)",
            "Bash(git show *)", "Bash(git branch)", "Bash(git branch *)", "Bash(git rev-parse *)",
            "Bash(git ls-files *)", "Bash(git merge-base *)", "Bash(git remote -v)", "Bash(git stash list)",
            "Bash(git add *)", "Bash(git commit *)", "Bash(git mv *)", "Bash(git rm *)",
            "Bash(git checkout -b *)", "Bash(git switch *)", "Bash(git fetch)", "Bash(git fetch *)",
            "Bash(git push origin *)", "Bash(git push -u origin *)", "Bash(git push --set-upstream origin *)",
            // GitHub: open and read pull requests.
            "Bash(gh pr create *)", "Bash(gh pr view *)", "Bash(gh pr view)", "Bash(gh pr list *)",
            "Bash(gh pr list)", "Bash(gh pr checks *)", "Bash(gh pr status)",
        ]
        // Project checks and builds.
        for tool in [
            "npm", "pnpm", "npx", "yarn", "bun", "bunx", "node", "tsc",
            "mvn", "./mvnw", "gradle", "./gradlew",
            "xcodebuild", "xcodegen", "xcrun", "swift", "expo",
            "pytest", "python3 -m pytest", "python -m pytest", "make",
            "./scripts/*", "scripts/*",
        ] {
            rules.append("Bash(\(tool) *)")
            if !tool.contains("*") { rules.append("Bash(\(tool))") }
        }
        return rules
    }()

    static let deny: [String] = [
        // Never push main/master, HEAD (could be main), the current branch implicitly, or with force/delete.
        "Bash(git push)", "Bash(git push origin)", "Bash(git push -u origin)", "Bash(git push --set-upstream origin)",
        "Bash(git push * main)", "Bash(git push * main *)", "Bash(git push *:main)", "Bash(git push *:main *)",
        "Bash(git push * master)", "Bash(git push * master *)", "Bash(git push *:master)", "Bash(git push *:master *)",
        "Bash(git push *HEAD*)", "Bash(git push *--force*)", "Bash(git push * -f)", "Bash(git push * -f *)",
        "Bash(git push -f *)", "Bash(git push *+*)", "Bash(git push *--delete*)", "Bash(git push * -d *)",
        "Bash(git push *--mirror*)", "Bash(git push *--all*)",
        "Bash(git reset --hard*)", "Bash(git reset * --hard*)", "Bash(git clean *)", "Bash(git checkout -- *)",
        "Bash(git branch -D *)", "Bash(git branch -d *)", "Bash(git branch --delete *)",
        "Bash(gh pr merge*)", "Bash(gh repo delete*)", "Bash(gh api *)",
        "Bash(sudo)", "Bash(sudo *)", "Bash(rm *)",
        // Secrets: file tools and read-only shell commands (those run without approval in every mode).
        "Read(**/.env)", "Read(**/.env.*)", "Read(**/*.pem)", "Read(**/*.key)", "Read(**/*.p12)",
        "Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(~/.config/gh/**)", "Read(~/.claude.json)",
        "Read(**/_daily-report/config.json)",
        "Bash(*.env*)", "Bash(*.pem*)", "Bash(*id_rsa*)", "Bash(*id_ed25519*)", "Bash(*_daily-report/config.json*)",
        "Bash(env)", "Bash(env *)", "Bash(printenv*)", "Bash(security *)",
    ]

    static func settingsJSON(_ profile: PermissionProfile = .code) -> String {
        let rules = rules(profile)
        let settings: [String: Any] = [
            "permissions": [
                "allow": rules.allow,
                "deny": rules.deny,
                "blockReadsOutsideWorkingDirectories": true,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
