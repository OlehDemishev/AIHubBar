# ClaudePult

Native macOS menu bar app (no Dock icon): a control panel for the projects in `~/Projects` and for Claude Code sessions. Full specification: [docs/SPEC.md](docs/SPEC.md). Progress: [docs/STATUS.md](docs/STATUS.md). Design decisions: [DECISIONS.md](DECISIONS.md).

Current stage: **6 — common commands and disk**. On top of the panel, the **Сессии** block lists every Claude Code session on this Mac (Terminal, Claude desktop app, background runs): project, worktree, task, duration and state — работает / в фоне / ждёт ответа / готово / ошибка / завершена. Waiting sessions are highlighted, raise a macOS notification once and are counted next to the menu bar icon; «Показать» brings the session's Terminal tab forward (desktop-app sessions open Claude, others the folder); background runs have «Журнал» and «Остановить». Session data comes from Claude Code hooks that ClaudePult installs into `~/.claude/settings.json` (Settings → «Сессии Claude Code»).

Each Claude command asks where to run — **Терминал** or **Фон** — unless a default is set in Settings («Запомнить выбор»).

Below the sessions, the projects from `~/Projects` with health, branch, uncommitted files, open PRs (coloured by CI) and last activity. A project expands into:

- **Claude** commands — «Следующий шаг», «Своя задача…» (text field), «Завершить» with the prompt from docs/SPEC.md §2.4: in **Терминал** mode a new Terminal window starts `claude` with the prompt as the first message; in **Фон** mode `claude -p` runs without a window (see below). If a Claude Code session already runs in the project folder, «Следующий шаг» and «Своя задача» start in a new worktree `.claude/worktrees/cb-<slug>` on branch `claude/<slug>` from `origin/main`; «Завершить» asks before starting a second session in the same folder.
- «Терминал / Finder / GitHub» buttons;
- the STATUS.md header (Stage / Now / Next / Needs Oleh), attention items and open PRs;
- the project's worktrees with a delete button (only when clean and pushed or merged).

Below the projects, **Команды** (spec §2.5) run the `_daily-report` tools without blocking the panel, with a spinner, a result line and a macOS notification: «Отчёт сейчас» (`report.py --since-hours 24 --no-open`, AI summary, Telegram), «Быстрая сводка» (`--no-ai --no-document --no-open --since-hours 24`), «Последний отчёт» (opens `reports/latest.html`), «Очистка: проверить» (`cleanup.py --dry-run`, output in a window) and «Очистка: выполнить» (`cleanup.py --now`, after a confirmation). The free disk space from the report is shown next to them, highlighted below 20 GB.

The menu bar icon gets a red dot when any project's health is red and the number of sessions waiting for an answer. The first Claude launch makes macOS ask for permission to control Terminal (System Settings → Privacy & Security → Automation).

Project data comes from `~/Projects/_daily-report/report.py --json` (the git/STATUS logic lives there, not in Swift). Refresh: at launch, when the panel opens and the data is older than 60 s, every 5 min in the background (`--no-fetch`), every 30 min with `git fetch`, and with ⌘R / the ↻ button in the panel.

## Requirements

- macOS 14 or newer (developed on macOS 27, Apple Silicon)
- Xcode with Swift 6 (developed with Xcode 27.1)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and install

```bash
scripts/build-and-install.sh
```

Generates `ClaudePult.xcodeproj` from `project.yml`, builds Release, installs to `~/Applications/ClaudePult.app` (replacing the old copy) and relaunches the app. Options:

- `--test` — run unit tests before building
- `--no-launch` — install without launching

The app is signed ad-hoc; no Apple Developer account is needed.

## Development

```bash
xcodegen generate
xcodebuild test -project ClaudePult.xcodeproj -scheme ClaudePult -destination 'platform=macOS,arch=arm64'
```

`ClaudePult.xcodeproj` and `ClaudePult/Info.plist` are generated from `project.yml` and are not committed — edit `project.yml` instead.

Layout:

- `ClaudePult/App` — app entry point, command-line mode
- `ClaudePult/Models` — `report.py --json` models (tolerant decoding), formatting helpers
- `ClaudePult/Services` — processes, report loading, project store, settings, log, login item
- `ClaudePult/Views` — SwiftUI views (menu panel, project rows, menu bar icon, settings)
- `ClaudePultTests` — Swift Testing unit tests

## Settings

«Настройки…» (⌘,): start at login, projects folder (default `~/Projects`), `_daily-report` folder (default `~/Projects/_daily-report`), path to `claude` (empty = auto-detect in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.claude/local`), launch mode (ask / Терминал / Фон), background time limit, Telegram for background results, session hooks, app log location.

## Background mode

`claude -p "<prompt>" --session-id <run id> --output-format stream-json --verbose --permission-mode dontAsk --permission-prompts none --settings '<rules>'` in the project folder (or a new worktree when the folder is busy). Everything not allowed is denied without asking:

- allowed: reading files, editing/writing inside the working folder, project checks and builds (npm, pnpm, npx, yarn, bun, node, tsc, mvn, gradle, xcodebuild, xcodegen, xcrun, swift, expo, pytest, make, `scripts/*`), `git status/diff/log/show/branch/add/commit/mv/rm/checkout -b/switch/fetch`, `git push origin <branch>` / `-u origin <branch>`, `gh pr create/view/list/checks/status`;
- denied: push to main/master or HEAD, bare `git push`, force/delete/mirror pushes, `git reset --hard`, `git clean`, deleting branches, `gh pr merge`, `gh api`, `sudo`, `rm`, reading `.env`, keys, `~/.ssh`, `_daily-report/config.json`, printing the environment.

The full rule set: `ClaudePult --background-settings`. The run's stream goes to `~/Library/Application Support/ClaudePult/runs/<id>.log` (metadata in `<id>.json`); «Журнал» shows it readably. Time limit 90 min by default (Settings), then SIGTERM. On finish: a macOS notification and, if enabled and `_daily-report/config.json` has `telegram.bot_token` / `chat_id`, a Telegram message «✅/❌ <Проект>: <начало задачи> — <итог>» with the PR link. A run keeps going if ClaudePult quits; the app picks it up again on start. Runs older than 30 days are deleted.

## Session hooks

«Установить hooks» in Settings (or `--hooks install`) writes `~/Library/Application Support/ClaudePult/hooks/claudepult-hook.py` and merges entries for `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `Notification`, `PostToolUse`, `Stop`, `StopFailure`, `SessionEnd` into `~/.claude/settings.json`; a backup `settings.json.claudepult-backup-<time>` is saved next to it first and other settings are left as they are. The hook stores one file per session in `~/Library/Application Support/ClaudePult/sessions/<session_id>.json` (state, cwd, project, first/last prompt up to 200 characters, Claude's pid and tty); it prints nothing and always exits 0, so it never changes what Claude does. «Снять hooks» removes only ClaudePult's entries. Claude Code picks up the change in running sessions by itself. Session files older than 7 days are deleted.

## Logs

`~/Library/Logs/ClaudePult/ClaudePult.log` (rotated at 1 MB to `ClaudePult.1.log`): app start, every `report.py` run with its duration, errors. No tokens or file contents are logged.

## Panel snapshot (development)

The app's windows are hidden from screen-capture automation, so the panel can save a picture of itself each time it opens:

```bash
defaults write com.demishev.claudepult DebugPanelSnapshot -bool YES
defaults write com.demishev.claudepult DebugPanelExpand Cantero   # optional: expand a project
```

The PNG goes to `~/Library/Logs/ClaudePult/panel.png` (plus the window frame in the log). It shows layout and text; colours are not reliable (some SwiftUI colour layers render white). Turn off with `defaults delete com.demishev.claudepult DebugPanelSnapshot`.

## Command line

The app binary accepts headless commands (used by scripts and checks; the UI is not started):

```bash
~/Applications/ClaudePult.app/Contents/MacOS/ClaudePult --login-item status
```

| Command | Effect |
|---|---|
| `--login-item status` | print login item state (`enabled`, `disabled`, `requiresApproval`) |
| `--login-item on` | register ClaudePult as a login item |
| `--login-item off` | unregister it |
| `--claude next <project>` | «Следующий шаг» in a new Terminal window (worktree if the folder is busy) |
| `--claude task <project> <text>` | «Своя задача» with the given text |
| `--claude finish <project>` | «Завершить сессию»; exits with 3 if the folder is busy |
| `--claude … --print` | print the command line instead of launching |
| `--claude … --claude-path <path>` | use another binary, e.g. `/bin/echo` for a dry run |
| `--claude … --background` | start as a background run; the running app reports the result |
| `--background-settings` | print the permission rules used for background runs |
| `--command report\|summary\|cleanup-check\|cleanup` | run a common command and print its result line |
| `--hooks status` | print hook state (`installed`, `outdated`, `notInstalled`) |
| `--hooks install` / `--hooks uninstall` | same as the Settings buttons (backup of settings.json first) |
| `--sessions` | list visible sessions: id, state, project, worktree, tty, task |
| `--show-session <id>` | bring the Terminal tab of a session forward («Показать») |
