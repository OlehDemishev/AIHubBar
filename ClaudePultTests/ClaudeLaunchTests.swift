import Foundation
import Testing
@testable import ClaudePult

struct ClaudeCommandTests {
    @Test func promptsMatchSpec() {
        #expect(ClaudeCommand.nextStep.prompt.hasPrefix("Прочитай только шапку docs/STATUS.md и последнюю запись журнала."))
        #expect(ClaudeCommand.nextStep.prompt.hasSuffix("запиши вопрос в поле Needs шапки STATUS.md и закончи."))
        #expect(ClaudeCommand.customTask("  Добавь экспорт в CSV\n").prompt(.workspace, rulesFile: "~/Code/CLAUDE.md")
            == "Задача: Добавь экспорт в CSV. Работай по правилам ~/Code/CLAUDE.md: отдельная ветка от origin/main, проверки, коммит, push, PR, запись в STATUS.md.")
        #expect(ClaudeCommand.finishSession.prompt(.workspace, rulesFile: "~/Code/CLAUDE.md").contains("по разделу \"Конец сессии\" из ~/Code/CLAUDE.md"))
        // No one's name or home folder is written into the prompts.
        for command in [ClaudeCommand.nextStep, .customTask("x"), .finishSession] {
            #expect(!command.prompt.contains("Олег") && !command.prompt.contains("~/Projects"))
        }
    }

    @Test func onlyFinishStaysInProjectFolder() {
        #expect(ClaudeCommand.nextStep.canUseWorktree)
        #expect(ClaudeCommand.customTask("x").canUseWorktree)
        #expect(!ClaudeCommand.finishSession.canUseWorktree)
    }

    @Test func nameSource() {
        #expect(ClaudeCommand.nextStep.nameSource(nextItems: ["Store submission", "Legal"]) == "Store submission")
        #expect(ClaudeCommand.nextStep.nameSource(nextItems: []) == "next step")
        #expect(ClaudeCommand.customTask("Fix login").nameSource(nextItems: ["other"]) == "Fix login")
    }
}

struct ShellQuoteTests {
    @Test(arguments: [
        ("plain", "$'plain'"),
        ("it's", "$'it\\'s'"),
        ("a\\b", "$'a\\\\b'"),
        ("line1\nline2", "$'line1\\nline2'"),
        ("say \"hi\" $HOME `x`", "$'say \"hi\" $HOME `x`'"),
    ] as [(String, String)])
    func quotes(input: String, expected: String) {
        #expect(ShellQuote.quote(input) == expected)
    }

    /// The quoted word must come back unchanged from a real shell (Terminal runs the user's zsh).
    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func roundTripsThroughShell(shell: String) async throws {
        let tricky = "Задача: «кавычки» \"двойные\" 'одинарные' \\ $HOME `date` $(id) !! * ?\nвторая строка\tтаб; rm -rf /tmp/nothing"
        let result = try await ProcessRunner.run(shell, ["-c", "printf %s \(ShellQuote.quote(tricky))"], timeout: .seconds(10))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == tricky)
    }

    @Test func commandLine() {
        #expect(ShellQuote.claudeCommandLine(folder: "/P/My App", claude: "/opt/homebrew/bin/claude", prompt: "Hi 'x'")
            == "cd $'/P/My App' && $'/opt/homebrew/bin/claude' $'Hi \\'x\\''")
    }

    @Test func terminalScriptTakesCommandAsArgument() {
        let args = TerminalLauncher.arguments(commandLine: "cd $'/x' && claude")
        #expect(args.last == "cd $'/x' && claude")
        #expect(args.filter { $0 == "-e" }.count == TerminalLauncher.script.count)
        #expect(args.contains("set commandLine to item 1 of argv"))
    }
}

struct WorktreePlanTests {
    @Test(arguments: [
        ("Fix the Android release build!", "fix-the-android-release-build"),
        ("Store submission (listings and review notes are in `store/`)", "store-submission-listings-and"),
        ("Добавить экспорт в CSV", "dobavit-eksport-v-csv"),
        ("  ", "task"),
        ("Supercalifragilisticexpialidocious-and-more-words", "supercalifragilisticexpialidocio"),
    ] as [(String, String)])
    func slug(text: String, expected: String) {
        let slug = WorktreePlan.slug(from: text)
        #expect(slug == expected)
        #expect(slug.count <= WorktreePlan.maxSlugLength)
        #expect(slug.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
    }

    @Test func picksFreeName() {
        let taken: Set<String> = ["/P/.claude/worktrees/cb-fix-login", "claude/fix-login-2"]
        let plan = WorktreePlan.make(projectPath: "/P", from: "Fix login") { path, branch in
            taken.contains(path) || taken.contains(branch)
        }
        #expect(plan == WorktreePlan(slug: "fix-login-3", path: "/P/.claude/worktrees/cb-fix-login-3", branch: "claude/fix-login-3"))
    }
}

struct RunningSessionsTests {
    @Test func parsesPS() {
        let output = """
          123 /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
          456 /Users/me/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude
          789 /Applications/Claude.app/Contents/MacOS/Claude
         1011 /bin/zsh
         1213 /usr/local/bin/claude-helper
        """
        #expect(RunningSessions.claudePIDs(psOutput: output) == [123, 456])
    }

    @Test func parsesLsof() {
        #expect(RunningSessions.lsofDirectories("p1\nfcwd\nn/Users/me/Projects/A\np2\nfcwd\nn/Users/me/Projects/B c\n")
            == ["/Users/me/Projects/A", "/Users/me/Projects/B c"])
    }

    @Test(arguments: [
        (["/P/App"], true),
        (["/P/App/sub/dir"], true),
        (["/P/App/.claude/worktrees/cb-x"], false),
        (["/P/AppOther"], false),
        (["/P"], false),
        ([], false),
    ] as [([String], Bool)])
    func busy(cwds: [String], expected: Bool) {
        #expect(RunningSessions.isBusy(projectPath: "/P/App", workingDirectories: cwds) == expected)
        #expect(RunningSessions.isBusy(projectPath: "/P/App/", workingDirectories: cwds) == expected)
    }
}

/// Real git against throwaway repositories: a bare "origin" and a clone acting as the project.
struct GitServiceTests {
    private struct Sandbox {
        let root: URL
        var project: String { root.appending(path: "project").path }

        static func make() async throws -> Sandbox {
            let root = FileManager.default.temporaryDirectory.appending(path: "claudepult-git-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sandbox = Sandbox(root: root)
            let origin = root.appending(path: "origin.git").path
            try await sandbox.git(["init", "--bare", "-b", "main", origin], in: root.path)
            try await sandbox.git(["clone", origin, sandbox.project], in: root.path)
            try await sandbox.git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "init"], in: sandbox.project)
            try await sandbox.git(["push", "-u", "origin", "main"], in: sandbox.project)
            return sandbox
        }

        @discardableResult
        func git(_ args: [String], in dir: String) async throws -> String {
            let result = try await ProcessRunner.run(GitService.git, args, currentDirectory: URL(fileURLWithPath: dir), timeout: .seconds(30))
            #expect(result.exitCode == 0, "git \(args.joined(separator: " ")): \(result.stderrText)")
            return String(decoding: result.stdout, as: UTF8.self)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func createsWorktreesWithUniqueNames() async throws {
        let sandbox = try await Sandbox.make()
        defer { sandbox.cleanUp() }

        let first = try await GitService.createWorktree(projectPath: sandbox.project, nameSource: "Fix login", baseRef: "origin/main")
        #expect(first.branch == "claude/fix-login")
        #expect(first.path == sandbox.project + "/.claude/worktrees/cb-fix-login")
        let head = try await sandbox.git(["rev-parse", "--abbrev-ref", "HEAD"], in: first.path)
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "claude/fix-login")

        let second = try await GitService.createWorktree(projectPath: sandbox.project, nameSource: "Fix login", baseRef: "origin/main")
        #expect(second.branch == "claude/fix-login-2")
    }

    @Test func removalOnlyWhenCleanAndPushed() async throws {
        let sandbox = try await Sandbox.make()
        defer { sandbox.cleanUp() }
        let plan = try await GitService.createWorktree(projectPath: sandbox.project, nameSource: "Task", baseRef: "origin/main")

        // Same commit as origin/main: nothing to lose.
        #expect(await GitService.removalCheck(worktreePath: plan.path, baseRef: "origin/main") == .allowed)

        try "x".write(toFile: plan.path + "/file.txt", atomically: true, encoding: .utf8)
        guard case .blocked = await GitService.removalCheck(worktreePath: plan.path, baseRef: "origin/main") else {
            Issue.record("dirty worktree must be blocked"); return
        }

        try await sandbox.git(["add", "."], in: plan.path)
        try await sandbox.git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "work"], in: plan.path)
        guard case .blocked = await GitService.removalCheck(worktreePath: plan.path, baseRef: "origin/main") else {
            Issue.record("unpushed branch must be blocked"); return
        }

        try await sandbox.git(["push", "-u", "origin", plan.branch], in: plan.path)
        #expect(await GitService.removalCheck(worktreePath: plan.path, baseRef: "origin/main") == .allowed)

        try await GitService.removeWorktree(plan.path, projectPath: sandbox.project)
        #expect(!FileManager.default.fileExists(atPath: plan.path))
    }

    @Test func remoteAndBranch() {
        #expect(GitService.remoteAndBranch("origin/main")! == ("origin", "main"))
        #expect(GitService.remoteAndBranch("upstream/release/1.0")! == ("upstream", "release/1.0"))
        #expect(GitService.remoteAndBranch("main") == nil)
    }
}

struct ClaudeLocatorTests {
    /// A fake home folder with an executable `claude` at each of `paths` (relative to it).
    private func home(with paths: [String]) throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)").path
        for path in paths {
            let file = "\(home)/\(path)"
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        return home
    }

    /// Only files in the fake home count: this Mac's own `/opt/homebrew/bin/claude` must not answer.
    private func detect(_ home: String, shellPath: String?) -> String? {
        ClaudeLocator.detect(home: home, shellPath: shellPath) { $0.hasPrefix(home) && FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test func nothingInstalled() throws {
        let home = try home(with: [])
        #expect(detect(home, shellPath: nil) == nil)
    }

    @Test func findsNewestNvmVersion() throws {
        let home = try home(with: [".nvm/versions/node/v9.11.2/bin/claude", ".nvm/versions/node/v20.11.0/bin/claude"])
        #expect(detect(home, shellPath: nil) == "\(home)/.nvm/versions/node/v20.11.0/bin/claude")
    }

    @Test func findsDesktopAppCopy() throws {
        let copy = "Library/Application Support/Claude/claude-code/2.1.309/5af865b9901c/claude.app/Contents/MacOS/claude"
        let home = try home(with: [
            "Library/Application Support/Claude/claude-code/2.1.99/a93ded4b1b47/claude.app/Contents/MacOS/claude", copy,
        ])
        #expect(detect(home, shellPath: nil) == "\(home)/\(copy)")
    }

    @Test func orderOfPlaces() throws {
        let desktop = "Library/Application Support/Claude/claude-code/2.1.309/x/claude.app/Contents/MacOS/claude"
        let home = try home(with: [desktop, ".nvm/versions/node/v20.0.0/bin/claude", "shell/claude", ".local/bin/claude"])
        let shell = "\(home)/shell/claude"
        #expect(detect(home, shellPath: shell) == "\(home)/.local/bin/claude")
        try FileManager.default.removeItem(atPath: "\(home)/.local/bin/claude")
        #expect(detect(home, shellPath: shell) == shell)
        #expect(detect(home, shellPath: nil) == "\(home)/.nvm/versions/node/v20.0.0/bin/claude")
        // A shell answer that no longer exists is skipped.
        #expect(detect(home, shellPath: "\(home)/gone/claude") == "\(home)/.nvm/versions/node/v20.0.0/bin/claude")
    }

    @Test func shellOutput() {
        #expect(ClaudeLocator.shellPath(fromOutput: "/opt/homebrew/bin/claude\n") == "/opt/homebrew/bin/claude")
        #expect(ClaudeLocator.shellPath(fromOutput: "Welcome back!\n  /Users/a/.nvm/versions/node/v22.1.0/bin/claude  \n")
            == "/Users/a/.nvm/versions/node/v22.1.0/bin/claude")
        #expect(ClaudeLocator.shellPath(fromOutput: "alias claude=/Users/a/.claude/local/claude") == nil)
        #expect(ClaudeLocator.shellPath(fromOutput: "") == nil)
    }

    /// The real shell answers on this Mac (zsh with no greeting or with one: the path is still picked out).
    @Test func refreshAsksTheShell() async {
        await ClaudeLocator.refreshShellPath()
        if let path = ClaudeLocator.shellPath { #expect(FileManager.default.isExecutableFile(atPath: path)) }
    }
}
