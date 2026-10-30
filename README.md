# ClaudePult

Native macOS menu bar app (no Dock icon): a control panel for the projects in `~/Projects` and for every Claude Code session on this Mac. **For people who just want to use it: [docs/GUIDE.md](docs/GUIDE.md)** — what it does, install, first start, privacy, troubleshooting. This README is the reference for Oleh and for development. Specification: [docs/SPEC.md](docs/SPEC.md). Progress: [docs/STATUS.md](docs/STATUS.md). Next: profiles made of modules — [docs/SPEC-profiles.md](docs/SPEC-profiles.md). Windows and Linux versions (spec only): [docs/SPEC-windows.md](docs/SPEC-windows.md), [docs/SPEC-linux.md](docs/SPEC-linux.md). Decisions: [DECISIONS.md](DECISIONS.md). What was checked how: [docs/CHECKLIST.md](docs/CHECKLIST.md). In the app: «Помощь».

## What it does

Click ✦ in the menu bar. Next to it, by default: the subscription usage (5-hour session and week % — green < 50 %, orange 50–80 %, red > 80 %), a red dot when a project's health is red and ✋ with the number of Claude sessions waiting for an answer. What the menu bar shows is built in Settings → «Строка меню» (presets, elements and their order, gauge style, separator, text size, colour; live preview).

**Лимиты** (top of the panel) — the 5-hour session with a countdown to the reset and a forecast from the last 30 minutes («хватит до ~16:40» / «до сброса хватит»), the week, per-model weeks, extra usage if enabled; «Расход по проектам» estimates each project's share and the heaviest session for the session / today / week from Claude Code's transcripts. Notifications once per window at 50/80/95 % (configurable) and when a limit is restored, optionally to Telegram. A background run while the session is above 90 % asks: start now or after the reset. Data from the same endpoint Claude Code uses (OAuth token read from the Keychain item «Claude Code-credentials», never stored); current values are written to `~/Library/Application Support/ClaudePult/usage.json` (`five_hour`, `seven_day`, `updated`) for report.py and the bot.

**Сессии** (top of the panel, from Claude Code hooks) — every session on this Mac: Terminal, Claude desktop app, background runs. Project, worktree, task, duration, state (работает / в фоне / ждёт ответа / готово / ошибка / завершена). Waiting sessions are highlighted and notify once. «Показать» brings the session's Terminal tab forward (desktop-app sessions open that session in Claude, others the folder); background runs have «Журнал» and «Остановить».

**Проекты** — from `~/Projects/_daily-report/report.py --json`: health, branch, uncommitted files, open PRs coloured by CI, last activity. A project expands into:

- **Claude**: «Следующий шаг» (first Next item), «Своя задача…», «Завершить» — prompts from spec §2.4. Each asks **Терминал** (new Terminal window with `claude "<prompt>"`) or **Фон** (`claude -p`, see below), or uses the default from Settings («Запомнить выбор»). If Claude already works in the project folder, the new task starts in a worktree `.claude/worktrees/cb-<slug>` on branch `claude/<slug>` from `origin/main`; «Завершить» asks before a second session in the same folder.
- «Терминал / Finder / GitHub».
- The STATUS.md header (Stage / Now / Next / Needs Oleh), attention items, open PRs.
- Worktrees with a delete button (only when clean and pushed or merged).

Data refreshes at launch, on panel open when older than 60 s, every 5 min (`--no-fetch`), every 30 min with `git fetch`, and with ⌘R.

**Команды** — through the `_daily-report` tools, with a spinner, a result line and a notification: «Отчёт сейчас» (AI report for 24 h to Telegram), «Быстрая сводка» (no AI), «Последний отчёт» (`reports/latest.html`), «Очистка: проверить» (`cleanup.py --dry-run`, output in a window), «Очистка: выполнить» (`cleanup.py --now`, after a confirmation). Free disk space next to them, orange below 20 GB.

**Widget** «Лимиты Claude» (right-click the desktop → «Изменить виджеты…» → ClaudePult): small — session % ring with the reset countdown; medium — session and week bars. It reads `usage.json`, refreshed whenever ClaudePult updates the limits.

**Профили** (SPEC-profiles; were «Режимы») — ClaudePult works in profiles made of modules: «Лимиты AI», «Сессии агентов», «Ближайшее», «Проекты», «Отчёты `_daily-report`» (docs/SPEC-profiles.md). A profile chooses which of its modules the panel shows and in what order (Settings → «Профили» → «Панель»; «Ближайшее», «Проекты», «Отчёты» appear when the profile has the calendar on, a project source or `_daily-report`) and has its own menu bar (Settings → «Строка меню» edits the current profile's). The current setup is the profile «Разработчик — Олег». With more than one profile enabled, a switcher appears at the top of the panel; Settings → «Профили» lists them (enable, order, duplicate, export, import, delete). Optional modules are installed from Settings → «Модули» («Установить» also adds it to the current profile, «Снять» takes it out of every profile; a profile adds or drops it in «Панель»). The first one is **«Ресурсы Mac»**: processor, memory and pressure, graphics, disk, network, battery and the five busiest processes — every 2 s while the panel is open and every 30 s otherwise, only while installed; alerts for processor above 90 % for 5 minutes, critical memory, low disk and battery below 15 %; «Процессор» and «Память» menu bar elements. CLI: `ClaudePult --resources`. The second is **«Не спать»**: a power assertion (`pmset -g assertions` shows «ClaudePult keep awake»; System Settings are not touched) while Claude works (a session or a background run — on by default), on power, with an external display or while chosen apps run; by hand the panel switch («до выключения») and 15 min / 1 h / 2 h timers; optionally the display too; ☕ in the menu bar. The «Разработчик» template ticks it in the assistant. Settings → «Модули» is the catalog: what each module does, which profiles show it and its settings that don't depend on a profile (limits thresholds and sign-in renewal, calendar reminders). Settings → Основные → «Экспорт настроек…» saves everything to a `*.claudepult` file, format version 2 (profiles with modules and menu bars; no keys or tokens; home paths as `~`); version 1 files still import. Double-clicking such a file in Finder imports it («Заменить все настройки» or «Добавить профили»). Oleh's settings: `docs/modes/oleh-developer.claudepult`. CLI: `ClaudePult --modes` lists profiles with their modules.

## Install

Requirements: macOS 14+ (developed on macOS 27, Apple Silicon), Xcode with Swift 6 (developed with 27.1), `brew install xcodegen`.

```bash
scripts/build-and-install.sh
```

Generates `ClaudePult.xcodeproj` from `project.yml`, builds Release, installs `~/Applications/ClaudePult.app` and relaunches it. `--test` runs the unit tests first, `--no-launch` only installs. Signed ad-hoc; no Apple Developer account needed.

First steps after installing:

1. «Настройки…» → «Claude Code» → «Установить hooks» (adds ClaudePult's hook to `~/.claude/settings.json`, backup saved next to it).
2. Optionally «Запускать при входе в систему».
3. The first «Терминал» launch makes macOS ask to let ClaudePult control Terminal — allow it; notifications — allow them.
4. For the limits, macOS may ask whether `security` may read «Claude Code-credentials» — «Always Allow».
5. Notifications must be allowed (System Settings → Notifications → ClaudePult); the panel warns while they are off, Settings → Основные → «Проверить» sends a test one.

Notifications are clickable: «Claude ждёт ответа» → the session's Terminal tab; a finished background run → its PR («Открыть PR») or «Журнал»; a report → `latest.html`; cleanup → its output.

## Settings

«Настройки…» (⌘,), one tab per area:

- **Основные** — start at login, projects folder, `_daily-report` folder, version, app log.
- **Внешний вид** — theme (system / light / dark, also for ClaudePult's windows), text size (small / normal / large / extra large; the panel widens with it), panel width, row density, opening animation, which blocks to show (Лимиты, Сессии, Проекты, Команды), «Сбросить внешний вид».
- **Строка меню** — the menu bar builder (SPEC-modes §7): presets «Минимум» / «Лимиты» / «Всё» / «Свой»; elements in order, each on/off with its options (icon symbol or the mode's icon; session / week / model week as number, ring or bar, shown always or from N %; reset countdown «2:14» or «2 ч 14 мин»; forecast; waiting, running sessions, background runs, queued launches — only when > 0; free disk below N GB; current mode as icon or name); separator, small text, colour by level or mono; live preview with «Сейчас» / «Пример со всем» and a warning when the item gets wider than 180 pt. CLI: `ClaudePult --menubar-preview <file.png> [minimum|limits|everything]` draws the item (dark and light) with sample data.
- **Модули** — the module catalog: description, which profiles show it, «Лимиты подписки» (thresholds, Telegram, «Продлевать вход Claude Code сам») and «Напоминания» of the calendar.
- **Claude Code** — path to `claude` (empty = auto-detect); session hooks (install / update / remove); background runs (time limit, results in Telegram). Where Claude runs is set per profile.
- **Профили → folder projects** (SPEC-modes §3): a mode's source can be «папки» (every subfolder of the projects folder is a project) or «одна папка». The card is `проект.md` in the project folder — plain Markdown lines `Этап:`, `Дедлайн:`, `Публикация:` (`2026-11-05 18:00` or `05.11.2026`), `Формат:`, `Главный файл:`, `Площадка:`. The mode sets the stages (comma-separated) and which metrics a row shows: words, duration (words per minute set per mode, 150 by default), reading time, pages, sources (PDFs and files in `источники`/`sources`), deadline (red when overdue), publish date, last edit. Words are counted in the main file (`.md`, `.txt`, `.rtf`, `.docx`, `.fountain`), or the newest text file. In the panel: stage switching (writes `Этап:` into `проект.md`), open the folder / main file / card, «Создать проект.md», «Новый проект». CLI: `ClaudePult --folder-projects <folder>`.
- **Languages** (SPEC-modes §13): Russian, English, Spanish, Portuguese (Brazil), French, German, Japanese, Indonesian, Korean, Italian, Arabic (right-to-left), Polish and Ukrainian. The interface is in all of them (String Catalog `ClaudePult/Resources/Localizable.xcstrings`, Russian is the source). Settings → Основные → «Язык интерфейса»: as in the system or any of the thirteen — applied after «Перезапустить». Everything ClaudePult writes or sends follows the interface language through one table per language (`ClaudePult/Models/ContentLanguage.swift`: card and plan file names and fields, task wrappers, prompts); Spanish uses `proyecto.md` / `plan-de-contenido.md`, Portuguese `projeto.md` / `plano-de-conteudo.md`, French `projet.md` / `plan-de-contenu.md`, German `projekt.md` / `inhaltsplan.md`, Japanese `プロジェクト.md` / `コンテンツ計画.md`, Indonesian `proyek.md` / `rencana-konten.md`, Korean `프로젝트.md` / `콘텐츠-계획.md`, Italian `progetto.md` / `piano-contenuti.md`, Arabic `مشروع.md` / `خطة-المحتوى.md`, Polish `projekt.md` / `plan-tresci.md`, Ukrainian `проєкт.md` / `контент-план.md` (the plan file name is shared with Russian). In every language the templates (`template-*.<lang>.json`), the prompts and wrappers for AI services, new cards and content plans are written in that language; every language's file names and field names are always read, and a card keeps the language it is written in. Oleh's own prompts stay as they are. For a one-off check: `ClaudePult <command> -AppleLanguages '(en)'`.
- **Помощник** (SPEC-modes §5): Settings → Профили → «+» → «Помощник…» builds a profile step by step — template or «С нуля», «Что будет в панели» (modules: limits, sessions, projects, upcoming; without projects the project steps are skipped), folder (it looks inside and suggests «git-репозитории» or «папки»), stages, metrics, calendar and reminders, AI service, commands, where Claude runs and what it may do in the background, panel blocks, menu bar preset, name and icon — with a live preview of the panel and the menu bar on sample data. On a first start without `_daily-report` ClaudePult starts empty (SPEC-profiles §2: no profile, nothing installed, the panel offers «Помощник…» and «Импортировать файл…»; deleting the last profile empties it again) and opens the assistant by itself, beginning with «Добро пожаловать в ClaudePult» — readiness checks with a button each: AI service found, session hooks, notifications, start at login (the same list is at the top of «Помощь») — and «Перенести настройки?» (import a `.claudepult` file). CLI: `ClaudePult --readiness [file.png]` prints the checks for this Mac (exit 1 while something is left). CLI: `ClaudePult --assistant-preview <file.png> [template]`.
- **Templates** (SPEC-modes §4): Settings → Профили → «+» → «Разработчик (GitHub)», «Видео», «Тексты», «Ресёрч», «Соцсети», «Свой» — pick the folder (it can be created in the dialog) and the mode is ready: source, card, stages, metrics, commands (texts from docs/TEMPLATES.md, kept in `ClaudePult/Resources/Templates/template-*.json`), permissions, calendar. «Разработчик (GitHub)» uses the built-in git scanner (no `_daily-report` needed: branch, uncommitted files, stashes, unpushed and local-only branches, worktrees, PRs and CI via `gh` if installed, STATUS.md summary — health like report.py) and generic prompts that follow the project's own CLAUDE.md / AGENTS.md. Oleh's mode keeps report.py and his prompts. CLI: `ClaudePult --git-scan <folder>`.
- **Calendar** (SPEC-modes §6): a folder mode's «Календарь» can be off, «Дедлайны и публикации» (from `проект.md`) or «+ контент-план» (rows of `контент-план.md` — a Markdown table `| Дата | Время | Площадка | Тема | Статус | Файл |` — in the mode folder and in each project folder). Panel block «Ближайшее»: the next 7 days of all enabled modes, overdue deadlines in red, a click opens the project or file. Window «Календарь»: month or week, all modes or the current one, a colour per mode; drag an entry to another day — the date is written back into its file; double-click a day to add a plan row or a project's deadline / publication. Reminders (Settings → «Модули» → «Напоминания»): none, 2 h, a day, a day and 2 h, 3 days and a day before; optionally to Telegram. The menu bar element «Ближайшая дата календаря» shows e.g. «Ролик · 2 дн». CLI: `ClaudePult --calendar [folder]`.
- **Commands of folder projects** (SPEC-modes §3, §11): each folder mode has command templates (Settings → Профили → «Команды проектов»: title, task with `{проект}` `{файл}` `{формат}` `{площадка}` `{хронометраж}` `{текст}` `{язык}`, result file name with `<время>` / `<файл>`, input «главный файл» or «весь проект», an optional question asked before running, a service of its own) plus «Своя задача» always. In an expanded project they run with the chosen service: **models by API** get the main file's text and ClaudePult writes the answer to a new file; **Claude Code** runs in the background with the mode's permissions — «Только файлы проекта» (read and write inside the folder, no shell, no internet), «Файлы + поиск в интернете» or «Код» — or in Terminal when the mode says so; **other agents** open in Terminal in the folder with the task on the clipboard. A result never overwrites a file (`-2`, `-3` …). **«Сравнить»** runs one command with 2–3 services → `хуки (Claude).md`, `хуки (OpenAI).md` …, shown side by side in the «Сравнение» window. API tokens are counted per request (`api-spend.json`); Settings → «Сервисы AI» → «Расход по API» shows today / this month, takes prices per provider and a monthly budget (notification at 80 % and 100 %); the limits block shows the month once something was spent. CLI: `--api-complete <provider> <prompt> [base-url]`, `--background-settings [code|filesOnly|filesAndWeb]`.
- **Сервисы AI** (SPEC-modes §11) — agents found on this Mac with their version (Claude Code, OpenAI Codex CLI, Google Gemini CLI, Google Antigravity CLI, GitHub Copilot CLI, Cursor CLI; install command to copy when missing) and models by API (Anthropic, OpenAI, Google Gemini, xAI Grok, DeepSeek, Mistral, any OpenAI-compatible server such as Ollama / LM Studio / OpenRouter). An API key is stored only in the macOS Keychain (item «ClaudePult API key», written through `/usr/bin/security`, never logged or exported); «Проверить» lists the provider's models (no tokens spent) and picks the model. Each mode has «Сервис по умолчанию» (used by command templates from stage 4). Installed agents other than Claude appear in a project's «Открыть в…» menu (opens the agent in Terminal in the project folder). CLI: `ClaudePult --services [check]`.

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
| `--modes` · `--export-settings <file>` | list modes (* = current) · export all settings (import: open the file) |
| `--notifications-status` · `--app-command test-notification` | notification permission · send a test notification |
| `--readiness [file.png]` | what this Mac still needs (AI service, hooks, notifications, start at login); exit 1 while something is left |
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
