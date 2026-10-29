# Decisions

Decisions made where the spec is silent or does not match reality. Newest at the top.

## 2026-10-29 — Settings tabs and appearance (Oleh's request)

**Tabs.** The single long Settings form became a `TabView` with Основные, Внешний вид, Claude, Сессии, Лимиты; the last opened tab is remembered.

**Text size.** macOS ignores `dynamicTypeSize` for SwiftUI text styles (checked: `.caption` and `.body` render the same at `.small` and `.xxxLarge`), so the panel uses its own scale: `scaledFont(_:)` maps each text style to its macOS point size (body 13, callout 12, caption 10, …) times the chosen factor (0.9 / 1 / 1.15 / 1.3), read from the `panelTextScale` environment value; the panel's default font is scaled the same way. All 55 font uses in the panel views were switched. The panel widens with the text (width × factor) so lines do not truncate; at «Очень крупный» it is 546 × 1003 pt here, still within the screen.

**Other appearance settings**: panel width (380 / 420 / 500 pt), row density (vertical padding × 0.5 / 1 / 1.5 for project and session rows), theme (system / light / dark via `preferredColorScheme`, also for the help, log, cleanup and settings windows), opening animation on/off (combined with Reduce Motion), visible blocks (hidden blocks keep working: notifications still arrive), the menu bar usage display (moved here from the limits section), and «Сбросить внешний вид».

**Settings windows checkable from scripts**: `--app-command settings` opens Settings in the running app; the debug snapshot covers it (the tab bar belongs to the window frame and is not in the picture).

## 2026-10-29 — Stage 8 (subscription limits)

**Endpoint, checked live** (`--usage-raw`, 2026-10-29): `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20` answers with `five_hour` and `seven_day` (`utilization` in %, `resets_at` ISO with microseconds), `seven_day_opus` / `seven_day_sonnet` / … (null on this account), a `limits` list (`kind`: `session`, `weekly_all`, `weekly_scoped` with `scope.model.display_name`, e.g. «Fable»), `extra_usage` (`is_enabled`, `used_credits`, `monthly_limit` in minor units, `currency`), `seven_day_breakdown`, `spend`, and many code-named objects. One of those (`iguana_necktie`, a dollar allowance) has `utilization: 100` and would look like a full limit, so only `five_hour`, `seven_day*` and `weekly_scoped` entries of `limits` are taken; a response without `five_hour` counts as unknown → «лимиты недоступны». Extra usage is shown only when enabled.

**Token.** Read from the Keychain item «Claude Code-credentials» (`claudeAiOauth.accessToken`, `expiresAt` in ms) with Apple's `/usr/bin/security`, not `SecItemCopyMatching`: a Keychain «Always Allow» for `security` survives ClaudePult rebuilds, while an ad-hoc signed app would be asked again after each build. The token lives only for the request; it is never stored, logged or refreshed. Expired → «Войдите в Claude Code: claude → /login».

**Refresh.** Every minute while a session is working/waiting or the session % grew in the last 10 min, otherwise every 5 min; never later than 5 s after the session reset. History of the last 3 h is kept in `usage-history.json`, so the forecast survives a restart.

**Forecast**: growth of the session % over the last 30 min of the same window (≥ 5 min of data); at that pace → «хватит до ~HH:mm» if before the reset, else «до сброса хватит»; no growth → «до сброса хватит».

**Notifications.** Thresholds (default 50/80/95, Settings) per window and reset time; only the highest newly crossed threshold notifies (starting at 85 % gives one alert). «Лимит восстановлен» when a window that was above 80 % drops by 30+ points or resets below 50 %. Notified keys persist in UserDefaults across restarts. Telegram for these alerts is off by default.

**Menu bar.** Modes: only icon / session % / session and week % / ring. Coloured text cannot go through a template label, so the label is one drawn `NSImage` (sparkle in `labelColor`, red dot, coloured percentages or ring, ✋ + waiting count), cached per state.

**Per-project breakdown.** `~/.claude/projects/**/*.jsonl` (~500 MB in a week here): files changed in the last 8 days are read incrementally (byte offset per file, only complete lines), lines are pre-filtered by bytes (`"usage"`, `"assistant"`) before JSON, and messages are de-duplicated by `message.id` — streaming writes the same message and usage on several lines. First pass ~2 s (was 15 s with String-based filtering), then only new lines, every 10 min. Projects by `cwd` under the projects folder (worktrees count for their project; anything else is «Другое»). Shares use a price-like weight (input ×1, output ×5, cache write ×1.25, cache read ×0.1); the token numbers shown exclude cache reads, which are hundreds of millions per day and would hide everything else. Labelled as an estimate.

**Background guard.** A background command while the session is above 90 % shows «Запустить после сброса» (queued for `resets_at` + 2 min, persisted in `queue.json`, started by a 30-s timer, cancellable in the «Лимиты» block) and «Запустить сейчас».

**usage.json** in Application Support: `five_hour` and `seven_day` (`utilization`, `resets_at`) and `updated`. report.py and bot.py are not changed (spec §5); what they would need is in Needs Oleh.

**Widgets not built.** A WidgetKit extension needs an App Group shared with the app, and App Groups need a real signing team (provisioning); this project is signed ad-hoc with no team (stage 1). Left in Next with that reason.

**Panel height.** With the limits block the panel grew; the project list now scrolls at a height derived from the screen (`visibleFrame − 700`, 180…420 pt), and the breakdown is collapsed by default.

## 2026-10-29 — Stage 7 (polish)

**Help.** «Помощь» in the panel footer opens a window built from one `HelpContent` list (menu bar, sessions, projects, commands, command line). The `help.txt` block for the Telegram bot is a shorter hand-written summary in Telegram HTML, appended at the end as the spec asks («🖥 ClaudePult»); the file went from 1645 to 2429 characters (limit 4000), tags balanced, the rest untouched.

**App icon** is drawn by `scripts/make-app-icon.swift` (warm gradient squircle, white ✦ and a small «panel» card) into `Resources/Assets.xcassets`, so it can be regenerated; the menu bar keeps the plain SF Symbol.

**Russian locale.** `CFBundleDevelopmentRegion = ru` (and `CFBundleLocalizations = [ru]`) so system formatters speak Russian («12,76 ГБ», dates), matching the Russian UI.

**Requests from outside the panel.** Windows that must open while the panel is closed (the cleanup check output) and `--app-command` requests from scripts (a distributed notification `com.demishev.claudepult.app-command`) go through `AppRequests`; the menu bar label — the only view alive all the time — opens the windows. This also made the help and cleanup windows checkable without clicks.

**«Очистка: проверить» skipped** («Идёт сборка — очистку пропускаю») now shows as not done, like the real cleanup.

**Checks.** Menu bar clicks from computer-use failed while another app was frontmost; with Finder in front they work, and the debug snapshot (now also for the help and cleanup windows) shows the panel. Clicking inside ClaudePult's windows stays impossible for automation (the app cannot be granted), so the remaining button checks are listed for Oleh in docs/CHECKLIST.md.

## 2026-10-29 — Stage 6 (common commands and disk)

**Report period.** «Отчёт сейчас» and «Быстрая сводка» pass `--since-hours 24` as the spec's command lines do. With an explicit period report.py does not move its own «since last report» marker (`state.json`), so the 10:00 report is not affected.

**Result line.** report.py prints `HH:MM:SS …` log lines and finishes with «Telegram: отправлено» or the Telegram error; that last line (time stripped) is the result, and anything else starting with «Telegram» counts as a failure because report.py exits 0 either way. cleanup.py puts its total first («Можно освободить: … · свободно на диске …»); a cleanup skipped because a build is running («Идёт сборка — очистку пропускаю») is shown as not done. Output passes through a filter that replaces `bot<digits>:<token>` so a token can never reach the panel, a notification or the app log.

**Long operations** run through `ProcessRunner` (async, timeouts: report 10 min, summary 3 min, cleanup check 5 min, cleanup 15 min); the button shows a spinner and is disabled while running, the result stays in the panel and goes to a macOS notification. The same command cannot run twice at once.

**«Очистка: выполнить»** asks for a confirmation inside the panel first (it deletes builds and resets simulators). After it, the project data is refreshed so the free-space figure updates.

**«Очистка: проверить»** opens its output in a separate window when it finishes. The window is opened from the menu bar label, the only view that exists while the panel is closed.

**Disk.** `disk_free_bytes` from report.py, shown with `ByteCountFormatter` (decimal GB, like Finder); below 20 GB it turns orange with a warning icon.

**Command line** `--command report|summary|cleanup-check|cleanup` runs the same code as the buttons (used for the live checks).

## 2026-10-29 — Stage 5 (background mode)

**Flags** checked with `claude --help` (2.1.312) and code.claude.com docs (headless, permissions, permission modes): `-p <prompt> --session-id <uuid> --output-format stream-json --verbose --permission-mode dontAsk --permission-prompts none --settings '<json>'`. `dontAsk` + `--permission-prompts none` deny everything not allowed without a prompt and tell Claude nobody will approve; the CLI flag overrides any `defaultMode`. The run id is passed as `--session-id`, so the hook's session file and the run share the id and the panel joins them. User settings stay loaded (`--setting-sources` would also drop the session hooks); they have no `allow` rules on this Mac, and `deny` rules win over `allow` from any level anyway.

**Rules** (`BackgroundPermissions`): allow list per spec §2.4 — read, `Edit(./**)` (writes only inside the working folder; `Write(...)` path rules never match, `Edit` covers them), checks/builds, safe git, `git push origin|-u origin <branch>`, `gh pr create/view/list/checks/status`; deny list — every push form that can reach main/master or HEAD (bare `git push`, `origin` without a branch, `*:main`, `HEAD`), force/delete/mirror/`+refspec` pushes, `reset --hard`, `clean`, branch deletion, `gh pr merge`, `gh api`, `sudo`, `rm`, secrets by path (`Read(**/.env*)`, keys, `~/.ssh`, `config.json`) and by command text (`Bash(*.env*)`, `env`, `printenv`) because read-only shell commands like `cat` run without approval in every mode; `blockReadsOutsideWorkingDirectories`. **Checked live** with a real `claude -p` in a throwaway repo with a local origin: branch, write, commit and `push -u origin feat/x` ran; `push origin main`, `push --force`, Read `.env`, `cat .env`, `rm`, writing `/tmp/…`, `gh pr merge`, `sudo`, `reset --hard` were denied; origin `main` untouched.

**Limits of the rules.** Per the docs, Bash rules are pattern matching, not a sandbox: an allowed command that runs other code (`npm run`, `make`, `scripts/*`, `npx`) could do anything its script does. The spec explicitly allows project checks and builds, so this is accepted; a real boundary would need Claude Code's sandbox (not used: it changes how builds and network work and was not asked for).

**Process.** Claude's stdout/stderr go straight to `runs/<id>.log` (not through a pipe), so a run survives ClaudePult quitting; metadata in `runs/<id>.json`. A run is "alive" while its PID exists with a start time within 30 s of the run start (guards PID reuse; a first version checked the executable name, which wrongly finished runs whose binary was not called `claude`). There is no run-time flag in the CLI, so the time limit (90 min default, Settings) is enforced by the app: SIGTERM (Claude runs SessionEnd hooks and kills its Bash children), SIGKILL 10 s later. «Остановить» does the same.

**Result.** The last `{"type":"result"}` event: `is_error` decides ✅/❌; `result` gives the summary (first 1–3 non-empty lines, ≤ 300 chars) and the last `github.com/…/pull/N` link; `permission_denials` are appended as «Отклонено правилами фона: …». No result event (killed, crashed) → ❌ «без результата». Time limit and manual stop → ❌ with that reason.

**Telegram.** Token and chat id are read from `_daily-report/config.json` on each send, never stored or logged; errors are logged without the request URL (it contains the token). HTML with user text escaped. Toggle in Settings (on by default); without credentials only the macOS notification is sent. Results of runs that finished more than an hour before ClaudePult noticed (app not running) are not announced.

**Mode choice.** Each command asks «Терминал / Фон» inline with «Запомнить выбор» unless Settings has a default; the default can be reset to «Спрашивать» in Settings. The busy-folder → worktree rule applies to both modes.

**«Журнал»** is a separate window rendering the stream-json log (assistant text, tool calls, result), refreshed every 2 s while the run is going; «Файл журнала» reveals the raw log.

**Command line** `--claude … --background` starts a run from a script; the running app discovers it within 10 s, enforces the limit and reports the result. `--background-settings` prints the rule set.

## 2026-10-29 — Stage 4 (sessions)

**Hook facts** checked against code.claude.com/docs/en/hooks on 2026-10-29 (not from memory): events `SessionStart` (source startup/resume/clear/compact/fork), `UserPromptSubmit` (`prompt`), `PermissionRequest` (fires when Claude asks), `Notification` (`notification_type`; `permission_prompt` only after ~6 s without typing, `idle_prompt` ~60 s after finishing), `Stop`, `StopFailure` (API error instead of Stop), `SessionEnd` (`reason`); common fields `session_id`, `transcript_path`, `cwd`, `hook_event_name`. Plain stdout on SessionStart/UserPromptSubmit is added to Claude's context; exit 2 blocks on several events. Commands run through `sh -c`; settings edits are picked up by running sessions; hooks from `~/.claude/settings.json` run in Terminal, desktop-app and `claude -p` sessions, in trusted folders.

**Hook script** in Python 3 (`/usr/bin/python3`, ~20–40 ms start): JSON parsing and file locking without dependencies; `report.py` already relies on the same interpreter. It prints nothing, silences stderr and always exits 0. One file per session, written atomically under a shared `flock`. It finds the Claude process by walking up from its parent with `ps` (once per session) to record pid and tty, plus `TERM_PROGRAM` and `CLAUDE_CODE_ENTRYPOINT`. Session ids are validated before being used as file names.

**States.** SessionStart → готово (a fresh session waits for input; `compact` keeps the current state), UserPromptSubmit → работает, PermissionRequest and Notification `permission_prompt` / `elicitation_*` / `agent_needs_input` → ждёт ответа, PostToolUse → работает (clears «ждёт ответа» after a permission was granted), Stop / StopFailure → готово, SessionEnd → завершена. `idle_prompt` is ignored: a finished session waiting for the next task is «готово», not «ждёт ответа» — otherwise every finished session would notify after a minute. PostToolUse runs on every tool call, so the hook writes then only when the state changes or once a minute. «Ошибка» is left for background runs (stage 5).

**Visibility.** A session whose recorded Claude process is gone (checked with `proc_pidpath`, guarding against PID reuse) counts as ended even without SessionEnd (crash, killed terminal). Ended sessions stay visible 15 min; others without a live process disappear after 2 h without events (spec). Order: waiting, running, error, done, ended. Files older than 7 days are deleted.

**Settings merge.** JSON is read with `JSONSerialization`; on a parse error nothing is written. ClaudePult's entries are recognised by `claudepult-hook` in the command, removed and re-added (idempotent); other hooks are untouched; a no-op install writes nothing and makes no backup. Each real change first copies the file to `settings.json.claudepult-backup-<local time>` and never overwrites an earlier backup (a first version did overwrite the backup of the original when installing twice within a second; the original was restored from a copy and the case is covered by a test). The file is written pretty-printed with sorted keys, so key order may change once.

**«Показать».** Terminal.app sessions: AppleScript finds the tab whose `tty` matches and brings its window forward. Desktop-app sessions (`CLAUDE_CODE_ENTRYPOINT=claude-desktop`): open Claude. Otherwise the folder in Finder. The tty check comes first because the entrypoint variable can be inherited.

**Child environment.** Processes started by ClaudePult no longer inherit `CLAUDE_CODE_*` / `CLAUDECODE`: when ClaudePult ran from inside a Claude session, a Terminal launched by it passed them on and the new `claude` treated itself as a child session (no transcript, desktop entrypoint).

**Task text.** The panel shows the first prompt; prompts of ClaudePult's own commands are shown as «Следующий шаг», «Завершить сессию» or the bare task text without «Задача от Олега: … Работай по правилам …».

**Not used:** `~/.claude/sessions/<pid>.json`, Claude Code's own registry of live sessions (pid, sessionId, cwd, status). It is undocumented; the spec asks for hooks.

**Notifications** via `UNUserNotificationCenter`, once per waiting episode (session + event time), not replayed for waits older than 10 min after an app restart. Authorization is requested on the first waiting session.

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
