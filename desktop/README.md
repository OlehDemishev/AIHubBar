# AI Hub Bar for Windows and Linux

Tauri 2: a Rust core plus a small HTML interface. The plan and the stages are in [docs/specs/SPEC-windows.md](../docs/specs/SPEC-windows.md) and [docs/specs/SPEC-linux.md](../docs/specs/SPEC-linux.md). The Mac app (Swift, in `AIHubBar/`) shares no code with this folder, only file formats and texts. Since 2026-11-17 this folder is developed on a Windows PC: setup in [WINDOWS-DEV.md](WINDOWS-DEV.md), rules for agents in [CLAUDE.md](CLAUDE.md), what of the Mac app works on Windows in [SPEC-windows §11](../docs/specs/SPEC-windows.md).

**Stage 1 «Каркас»** is done:
- the tray icon with its menu;
- the panel at the icon;
- the settings window (language, start at sign-in);
- 13 languages;
- one running copy;
- `claudepult --app-command panel|settings|quit`.

**Stage 2 «Лимиты»** is mostly done:
- the session and week limits from Claude Code's token file;
- the tray icon drawn as a ring, with the summary in its hint;
- the forecast;
- notifications at 50 / 80 / 95 %;
- `usage.json`.

Still to come in stage 2: Telegram, spend per project, custom thresholds.

**Stage 3 «Сессии»** is mostly done:
- `claudepult-hook`, a port of the Mac hook (format 7 since 2026-11-17) that writes the same session files, for Claude Code and, with `--agent codex|copilot`, Codex and Copilot CLI; it answers a permission request with the decision given in the app (`approvals/`, the Mac's protocol);
- installing it into Claude Code's `settings.json` in exec form (Settings → Hooks);
- the sessions list in the panel; a session whose process is gone shows as ended;
- «Разрешить» / «Отклонить» under a session that asks for a permission, and a notification for each new request (the app keeps `approvals/alive` fresh while it runs and removes it on quit);
- an orange dot on the tray icon while a session waits.

- Settings → Hooks also installs the hook for Codex (`~/.codex/hooks.json`, merged with a backup; `commandWindows` for cmd.exe, `command` for sh; trusted once in `codex` → `/hooks`) and Copilot CLI (`~/.copilot/hooks/aihubbar.json`, `powershell` and `bash`). On a Mac only into another `CODEX_HOME` / `COPILOT_HOME`.

Still to come in stage 3: «Show» (bringing the terminal forward), buttons in the notification itself (to check on Windows), a switch to turn the answers off.

**Stage 4 «Проекты»** has begun (2026-11-18):
- `core/projects.rs`, a port of the Mac's built-in git scanner (`GitScanner`) and STATUS.md reader (`StatusText`): every folder with a `.git` in `~/Projects` (`%USERPROFILE%\Projects`); branch, uncommitted files, stashes, unpushed branches, worktrees, open PRs with CI through `gh`, the STATUS.md summary and the attention items with the Mac's texts and the same health dot;
- `core/command.rs` runs `git` and `gh`: found through `PATH` and `PATHEXT`, no console window, a time limit; git speaks English (`LC_ALL=C`) and never asks for a password in the background;
- in the panel a «Проекты» card: dot, name, branch, badges, last activity; a click opens STATUS (Сейчас / Дальше / Нужно от вас), attention, PRs, worktrees and «Терминал» / «Папка» / GitHub (Windows Terminal or PowerShell, Explorer, the browser);
- refreshed at start, every 5 minutes, with `git fetch` every 30, and when the panel opens on a list older than a minute;
- Claude in a terminal (`core/launch.rs`, 2026-11-18): «Следующий шаг», «Своя задача…», «Завершить» in an opened project, with the Mac's prompts (the shared `~/Projects/CLAUDE.md` when it exists, else the generic ones of the interface language from `ui/i18n/prompts.json`); a project folder where a session works gives a new worktree `.claude/worktrees/cb-<slug>`, «Завершить» asks instead. Windows: PowerShell with `-EncodedCommand` in a Windows Terminal tab, or in a console of its own without `wt`.

- Claude in the background (`core/runs.rs`, `app/src/runs.rs`, 2026-11-18): the same commands as `claude -p` with no window, as the Mac's `RunStore`. `runs/<id>.json` and `.log` keep the Mac's shape; the Mac's permission rules go in as a file, and on Windows every `Bash(…)` rule is also a `PowerShell(…)` rule, with PowerShell's deletions, downloads and environment reads denied. A time limit, «Остановить» (`taskkill /T /F` on Windows), a notification with the result, the log in the panel. The first launch asks «Терминал» or «Фон» («Запомнить выбор»); Settings → «Фоновые задачи» holds the mode and the limit.

- notifications when a PR's CI fails or is fixed and when a PR closes (between two scans, as the Mac's `PullRequestAlerts`; Settings → «Проекты» turns them off), a red dot on the tray icon while a project needs attention (orange still wins while a session waits) and «Проектов: N · с проблемами: M» in its hint (2026-11-18).

- «Удалить» on a worktree in an opened project (2026-11-18): a check first, as the Mac's `GitService.removalCheck` — nothing uncommitted, the branch merged into the base or pushed — then «Удалить?» / «Отмена», and `git worktree remove` without force; otherwise the reason under the row.

Still to come in stage 4: pausing background runs at the limit, Telegram.

Stage 5 «Профили и модули» (docs/specs/SPEC-windows.md §9):

- Settings → «Проекты» → «Папка проектов» (2026-11-18): «Выбрать…» opens the system's folder picker, «По умолчанию» goes back to `~/Projects` (`%USERPROFILE%\Projects`); `projects_dir` in `settings.json`, as the Mac's `projectsDirectory`. A new folder is read at once, its PR changes are not compared with the old folder's, and installed hooks show «нужно обновить» (they name a session's project by this folder). «Папки нет: …» under the path when it is gone.
- Profiles (`core/profiles.rs`, `app/src/profiles.rs`, 2026-11-18): kept in `settings.json` (`profiles`, `current_profile`) in the Mac's own profile JSON, so `.claudepult` files can move both ways; fields this version doesn't use (modules, menu bar, card, stages, commands…) are written back unchanged, paths with `~` and `/`. The projects folder and «Где запускать Claude» are the current profile's (the Mac's `ProfileStore.apply`). A file from before profiles with its own folder or launch mode gets «Разработчик (GitHub)» from the Mac's template (`ui/i18n/templates.json`, written by `scripts/strings.py`) with them; a first start has no profile (the Mac's empty start, see the assistant below). Settings → «Профили»: choose, rename, «Добавить профиль» (that template), «Удалить» with «Удалить профиль?» (the last one stays); the panel's header switches between them once there are two. A profile with folder projects (from a Mac) shows «У этого профиля нет папки проектов» until folder projects come.
- `.claudepult` files (2026-11-18), the Mac's `SettingsBundle` version 2: Settings → «Экспорт и импорт» → «Экспорт настроек…» (every profile) and «Импорт…»; «Экспорт профиля…» on the current profile. An imported file waits for «Заменить все настройки» (a settings file only) / «Добавить профили» / «Отмена», as on the Mac; ids from a file are checked like `ProfileStore.sanitized`. The Mac's settings this version can't use (appearance, AI services, Telegram, modules) are kept in `mac_settings` and written back on export, so Mac → Windows → Mac gives the same file. `exportedAt` is in whole seconds: the Mac's ISO 8601 decoder refuses fractions. Opening a `.claudepult` with a double click needs the installer (stage 7).
- Folder projects (`core/folders.rs`, 2026-11-18), the Mac's `FolderScanner` and `ProjectCardFile`: a profile with «папки» lists every subfolder (not `_…`, not hidden) newest first, an «входящие» profile its one folder. The card `проект.md` is read in any of the 13 content languages (`ui/i18n/content.json` from `ContentLanguage.swift`) and written back keeping its language, its other lines and its line endings. A row: name, stage chip, the profile's metrics (words, duration, reading time, pages, sources, deadline, publication, last change) and «просрочено N дн»; opened: the stages to switch, format, «Папка», the main file, the card or «Создать проект.md»; «Новый проект» at the bottom. «Добавить профиль» takes any of the Mac's templates now (Разработчик, Видео, Тексты, Ресёрч, Соцсети, Свой); «По умолчанию» goes back to the template's folder. - AI commands of folder projects (`core/commands.rs`, `app/src/commands.rs`, 2026-11-18), the Mac's `CommandEngine` for Claude Code: the profile's commands and «Своя задача» in an opened project, a field first when a command asks («Язык», «Тон»); the result's name never takes an existing file. In the background (`claude -p`) with the profile's permissions — «Только файлы» or «Файлы + поиск в интернете»: files only, `Bash` and (on Windows) `PowerShell` denied — or in a terminal window when the profile's launch mode says so. The rows under the commands: running, done (its file), failed with why; «Убрать готовые». An `.rtf` source's text goes into the prompt (no shell to read it). Models by API and «Сравнить» come with «Сервисы AI».
- «Сервисы AI», models by API (`core/ai.rs`, `core/keys.rs`, `app/src/services.rs`, 2026-11-18): the Mac's eleven providers with the same endpoints. Settings → «Сервисы AI»: a key per provider kept in Windows' Credential Manager («ClaudePult API key/<provider>», DPAPI under the user; never in `settings.json` or an export), «Проверить» lists the models (no tokens spent) and picks one, «Заменить ключ», «Удалить ключ», the compatible server's name and address (Ollama, LM Studio), «API за месяц». The choices are the Mac's `AIServicesConfig`, kept as `services` with the other Mac settings, so `.claudepult` files carry them. A folder project's commands: «Каким сервисом выполнять» (Claude Code or a model with a key) and «Сравнить» with 2–3 services, results named `хуки (OpenAI).md`. A model gets the main file's text and AI Hub Bar writes the answer, notifies, and adds the tokens to `api-spend.json` in the Mac's format. Linux has no key store yet (Secret Service comes later): there, and in the Mac build for developing this one, only servers without a key work. Prices and the budget: see «Расход по API» below.
- Other agents (`core/agents.rs`, 2026-11-18): Codex, Gemini CLI, Antigravity, Copilot and Cursor CLIs found in PATH and where their installers put them (`%APPDATA%\npm`, winget's links, `%LOCALAPPDATA%\agy\bin`, `%LOCALAPPDATA%\cursor-agent`; `~/.local/bin`, nvm on Linux), with their `--version`. Settings → «Сервисы AI» → «Агенты»: installed with version and how it signs in, or the install command for Windows from the vendor's docs with «Скопировать». A git project's Claude block has «Открыть в…»; a folder project's commands can go to an agent: it opens in a terminal in the folder with the task on the clipboard («…вставьте Ctrl+V»), as on the Mac — their «no actions» modes aren't checked live, so none runs unattended.
- «Ближайшее» (`core/calendar.rs`, `app/src/calendar.rs`, 2026-11-18), the Mac's `CalendarScanner` / `CalendarStore`: every profile with folder projects whose calendar is on (Settings → current profile → «Календарь»: «Выключен», «Дедлайны и публикации», «+ контент-план») gives its cards' deadlines and publications, and with the plan the rows of `контент-план.md` (the profile's own and each project's, in any content language). The panel shows the next 7 days, overdue in red; a click opens the project, the row's file or the plan. Reminders before each date as on the Mac («Напоминать»: none, 2 h, a day, a day and 2 h, 3 days and a day), each once (`calendar-reminded.json`). Read at start, every 5 minutes, on a stale panel and after a stage changes.
- The «Календарь» window (`ui/calendar.html`, 2026-11-18), the Mac's `CalendarWindow`: «Календарь» in «Ближайшее» opens a month or a week (the language's first weekday and month names from the webview's `Intl`), every profile or «Только текущий профиль», a colour per profile. Dragging a date to another day writes it into the card or the plan row, keeping its time; a double click on a day adds a plan row (to the profile's own `контент-план.md`, made when missing) or a project's deadline or publication; a double click on a date opens it. The window has no file drop handler (`disable_drag_drop_handler`), so the page's own drag and drop works in WebView2.
- The profile assistant (`core/assistant.rs`, `ui/assistant.html`, 2026-11-18), the Mac's `AssistantView` / `AssistantDraft`: Settings → «Профили» → «Помощник…». One choice per screen — a template or «С нуля»; the projects folder (what it holds: git repositories suggest the git scanner, the «код» rules and STATUS.md cards); stages, the row's metrics with the speech pace, the calendar with reminders (folder projects only); the service; where Claude runs and what it may do in the background; the name. Nothing is saved until «Готово», which makes the folder if needed and adds the profile as the current one. The Mac's steps for modules, the menu bar and SF Symbol icons are left out (none of those here); the template's commands come as they are.
- The empty start (2026-11-18, SPEC-profiles §2): a first start (no `settings.json`) has no profile and opens the assistant; the panel shows «Создайте первый профиль» with «Помощник…» and «Импортировать файл…» (the file then waits in Settings for «Заменить» / «Добавить»). Limits and sessions work without a profile.
- The current profile in Settings (2026-11-18), the Mac's profile page: «Сервис по умолчанию»; for folder projects «Права Claude в фоне», stages (comma separated), the row's metrics, the speech pace and «Команды проектов» — each command folded into a line until opened: name, result file, main file or whole project, «Спросить перед запуском», service, task, «Удалить команду» (asks once); «Добавить команду». A field is saved when it is left (`set_profile_field`, checked like the Mac's decoder), and the panel reads the projects again.
- «Расход по API» (2026-11-18): today and this month, «Бюджет в месяц, $», a price per million tokens (in / out) for Anthropic, the compatible server and every provider with a key — the Mac's `prices` and `monthlyBudget`, so `.claudepult` files carry them. A notification at 80 % and 100 % of the budget, each once a month (`api-budget-warned.json`).
- `.docx` (`core/docx.rs`, 2026-11-18): a Word file's text is read from `word/document.xml` (unzipped with `miniz_oxide`, already in the build), for word counts and, as on the Mac, into a background prompt (no shell to open it).
- «Не спать» (`core/keep_awake.rs`, `app/src/keep_awake.rs`, 2026-11-18), the first stage 6 module: Settings → «Модули» switches it (the Mac's `installed` / `off` lists in `mac_settings`, so `.claudepult` files carry them). The computer is held awake by a power request (`PowerCreateRequest`, see `powercfg /requests`; `systemd-inhibit` on Linux, `caffeinate` on a Mac, both ending with the app) while a rule holds: by hand (the switch, 15 min, 1 h, 2 h; kept across restarts), while Claude works, on mains power, with an external display, while chosen programs run; «Не гасить и экран» holds the display too. Rules in `settings.json` (`keep_awake`), looked at every 15 s. The panel's «Не спать» block and «☕ держу: …» in the tray's hint. «С закрытой крышкой» needs the power plan changed and comes later.
- «Ресурсы компьютера» (`core/resources.rs`, `app/src/resources.rs`, 2026-11-18): processor, memory, the system disk, network, graphics and the programs using the most processor through `sysinfo` (pinned at 0.40.1), the battery through `GetSystemPowerStatus` (`/sys/class/power_supply` on Linux), «памяти не хватает» from Windows' own low memory signal. Read every 30 s in the background (alerts, «Процессор … · память …» in the tray's hint) and every 2 s while the panel is visible. The Mac's alerts: processor over 90 % for 5 minutes, a memory shortage, little disk space (5–100 GB), battery under 15 % off the charger — once each until it clears. Settings → «Модули»; «Открыть Диспетчер задач» in the panel on Windows.
- «Быстрые команды» (`core/quick_commands.rs`, `app/src/quick_commands.rs`, 2026-11-18): the person's own buttons, the Mac's `QuickCommand` JSON in `settings.json` (`quick_commands`; two examples until edited). A script in the background (PowerShell without its profile, UTF-8 output, the home folder, up to 10 minutes, no console window; its last line as a notification), a script in a new terminal window, or a link, file, folder or program to open; the Mac's «Команды» shortcuts are not shown here. The panel's buttons two per row, «Запустить «…»?» when a command asks, each one's last result. Settings → «Модули» edits the library. Keyboard shortcuts come later; a command's `hotKey` is kept as it was.
- «Быстрые переключатели» (`core/toggles.rs`, `app/src/toggles.rs`, 2026-11-18): dark mode (the `Personalize` values and `WM_SETTINGCHANGE`), desktop icons (Explorer's own «Show desktop icons» command), lock (`LockWorkStation`), the display off (`SC_MONITORPOWER`), the Recycle Bin emptied (`SHEmptyRecycleBinW`, after «…? Это нельзя отменить.»). On Linux `gsettings`, `loginctl`, `xset`, `gio` where present. Tiles in the panel; Settings → «Модули» picks which show. «Извлечь диски» comes later.

Not yet: dates as day and month numbers (no month names without a translation).

On a Mac this build never installs hooks into the real `~/.claude/settings.json`: the Mac app owns it. It does so only with another `CLAUDE_CONFIG_DIR`.

## Layout

| Folder | What |
|---|---|
| `core/` | Shared logic with no interface: paths, `settings.json`, languages, the link to the running app, limits (`usage.rs`, `texts.rs`, `tray_icon.rs`), sessions and hooks, projects (`projects.rs`, `command.rs`, `launch.rs`), background runs (`runs.rs`). `cargo test -p claudepult-core` runs on any system |
| `app/` | The tray app, `AIHubBar.exe` / `AIHubBar` (`tauri.conf.json`, icons, capabilities) |
| `cli/` | `claudepult`, the console program: `AIHubBar.exe` is a window program and cannot print to a console |
| `hook/` | `claudepult-hook`, the Claude Code hook (port of the Mac's Python hook); `cargo test -p claudepult-hook` runs it with real events |
| `ui/` | The panel and settings pages, plain HTML/JS with no bundler; `ui/i18n/*.json` are generated |
| `scripts/strings.py` | Writes `ui/i18n/` from the Mac app's String Catalog |

The two programs are called `AIHubBar` and `claudepult`, not `ClaudePult` and `claudepult`. Windows and macOS file systems ignore letter case, so names that differ only in case would overwrite each other.

## Texts

Keys are the Russian texts of the Mac catalog, `AIHubBar/Resources/Localizable.xcstrings`. A new text works like this:
1. Add it to the catalog first, with all 12 translations.
2. Use it in the code: `data-t="…"` or `t("…")` in `ui/`, `.t("…")` in Rust.
3. Run `python3 scripts/strings.py`.

`--check` fails when a key or a translation is missing, or when the files are out of date. CI runs it.

## Build and run

You need Rust (stable) and Node 22. On Linux you also need the Tauri libraries: `libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev libssl-dev`.

```bash
npm ci
cargo test --workspace
npx tauri dev                      # the app, with reload
cargo build --release -p claudepult-hook -p claudepult-cli
./scripts/stage-binaries.sh        # puts both next to the app in the installer
npx tauri build --bundles nsis --config app/tauri.bundle.conf.json   # Windows installer (current user, no admin)
npx tauri build --bundles deb --config app/tauri.bundle.conf.json    # Linux package
```

On a Mac this version runs for development only:
- its files go to `~/Library/Application Support/ClaudePult Desktop Dev/`, never the real app's folder;
- `claudepult` talks to it through `/tmp/ClaudePult-<user>`.

## CI

`.github/workflows/desktop.yml` runs on GitHub's Windows and Linux machines. The repository is public, so it costs nothing. It does three things:
- checks the texts;
- runs `cargo test`;
- builds the Windows installer and the `.deb`, kept for 14 days as artifacts of the run.
