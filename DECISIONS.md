# Decisions

Decisions made where the spec is silent or does not match reality. Newest at the top.

## 2026-10-29 — Stage 3 (Claude in Terminal)

**Claude CLI.** `claude [prompt]` (2.1.312, `/opt/homebrew/bin/claude`) starts an interactive session with the prompt as the first message — no extra flags needed. The binary is found in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.claude/local` unless Settings give a path; the absolute path is typed into Terminal so the user's shell PATH does not matter.

**Prompts** are the spec's texts verbatim, also in a worktree. There the branch `claude/<slug>` already exists fresh from `origin/main`; if Claude makes another branch per the prompt, nothing is lost.

**Terminal via `osascript` with argv.** The command line is passed as an argument (`do script (item 1 of argv)`), not spliced into AppleScript source, so only shell quoting is needed. Shell quoting uses ANSI-C `$'…'` (zsh and bash): quotes, backslashes and newlines in Oleh's task survive and the typed line never contains a raw line break. Tested by round-tripping a nasty string through real `/bin/zsh` and `/bin/bash`. A fish login shell would not understand `$'…'` — not the case on this Mac. If Terminal is not running, the command goes into the window Terminal opens on launch instead of a second one. `osascript` runs async with a 180 s timeout (the first run waits for the permission prompt).

**Automation permission.** `NSAppleEventsUsageDescription` explains the prompt. Error -1743/-1744 shows a message with a button to System Settings → Automation. After a rebuild (new ad-hoc signature) macOS did not ask again (checked).

**Busy folder without hooks.** Hooks arrive in stage 4, so for now a folder is "busy" when a live Claude Code process (`claude` or `claude.exe`, from `ps`) has its working directory (`lsof -d cwd`) in the project or below it — except inside `.claude/worktrees/`. This also catches sessions started by hand and by the Claude desktop app. Stage 4 can combine it with hook data.

**Worktree naming.** `.claude/worktrees/cb-<slug>` (spec) on branch `claude/<slug>` — the prefix Claude Code already uses in these projects; a type prefix (`feat/`, `fix/`) cannot be guessed from free text. The slug comes from the task text, or for «Следующий шаг» from the first Next item: transliterated to Latin, lowercase words joined by `-`, at most 32 characters; `-2`, `-3`… if the folder or branch exists. `git fetch <remote> <branch>` runs first; if offline, the local `origin/main` is used.

**«Завершить сессию» never moves to a worktree** — it is about the work already in the folder. When the folder is busy it asks «Запустить всё равно».

**Worktree removal.** The first click checks: no uncommitted changes, and HEAD is merged into the base branch or its upstream has no unpushed commits; the second click runs `git worktree remove` (no `--force`, so git refuses anything dirty anyway). The branch is kept. Detached worktrees can only be removed when merged.

**Mode «Терминал / Фон».** Only Terminal exists until stage 5, so the commands launch directly; the mode question, its default in Settings and «Запомнить выбор» come with the background mode.

**Layout.** In an expanded project the actions (Claude commands, Terminal / Finder / GitHub) come first and STATUS below — with a long STATUS the buttons were below the fold.

**Command line** `--claude next|task|finish <project>` (with `--print` and `--claude-path`) runs the same launcher as the panel; used for checks with `/bin/echo` instead of `claude`, since the panel cannot be clicked by automation.

**Log.** Unit tests no longer write to the app log (they run inside the app); command-line mode flushes the log before exiting.

## 2026-10-29 — Stage 2 (projects)

**Running report.py.** `/usr/bin/env python3 report.py --json --projects-dir <folder> [--no-fetch]`, working directory `_daily-report`, like the script's own shebang. An app launched from Finder or at login gets only the system PATH, while report.py calls `git` and `gh` (Homebrew), so the child PATH is prefixed with `/opt/homebrew/bin`, `/opt/homebrew/sbin`, `/usr/local/bin`, `~/.local/bin`; `PYTHONIOENCODING=utf-8` for Cyrillic output. Timeouts: 90 s without fetch (a run takes ~6 s here), 300 s with fetch. `--projects-dir` is passed from Settings so the app does not depend on report.py's config.json default.

**Refresh schedule** per spec 2.2: at launch; on panel open if older than 60 s; every 5 min `--no-fetch`; every 30 min (counted from launch) with fetch. Only one run at a time — a request during a run is dropped. The unit-test host skips the background loop (`XCTestConfigurationFilePath`), so tests never run report.py.

**Tolerant decoding.** Every field except a project's `path` is optional; malformed array elements are skipped (a project without `path` is dropped), unknown `health`/`ci`/`level` values become `.unknown`. Dates accept ISO 8601 with or without fractional seconds (report.py emits microseconds). `open_prs: null` (no gh) is kept distinct from `[]`.

**Project order** is report.py's (alphabetical). A stable order is easier to scan than one that reshuffles by health or activity; the health dot and badges carry the urgency.

**Expanded project.** Shows Stage/Now/Next/Needs Oleh, then attention items. report.py repeats every Needs Oleh line as an attention item «нужно от вас: …»; those are hidden when the line is already shown above. STATUS items and attention texts are rendered as inline Markdown (`code`, bold, links). Open PRs are listed with CI colour and open in the browser. The three Claude buttons come in stage 3.

**Open in Terminal / Finder / GitHub** use `NSWorkspace` (Terminal opens a new window in the folder without AppleScript, so no Automation permission is needed yet). The GitHub URL is derived from `remote`: scp-style and `ssh://` remotes become `https://host/owner/repo`, `.git` and credentials are stripped; local remotes get no button.

**Menu bar red dot.** `MenuBarExtra` renders its label as a template image, which would turn a coloured dot monochrome. With a red project the label is a non-template `NSImage` drawn on demand: the sparkle in `labelColor` (follows the menu bar appearance) plus a `systemRed` dot. Without red projects it is the plain SF Symbol.

**Visual checks.** The app cannot be granted to computer-use tools and its windows are filtered out of screenshots, so a debug-only snapshot (`DebugPanelSnapshot` default, see README) renders the panel's layer tree to a PNG. Layout and text are reliable; colours are not (`CALayer.render(in:)` drops SwiftUI's colour layers). Colours were checked in code and on the real menu bar icon only.

**Logging.** `~/Library/Logs/ClaudePult/ClaudePult.log`, plain text, rotated at 1 MB; the same messages go to unified logging (subsystem `com.demishev.claudepult`).

## 2026-10-29 — Rename to ClaudePult

Oleh asked to rename everything from ClaudeBar to ClaudePult. Done in one go: GitHub repo (new `OlehDemishev/ClaudePult`, history kept), app and target names, bundle id `com.demishev.claudepult`, logger subsystem, paths in the spec (`~/Library/Application Support/ClaudePult`, `~/Library/Logs/ClaudePult`), the help.txt block title, and the project folder `~/Projects/ClaudePult`. The old bundle id had no saved data and its login item was off, so nothing needed migrating. Older STATUS journal entries keep the old name (journal entries are not rewritten).

## 2026-10-29 — Stage 1 (skeleton)

**Environment differs from the spec.** The spec says macOS 26; the machine runs macOS 27.2 with Xcode 27.1 (Swift 6.4, macOS 27.0 SDK). Nothing in stage 1 depends on this. The deployment target stays macOS 14 as specified.

**XcodeGen.** Was not installed; installed with `brew install xcodegen` (2.46.0). It works with Xcode 27.1, so the spec's approach is kept: `project.yml` is the source of truth, `ClaudePult.xcodeproj` and `ClaudePult/Info.plist` are generated and git-ignored.

**Signing.** The keychain has no code signing identities, so the app is signed ad-hoc (`CODE_SIGN_IDENTITY = "-"`, manual style, no team). `SMAppService.mainApp` registration works with an ad-hoc signature (checked). Hardened Runtime is off for now; App Sandbox is off as required by the spec. If Apple Events to Terminal (stage 3) need it, revisit together with the `com.apple.security.automation.apple-events` entitlement.

**Swift language mode.** `SWIFT_VERSION = 6.0` (Swift 6 language mode, complete concurrency checking) — the Swift 6.4 compiler builds it in that mode.

**Bundle identifier** `com.demishev.claudepult`, in line with the existing `com.demishev.projects-*` launchd agents.

**Menu bar icon.** SF Symbol `sparkle` (✦, a nod to Claude). The coloured health dot and the waiting-sessions badge from spec 2.1 come in stages 2 and 4.

**Login item states.** `SMAppService.mainApp.status` returns `.notFound` until the app has been registered once, not `.notRegistered`. Both are shown as "off". `.requiresApproval` is shown as "on" with a hint and a button that opens System Settings → Login Items.

**Command-line mode** (`ClaudePult --login-item status|on|off`). Added so the login item can be checked from a script: on macOS 27 menu bar items are drawn by the system `MenuBarAgent`, and the app (an `LSUIElement` agent) cannot be granted to computer-use tools, so its panel and Settings window cannot be driven from automation. The command goes through the same `LoginItemController` as the Settings toggle.

**Tests** use Swift Testing (`import Testing`) in a hosted unit-test bundle.

**Build script** builds with `-destination 'platform=macOS,arch=arm64'` (Apple Silicon only, avoids the "multiple matching destinations" warning) into `build/DerivedData` inside the project, so builds are reproducible and covered by the auto-cleanup of `build/`.
