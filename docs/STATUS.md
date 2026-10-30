# Status

<!-- summary:start -->
**Stage:** SPEC.md done; SPEC-modes stage 1 of 9 (mode model) done
**Updated:** 2026-10-30

**Now:**
- SPEC-modes §9 stage 2 (menu bar builder) — starting

**Next:**
- SPEC-modes §9: 2 menu bar builder, 3 AI services, 4 folder projects + commands, 5 calendar, 6 templates, 7 setup assistant, 8 for everyone, 9 languages (§13: en, es, pt-BR, fr, de, ja, id, ko, it, ar with RTL, pl, uk)
- Fix whatever Oleh finds in docs/CHECKLIST.md

**Needs Oleh:**
- try Settings → Режимы (duplicate the mode → switcher appears in the panel) and a double-click on a .claudepult file
- read and edit docs/TEMPLATES.md (template texts) before stage 6
- before stage 3: install Codex CLI and Gemini CLI and create API keys (OpenAI, Google, xAI, DeepSeek, Mistral) for live checks — Oleh offered to
- before stage 8: Apple Developer Program (Developer ID, notarization) for distributing ClaudePult; decide on the name (SPEC-modes §10.4)
- try the «Внешний вид» settings tab (theme, width, density not checked by eye)
- optional, in _daily-report (not changed by ClaudePult): report.py/bot.py could read `~/Library/Application Support/ClaudePult/usage.json` (`five_hour`, `seven_day`, `updated`) for a /limits bot command or a limits line in the report
- go through the «Oleh» rows of docs/CHECKLIST.md (buttons inside the panel, Settings, notifications, Telegram messages) — automation cannot click inside ClaudePult
- hooks are installed in ~/.claude/settings.json; backup of the original: ~/.claude/settings.json.claudepult-backup-20261029T192827
- delete or archive the old repo `OlehDemishev/ClaudeBar`; turn on start at login if wanted
<!-- summary:end -->

## 2026-10-30 — Usage endpoint backoff (branch `fix/usage-backoff`)

Done: HTTP 429 from the usage endpoint now pauses requests for 5 → 10 → 20 → 40 → 60 min (longer if `Retry-After` asks; its «0» is not trusted); the panel shows when the next try is and the refresh button waits. Active polling every 2 min instead of 1. Last snapshot cached in `usage-snapshot.json`, shown right after a restart; a restart within the active interval does not fetch.
Checked: `scripts/build-and-install.sh --test` — 94 tests (143 cases) green incl. Retry-After parsing and the backoff sequence; no compiler warnings. Live: the log showed the server answering 429 with `Retry-After: 0`; a fetch in between succeeded and was cached (session 3 %, week 64 %). With the fix installed: no 429 in the 7 minutes after, the next fetch succeeded (02:12) and refreshed the cache. CI not set up; checks run locally.
Left: the endpoint's real limit is unknown (undocumented).

## 2026-10-30 — Modes, stage 1 (branch `feat/modes`)

Done: mode model (`Mode`, blocks per SPEC-modes §3, tolerant JSON) and `ModeStore` (storage in Application Support, order, enabled, current; duplicate, delete, move); first start turns the current settings into the mode «Разработчик — Олег» (renamed from the neutral default «Разработчик (мой)»); the active mode is applied to the existing settings, so nothing changes for Oleh. Settings → «Режимы» tab (list with enable/order/duplicate/export/import/delete, editor for folders, launch mode, projects and common-commands blocks, later blocks marked «скоро»); folders, `_daily-report` and launch mode moved there from other tabs. Mode switcher at the top of the panel (2+ enabled modes). Export of all settings or one mode to `*.claudepult` (no secrets, `~` paths), import with «Заменить все настройки» / «Добавить режимы», double-click in Finder (UTI + document type). CLI `--modes`, `--export-settings`. Oleh's settings exported to `docs/modes/oleh-developer.claudepult`. Languages from Oleh added to SPEC-modes as §13 and stage 9.
Checked: `scripts/build-and-install.sh --test` — 92 tests (141 cases) green incl. migration, switching, export/replace on «another Mac», add-import, tolerant decoding; no compiler warnings. Live: after install `--modes` shows one mode, projects folder and launch mode unchanged; a temporary second mode was listed and removed again. The panel switcher could not be seen (menu bar clicks failed this time). CI not set up; checks run locally.
Left: the usage endpoint answered HTTP 429 — polling needs a backoff (next fix); switcher and import need Oleh's eye.

## 2026-10-30 — Spec: AI services, for everyone, settings export; template texts (branch `docs/spec-providers`)

Done: `docs/SPEC-modes.md` extended after Oleh's decisions: ClaudePult is for everyone (Oleh's setup becomes his own saved mode «Разработчик — Олег»; the built-in developer template uses a built-in git scanner instead of report.py); other AI services besides Claude (§11: agents — Codex CLI, Gemini CLI, Copilot CLI, Cursor CLI, custom; API models — OpenAI, Google, xAI, DeepSeek, Mistral, Anthropic, OpenAI-compatible incl. local; keys only in the Keychain; «Сравнить» runs one command with 2–3 services; limits/spend per service); settings export/import as `*.claudepult` files without secrets (§12); stages re-ordered (§9). New `docs/TEMPLATES.md`: how ClaudePult wraps a task for an agent or an API model, and the command texts of all built-in templates for Oleh to review.
Checked: docs only. Only Claude Code is installed on this Mac; other CLIs' flags and APIs are marked «verify against their docs» before stage 3.
Left: Oleh's review of TEMPLATES.md; installing other CLIs and API keys before stage 3.

## 2026-10-30 — Spec: modes, templates, setup assistant (branch `docs/spec-content`)

Done: after discussing with Oleh the texts-mode draft became `docs/SPEC-modes.md`: ClaudePult works in modes assembled from blocks (project source, card, stages, metrics, Claude commands, where to run, background permissions, calendar, panel blocks, common commands, menu bar additions); built-in templates «Разработчик (GitHub)» (current behaviour), «Видео», «Тексты», «Ресёрч», «Соцсети», «Свой»; a setup assistant that builds a mode block by block with a live preview; a mode switcher in the panel; a publishing calendar in the first wave (project dates, Markdown content plan, «Ближайшее», calendar window, reminders); a fully configurable menu bar (elements, formats, conditions, order, presets). Stages in §9.
Checked: docs only.
Left: Oleh's merge; open questions in §10.

## 2026-10-30 — Spec draft: texts mode, superseded (branch `docs/spec-content`)

Done: `docs/SPEC-content.md` — draft spec for people who write texts with Claude (video scripts, posts): what of ClaudePult already helps them (limits, background runs, queue, notifications), what must change (optional `_daily-report`/git, pluggable project sources, a mode setting), first version (folder projects with `проект.md`, stages, deadlines, word count and running time, task templates with results saved next to the source, narrower background permissions without Bash, hidden draft versions), later ideas (quick prompt from any app, batch tasks, publishing calendar), open questions and stages.
Checked: docs only; no code changed.
Left: Oleh's answers to §7 before any implementation.

## 2026-10-30 — Clickable notifications (branch `feat/notification-actions`)

Done: notifications carry a target and react to clicks — waiting session → its Terminal tab; background run → PR or «Журнал» (action buttons); report → latest.html; cleanup → output window; banners shown while the app is active. Found that notifications had never been shown (permission refused at the first prompt, the app cached the refusal silently): the permission is now checked before each notification, refusals are logged, the panel warns with «Включить…», Settings → Основные shows the state with «Разрешить» / «Открыть настройки» / «Проверить». CLI `--notifications-status`, `--app-command test-notification`.
Checked: `scripts/build-and-install.sh --test` — 86 tests (135 cases) green; no compiler warnings. Live: the log showed `UNErrorDomain 1`; Settings snapshot «выключены в macOS»; after Oleh enabled them `--notifications-status` → authorized; the test notification arrived and Oleh's click reached the app («Notification click: openWindow(id: "help")»). CI not set up; checks run locally.
Left: clicks on a real «ждёт ответа» / background-run notification not seen live (covered by routing tests).

## 2026-10-29 — Widgets (branch `feat/widgets`)

Done: WidgetKit extension `ClaudePultWidget` embedded in the app: «Лимиты Claude» small (session ring, reset countdown) and medium (session and week bars, resets, last update). Sandboxed with a read-only exception for `~/Library/Application Support/ClaudePult/`, reads `usage.json`; ClaudePult reloads the widget after every usage update. Works with ad-hoc signing — the stage 8 note that widgets need an App Group was wrong (corrected in DECISIONS). Help and README mention the widget. Also: the CLI background launch keeps its RunStore in a variable (Release-build warning gone).
Checked: `scripts/build-and-install.sh --test` — 82 tests green; no compiler warnings. Live: `pluginkit` lists the extension; NotificationCenter publishes the ClaudePult container in the widget gallery; Oleh placed the widget and it shows the percentages; the widget log shows it reading usage.json (29 % → 30 %, same as the file). The widget target has no unit tests (its decoding mirrors `UsageFile`, which is tested). CI not set up; checks run locally.
Left: nothing known.

## 2026-10-29 — Settings tabs and appearance (branch `feat/settings-appearance`)

Done: Settings split into tabs Основные / Внешний вид / Claude / Сессии / Лимиты. New «Внешний вид»: theme (also for ClaudePult's windows), panel text size (own scaling — macOS ignores dynamicTypeSize; panel widens with it), width, row density, opening animation, visible blocks, menu bar usage display, reset. All panel fonts go through `scaledFont`. `--app-command settings`; debug snapshot of the Settings window; snapshot falls back to the key window.
Checked: `scripts/build-and-install.sh --test` — 82 tests (126 cases) green; no compiler warnings. Live: Settings opened via `--app-command settings`, appearance tab snapshot; panel with «Очень крупный» text (546 × 1003 pt) snapshot — fits the screen, forecast line visible; settings restored to normal afterwards. CI not set up; checks run locally.
Left: tab bar not in snapshots (window frame); theme/width/density need Oleh's eye.

## 2026-10-29 — Stage 8: subscription limits (branch `feat/usage-limits`)

Done: limits from `api.anthropic.com/api/oauth/usage` (token from the Keychain via `security`, never stored or logged; response shape checked live, tolerant decoding that skips code-named objects); menu bar shows session / session + week % or a ring, coloured by level; «Лимиты» block with bars, reset countdown, per-model week, extra usage, forecast from the last 30 min; smart refresh (1 min while active, 5 min idle, right after reset); threshold notifications once per window + «Лимит восстановлен», optional Telegram; per-project token breakdown from `~/.claude/projects/**/*.jsonl` (incremental, de-duplicated, session / today / week, heaviest session, labelled as an estimate); background guard above 90 % with «Запустить после сброса» queue; `usage.json`; Settings for display, thresholds and Telegram; Help section; help.txt line; CLI `--usage`, `--usage-raw`, `--token-usage`; screen-aware panel height. Widgets not built (App Group needs a signing team).
Checked: `scripts/build-and-install.sh --test` — 79 tests (123 cases) green incl. the real response shape, forecast, alerts, incremental scanner; no compiler warnings. Live: `--usage` → session 16 %, week 58 %, Fable week 0 %; app wrote usage.json on start; menu bar «17% · 58%» green/orange (screenshot); panel snapshot with the limits block and the expanded breakdown; `--token-usage` first scan 2.0 s (was 14.6 s before byte filtering). CI not set up; checks run locally.
Left: forecast needs a few minutes of history; threshold notifications and the >90 % guard not reachable live (session at 17 %); widgets deferred.

## 2026-10-29 — Stage 7: polish (branch `feat/polish`)

Done: «Помощь» in the panel footer → window with all ClaudePult features and command-line commands; block «🖥 ClaudePult» appended to `~/Projects/_daily-report/help.txt` (2429 of 4000 characters, rest untouched); app icon generated by `scripts/make-app-icon.swift`; Russian development region (Russian units in the disk indicator); `AppRequests` + `--app-command` so the running app opens windows / runs commands on request; the cleanup check opens its output window automatically; skipped cleanup check shown as not done; snapshots for the help and cleanup windows; README rewritten; docs/CHECKLIST.md with every spec scenario and how it was checked.
Checked: `scripts/build-and-install.sh --test` — 61 tests (100 cases) green; no compiler warnings. Live: panel snapshot with sessions (real ones from other projects), projects, commands, disk «Свободно 12,76 ГБ», «Помощь» in the footer; `--app-command help` opened the help window (snapshot), `--app-command cleanup-check` ran the check and opened its window (snapshot); icon present in the bundle; help.txt length and tags checked. CI not set up; checks run locally.
Left: buttons inside the panel, Settings and notifications need Oleh (docs/CHECKLIST.md); stage 8 (subscription limits) is next.

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
