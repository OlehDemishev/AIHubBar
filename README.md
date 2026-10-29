# ClaudePult

Native macOS menu bar app (no Dock icon): a control panel for the projects in `~/Projects` and for every Claude Code session on this Mac. Specification: [docs/SPEC.md](docs/SPEC.md). Progress: [docs/STATUS.md](docs/STATUS.md). Decisions: [DECISIONS.md](DECISIONS.md). What was checked how: [docs/CHECKLIST.md](docs/CHECKLIST.md). In the app: «Помощь».

## What it does

Click ✦ in the menu bar. Next to it: the subscription usage (5-hour session %, or session and week %, or a ring — green < 50 %, orange 50–80 %, red > 80 %), a red dot when a project's health is red and ✋ with the number of Claude sessions waiting for an answer.

**Лимиты** (top of the panel) — the 5-hour session with a countdown to the reset and a forecast from the last 30 minutes («хватит до ~16:40» / «до сброса хватит»), the week, per-model weeks, extra usage if enabled; «Расход по проектам» estimates each project's share and the heaviest session for the session / today / week from Claude Code's transcripts. Notifications once per window at 50/80/95 % (configurable) and when a limit is restored, optionally to Telegram. A background run while the session is above 90 % asks: start now or after the reset. Data from the same endpoint Claude Code uses (OAuth token read from the Keychain item «Claude Code-credentials», never stored); current values are written to `~/Library/Application Support/ClaudePult/usage.json` (`five_hour`, `seven_day`, `updated`) for report.py and the bot.

**Сессии** (top of the panel, from Claude Code hooks) — every session on this Mac: Terminal, Claude desktop app, background runs. Project, worktree, task, duration, state (работает / в фоне / ждёт ответа / готово / ошибка / завершена). Waiting sessions are highlighted and notify once. «Показать» brings the session's Terminal tab forward (desktop-app sessions open Claude, others the folder); background runs have «Журнал» and «Остановить».

**Проекты** — from `~/Projects/_daily-report/report.py --json`: health, branch, uncommitted files, open PRs coloured by CI, last activity. A project expands into:

- **Claude**: «Следующий шаг» (first Next item), «Своя задача…», «Завершить» — prompts from spec §2.4. Each asks **Терминал** (new Terminal window with `claude "<prompt>"`) or **Фон** (`claude -p`, see below), or uses the default from Settings («Запомнить выбор»). If Claude already works in the project folder, the new task starts in a worktree `.claude/worktrees/cb-<slug>` on branch `claude/<slug>` from `origin/main`; «Завершить» asks before a second session in the same folder.
- «Терминал / Finder / GitHub».
- The STATUS.md header (Stage / Now / Next / Needs Oleh), attention items, open PRs.
- Worktrees with a delete button (only when clean and pushed or merged).

Data refreshes at launch, on panel open when older than 60 s, every 5 min (`--no-fetch`), every 30 min with `git fetch`, and with ⌘R.

**Команды** — through the `_daily-report` tools, with a spinner, a result line and a notification: «Отчёт сейчас» (AI report for 24 h to Telegram), «Быстрая сводка» (no AI), «Последний отчёт» (`reports/latest.html`), «Очистка: проверить» (`cleanup.py --dry-run`, output in a window), «Очистка: выполнить» (`cleanup.py --now`, after a confirmation). Free disk space next to them, orange below 20 GB.

## Install

Requirements: macOS 14+ (developed on macOS 27, Apple Silicon), Xcode with Swift 6 (developed with 27.1), `brew install xcodegen`.

```bash
scripts/build-and-install.sh
```

Generates `ClaudePult.xcodeproj` from `project.yml`, builds Release, installs `~/Applications/ClaudePult.app` and relaunches it. `--test` runs the unit tests first, `--no-launch` only installs. Signed ad-hoc; no Apple Developer account needed.

First steps after installing:

1. «Настройки…» → «Сессии Claude Code» → «Установить hooks» (adds ClaudePult's hook to `~/.claude/settings.json`, backup saved next to it).
2. Optionally «Запускать при входе в систему».
3. The first «Терминал» launch makes macOS ask to let ClaudePult control Terminal — allow it; notifications — allow them.
4. For the limits, macOS may ask whether `security` may read «Claude Code-credentials» — «Always Allow».

## Settings

«Настройки…» (⌘,), one tab per area:

- **Основные** — start at login, projects folder, `_daily-report` folder, version, app log.
- **Внешний вид** — theme (system / light / dark, also for ClaudePult's windows), text size (small / normal / large / extra large; the panel widens with it), panel width, row density, opening animation, which blocks to show (Лимиты, Сессии, Проекты, Команды), what the menu bar shows next to the icon, «Сбросить внешний вид».
- **Claude** — path to `claude` (empty = auto-detect), launch mode (ask / Терминал / Фон), background time limit, background results in Telegram.
- **Сессии** — install / update / remove the session hooks.
- **Лимиты** — notification thresholds, limit alerts to Telegram.

## Background mode

`claude -p "<prompt>" --session-id <run id> --output-format stream-json --verbose --permission-mode dontAsk --permission-prompts none --settings '<rules>'` in the project folder or a new worktree. Anything not allowed is denied without asking:

- allowed: reading files, editing/writing inside the working folder, project checks and builds (npm, pnpm, npx, yarn, bun, node, tsc, mvn, gradle, xcodebuild, xcodegen, xcrun, swift, expo, pytest, make, `scripts/*`), `git status/diff/log/show/branch/add/commit/mv/rm/checkout -b/switch/fetch`, `git push origin <branch>` / `-u origin <branch>`, `gh pr create/view/list/checks/status`;
- denied: push to main/master or HEAD, bare `git push`, force/delete/mirror pushes, `git reset --hard`, `git clean`, deleting branches, `gh pr merge`, `gh api`, `sudo`, `rm`, reading `.env`, keys, `~/.ssh`, `_daily-report/config.json`, printing the environment.

Full rule set: `ClaudePult --background-settings`. Log: `~/Library/Application Support/ClaudePult/runs/<id>.log`, shown readably by «Журнал». Time limit from Settings, then SIGTERM. On finish: a notification and, if enabled and `_daily-report/config.json` has the bot, a Telegram message «✅/❌ <Проект>: <начало задачи> — <итог>» with the PR link. A run keeps going if ClaudePult quits. Runs older than 30 days are deleted. Note: Bash rules are pattern matching, not a sandbox — see DECISIONS.md.

## Session hooks

The hook (`~/Library/Application Support/ClaudePult/hooks/claudepult-hook.py`) listens to `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `Notification`, `PostToolUse`, `Stop`, `StopFailure`, `SessionEnd` and writes one file per session to `~/Library/Application Support/ClaudePult/sessions/<session_id>.json` (state, cwd, project, first/last prompt up to 200 characters, Claude's pid and tty). It prints nothing and always exits 0, so it never changes what Claude does. «Снять hooks» removes only ClaudePult's entries. Session files older than 7 days are deleted.

## Command line

The app binary runs headless commands instead of the UI: `~/Applications/ClaudePult.app/Contents/MacOS/ClaudePult <command>`.

| Command | Effect |
|---|---|
| `--login-item status\|on\|off` | start at login |
| `--claude next\|finish <project>` · `--claude task <project> <text>` | Claude command in a new Terminal window (worktree if busy); `finish` exits 3 if the folder is busy |
| `--claude … --background` | as a background run; the running app reports the result |
| `--claude … --print` · `--claude-path <path>` | print the command line · use another binary (e.g. `/bin/echo`) |
| `--background-settings` | permission rules of background runs |
| `--command report\|summary\|cleanup-check\|cleanup` | run a common command here and print its result |
| `--app-command <command>\|help\|cleanup-output\|settings` | ask the running app to run a command or open a window |
| `--hooks status\|install\|uninstall` | session hooks |
| `--usage` · `--usage-raw` · `--token-usage` | subscription limits (raw response; the token is never printed) · per-project breakdown |
| `--sessions` · `--show-session <id>` | list sessions · bring a session's Terminal tab forward |

## Development

```bash
xcodegen generate
xcodebuild test -project ClaudePult.xcodeproj -scheme ClaudePult -destination 'platform=macOS,arch=arm64'
```

`ClaudePult.xcodeproj` and `ClaudePult/Info.plist` are generated from `project.yml` and not committed. The app icon is generated by `swift scripts/make-app-icon.swift`.

Layout: `ClaudePult/App` (entry point, command line), `Models` (report, sessions, runs, commands, formatting), `Services` (processes, stores, hooks, launcher, Telegram, settings, log), `Views` (panel, rows, sessions, commands, windows, settings, help), `Resources` (icon), `ClaudePultTests` (Swift Testing).

Logs: `~/Library/Logs/ClaudePult/ClaudePult.log` (rotated at 1 MB). No tokens or file contents are logged.

Panel snapshots for checks (the app's windows are hidden from screen-capture automation): `defaults write com.demishev.claudepult DebugPanelSnapshot -bool YES` saves `panel.png`, `help.png`, `cleanup.png` to the log folder whenever those windows show; `defaults write com.demishev.claudepult DebugPanelExpand <project>` expands a project. Layout and text are reliable, some colours are not. Turn off with `defaults delete com.demishev.claudepult DebugPanelSnapshot`.
