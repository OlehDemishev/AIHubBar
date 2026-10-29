# Status

<!-- summary:start -->
**Stage:** Stage 6 of 8 done — projects, Claude in Terminal and background, sessions, common commands
**Updated:** 2026-10-29

**Now:**
- nothing in progress

**Next:**
- Stage 7 — Polish: Help window + help.txt, manual run of all scenarios, README update, app icon
- Stage 8 — Subscription limits (spec 2.8): limits in menu bar and panel, notifications, forecast, per-project token breakdown, background-mode guard, `usage.json`, widgets if simple

**Needs Oleh:**
- free disk space is 15.7 GB (< 20 GB) — run «Очистка: выполнить» when no build is running (my live run was skipped by cleanup.py because a build was running)
- check that the Telegram test message «✅ repo: Тест ClaudePult…» arrived; try «Фон» on a real project
- hooks are installed in ~/.claude/settings.json (with your OK); backup of the original: ~/.claude/settings.json.claudepult-backup-20261029T192827
- check that the «Claude ждёт ответа» macOS notification arrives (allow notifications for ClaudePult if asked) — not visible to automation
- try «Своя задача…» on a real project (if macOS asks for permission to control Terminal, allow it)
- open the panel and check colours (dots, badges) and the Terminal / Finder / GitHub buttons — automation cannot see or click them
- delete or archive the old repo `OlehDemishev/ClaudeBar` (its code is now in `OlehDemishev/ClaudePult`)
- turn on «Запускать при входе в систему» in Settings if wanted — it is left off
<!-- summary:end -->

## 2026-10-29 — Stage 6: common commands and disk (branch `feat/common-commands`)

Done: «Команды» block under the projects — «Отчёт сейчас», «Быстрая сводка» (report.py with `--since-hours 24`), «Последний отчёт», «Очистка: проверить» (output in its own window), «Очистка: выполнить» (with confirmation); spinner, result line, macOS notification, no blocking. Free disk space from the report, orange below 20 GB. Telegram tokens filtered out of any output. CLI `--command`.
Checked: `scripts/build-and-install.sh --test` — 61 tests (100 cases) green incl. a fake `_daily-report` folder; no compiler warnings. Live via `--command` (with Oleh's OK): cleanup check → «Можно освободить: 18.9 ГБ · свободно на диске 15.7 ГБ»; quick summary → «Telegram: отправлено» in 14 s; full report with AI → «Telegram: отправлено» in 32 s, latest.html regenerated; cleanup run → skipped by cleanup.py because an xcodebuild of another project was running (now shown as not done). No app windows open on launch. CI not set up; checks run locally.
Left: the panel block and the cleanup window not seen (computer-use clicks on the menu bar keep failing); the real cleanup not executed (build running).

## 2026-10-29 — Stage 5: background mode (branch `feat/background`)

Done: «Фон» mode — `claude -p` with `--session-id`, stream-json log in `runs/<id>.log`, `--permission-mode dontAsk --permission-prompts none` and allow/deny rules per spec §2.4 (`BackgroundPermissions`, `--background-settings`). Time limit (90 min default) and «Остановить» via SIGTERM → SIGKILL; result from the stream: ✅/❌, 1–3 line summary, PR link, denied tools. macOS notification and Telegram message (bot from `_daily-report/config.json`, toggle in Settings). Runs survive an app restart and are picked up again. «Сессии» block joins hook sessions with runs (state «в фоне», «ошибка», «Журнал», «Остановить»); «Журнал» window renders the log. Commands ask «Терминал / Фон» with «Запомнить выбор»; Settings: default mode, time limit, Telegram. CLI `--claude … --background`. Shared `Notifier`.
Checked: `scripts/build-and-install.sh --test` — 55 tests (94 cases) green, no compiler warnings. Live: (1) real `claude -p` with the exact flags in a throwaway repo: 4 allowed actions ran, 9 forbidden ones were denied (push main, force push, Read/cat .env, rm, write outside, gh pr merge, sudo, reset --hard), origin main untouched; (2) fake claude with a 1-min limit → stopped by the limit (SIGTERM, then SIGKILL), state «лимит времени», notified; (3) fake success → summary and PR link parsed; (4) real background run through the app with Telegram on → «готово» in 18 s, joined with its hook session, Telegram API answered OK. Found and fixed: runs started from the command line were finished early (liveness checked the executable name). Test runs, sandbox and settings restored. CI not set up; checks run locally.
Left: the panel and «Журнал» window not seen this time (computer-use clicks on the menu bar failed repeatedly); the Telegram message itself and the notification banner are not visible to automation.

## 2026-10-29 — Stage 4: sessions (branch `feat/sessions`)

Done: hook script (Python, `~/Library/Application Support/ClaudePult/hooks/claudepult-hook.py`) for SessionStart, UserPromptSubmit, PermissionRequest, Notification, PostToolUse, Stop, StopFailure, SessionEnd → `sessions/<session_id>.json` (state, cwd, project, prompts, pid, tty); event names and fields checked in the hooks docs. Install/update/remove in Settings and `--hooks`, merged into ~/.claude/settings.json with a backup, idempotent. «Сессии» block on top of the panel: project, worktree, task, duration, state, waiting highlighted with the reason, «Показать» (Terminal tab by tty / Claude app / Finder). Waiting count next to the menu bar icon, macOS notification once per wait. Dead process → ended; stale after 2 h; ended visible 15 min; files deleted after 7 days. Hint in the panel when hooks are missing. CLI `--sessions`, `--show-session`. Child processes no longer inherit `CLAUDE_CODE_*`.
Checked: `scripts/build-and-install.sh --test` — 43 tests (82 cases) green incl. the real hook script fed with a full event sequence, garbage input (silent exit 0), settings merge/remove/backup on temp files and malformed settings left untouched; no compiler warnings. Live (hooks installed with Oleh's OK): this session's own events recorded (pid, desktop entrypoint); a real `claude` test session in a ClaudePult worktree recorded SessionStart → running → done with tty and Terminal; a PermissionRequest event fed to the installed hook → «ждёт ответа», badge «1» on the menu bar icon (screenshot) and the highlighted row in the panel snapshot; `--show-session` focused its Terminal tab; closing the window → SessionEnd → «завершена». Found and fixed: a second install within the same second overwrote the backup of the original settings (restored from a copy, now never overwritten); inherited `CLAUDE_CODE_*` variables. Test worktree removed. CI not set up; checks run locally.
Left: «ждёт ответа» from a real permission prompt not seen live (this Mac auto-approves edits, so the test session never asked); the macOS notification itself not visible to automation; background sessions and the «ошибка» state come with stage 5.

## 2026-10-29 — Stage 3: Claude in Terminal (branch `feat/terminal-launch`)

Done: «Claude» block in an expanded project — «Следующий шаг», «Своя задача…» (inline text field, ⌘↩), «Завершить» — opens a new Terminal window and starts `claude` with the spec prompt (osascript with the command as argv, `$'…'` shell quoting, single window when Terminal was not running). Busy folder = live Claude Code process with cwd in the project (ps + lsof); then next/task go to a new worktree `.claude/worktrees/cb-<slug>` on `claude/<slug>` from origin/main (fetched first) and the UI says so; finish asks to confirm. Worktree list with removal (clean + pushed/merged check, `git worktree remove`). Automation permission text and error with a link to System Settings. Settings: path to claude (auto-detect). CLI `--claude next|task|finish`. Actions moved to the top of the expanded project. Tests no longer write to the app log; CLI flushes the log.
Checked: `scripts/build-and-install.sh --test` — 27 tests (63 cases) green incl. zsh/bash round-trip of the quoting and real git worktree create/remove in temp repos; no compiler warnings. Live with `--claude-path /bin/echo`: a new Terminal window opened in a folder with a space and printed the task with both quote kinds and a newline intact; `--claude next` on ClaudePult (busy — this session) created worktree `cb-next-step` on `claude/next-step` and opened Terminal there; `--claude finish` on the busy folder asked to confirm (exit 3); after a rebuild no new permission prompt; with Terminal not running only one window opened. Panel snapshot shows the Claude block. Test worktree, branch and Terminal windows removed. CI not set up; checks run locally.
Left: not clicked in the real panel (automation cannot click the app's windows); a real `claude` session not started on purpose. Mode «Терминал / Фон» comes with stage 5.

## 2026-10-29 — Stage 2: projects (branch `feat/projects`)

Done: the panel lists projects from `report.py --json` (run via `/usr/bin/env python3` with Homebrew added to PATH): health dot, name, branch, uncommitted-files and open-PR badges (PR colour = worst CI), last activity. A row expands into the STATUS header (Stage / Now / Next / Needs Oleh, inline Markdown), attention items (Needs duplicates hidden), open PRs (open in browser) and Terminal / Finder / GitHub buttons. Refresh at launch, on panel open if older than 60 s, every 5 min without fetch, every 30 min with fetch, ⌘R / ↻; loading, error and empty states. Red dot on the menu bar icon when any project is red. Settings: projects folder and `_daily-report` folder. File log in ~/Library/Logs/ClaudePult. Debug panel snapshot (`DebugPanelSnapshot` default). Tests for report decoding (full, nulls, missing fields, unknown enums), attention dedupe, report arguments, relative time, remote → GitHub URL, PATH.
Checked: `scripts/build-and-install.sh --test` — 12 tests (34 cases) green, no compiler warnings, Release installed and running. Live: report.py loads 6 projects in ~6 s (log); red dot on the menu bar icon seen on a screenshot; panel snapshots show the list and an expanded project (Cantero) with STATUS, attention, PR and buttons; tests no longer start report.py. CI not set up; checks run locally.
Left: colours inside the panel and the Terminal/Finder/GitHub buttons not checked by a real click (the app's windows cannot be driven by automation); the 30-min fetch run not observed live. Claude commands come in stage 3.

## 2026-10-29 — Rename to ClaudePult (branch `chore/rename-to-claudepult`)

Done: code moved to the private repo `OlehDemishev/ClaudePult` (main pushed with full history); app, Xcode targets, source folders, bundle id (`com.demishev.claudepult`), build script, README, DECISIONS and SPEC renamed from ClaudeBar to ClaudePult; old `~/Applications/ClaudeBar.app` removed (its login item was off), `ClaudePult.app` installed. Project folder becomes `~/Projects/ClaudePult`. STATUS header updated with stage 8 (subscription limits) that was added to the spec.
Checked: `scripts/build-and-install.sh --test` — tests green, Release built, `~/Applications/ClaudePult.app` running with bundle id `com.demishev.claudepult`; menu bar icon present on a screenshot; `--login-item on` → `enabled`, `off` → `disabled`. CI not set up; checks run locally.
Left: older journal entries keep the old name by design. The old GitHub repo `OlehDemishev/ClaudeBar` still exists.

## 2026-10-29 — Panel entrance animations (branch `feat/panel-animations`)

Done: the panel's header, content and footer fade in and settle down from under the menu bar with a staggered spring (0.35 s, 50 ms step) on every open; the header sparkle bounces once; button hover highlight eases in. With Reduce Motion only the fade remains. The empty panel got a proper empty state («Пока пусто») instead of a single line.
Checked: `scripts/build-and-install.sh --test` — tests green, Release build installed and running; opened the panel twice from the menu bar and the log shows `Panel shown` both times, so the animation replays on each open. CI not set up; checks run locally.
Left: the animation itself not seen on a screenshot (the app's windows are hidden from computer-use screenshots) — needs Oleh's look.

## 2026-10-29 — Stage 1: skeleton (branch `main`)

Done: git repo and private GitHub repo `OlehDemishev/ClaudeBar`; `project.yml` (XcodeGen, macOS 14+, Swift 6, LSUIElement, no sandbox, ad-hoc signing); menu bar icon (SF Symbol `sparkle`) with a `.window` panel containing «Настройки…» and «Выход»; Settings window with the «Запускать при входе в систему» toggle via `SMAppService.mainApp`; headless `--login-item status|on|off`; `scripts/build-and-install.sh`; README, DECISIONS, this STATUS. First commit pushed straight to `main` (exception allowed by the spec).
Checked: `scripts/build-and-install.sh --test` — 3 Swift Testing tests green, Release build, installed to ~/Applications, app running. Menu bar icon seen on a screenshot, disappears when the app quits, icon highlights on click (the panel window itself is hidden from computer-use screenshots). Login item: `--login-item on` → `enabled`, `off` → `disabled`. CI not set up; all checks run locally.
Left: panel contents and Settings window not inspected visually (the app's windows are hidden from computer-use screenshots); actual start at login not tested (needs a re-login). Environment differs from the spec (macOS 27.2, Xcode 27.1) — see DECISIONS.md.
