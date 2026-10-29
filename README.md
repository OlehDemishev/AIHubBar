# ClaudePult

Native macOS menu bar app (no Dock icon): a control panel for the projects in `~/Projects` and for Claude Code sessions. Full specification: [docs/SPEC.md](docs/SPEC.md). Progress: [docs/STATUS.md](docs/STATUS.md). Design decisions: [DECISIONS.md](DECISIONS.md).

Current stage: **3 — launching Claude in Terminal**. The panel lists the projects from `~/Projects` with health, branch, uncommitted files, open PRs (coloured by CI) and last activity. A project expands into:

- **Claude** commands — «Следующий шаг», «Своя задача…» (text field), «Завершить»: each opens a new Terminal window in the project folder and starts `claude` with the prompt from docs/SPEC.md §2.4 as the first message. If a Claude Code session already runs in the project folder, «Следующий шаг» and «Своя задача» start in a new worktree `.claude/worktrees/cb-<slug>` on branch `claude/<slug>` from `origin/main`; «Завершить» asks before starting a second session in the same folder.
- «Терминал / Finder / GitHub» buttons;
- the STATUS.md header (Stage / Now / Next / Needs Oleh), attention items and open PRs;
- the project's worktrees with a delete button (only when clean and pushed or merged).

The menu bar icon gets a red dot when any project's health is red. The first Claude launch makes macOS ask for permission to control Terminal (System Settings → Privacy & Security → Automation).

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

«Настройки…» (⌘,): start at login, projects folder (default `~/Projects`), `_daily-report` folder (default `~/Projects/_daily-report`), path to `claude` (empty = auto-detect in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.claude/local`), app log location.

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
