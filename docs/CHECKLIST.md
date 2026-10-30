# Scenario checklist

Every scenario of docs/SPEC.md with how it was checked. «Auto» = unit tests; «Live» = run on this Mac by Claude (command line, panel snapshot, screenshots of the menu bar and Terminal); «Oleh» = needs a person, because automation can neither click inside ClaudePult's windows nor see notifications and Telegram.

Panel snapshots: `defaults write com.demishev.claudepult DebugPanelSnapshot -bool YES` saves `~/Library/Logs/ClaudePult/panel.png` (and `help.png`, `cleanup.png`) each time the window shows; turn off with `defaults delete com.demishev.claudepult DebugPanelSnapshot`.

## Menu bar and panel (§2.1)

| Scenario | Checked |
|---|---|
| ✦ icon in the menu bar, gone when the app quits | Live (screenshot) |
| Red dot when a project is red | Live (screenshot) |
| Number of waiting sessions next to the icon | Live (screenshot, «1») |
| Panel order: sessions, projects, commands + disk, Настройки / Помощь / Выход | Live (snapshot) |
| Entrance animation, Reduce Motion | Live (fires on every open, log); **Oleh: look** |
| ⌘R, ⌘,, ⌘Q | **Oleh** |

## Projects (§2.2)

| Scenario | Checked |
|---|---|
| Rows: health, name, branch, uncommitted, PR badge with CI colour, time ago | Auto + Live (snapshot) |
| Expand: Stage / Now / Next / Needs Oleh, attention, PRs, worktrees | Live (snapshot) |
| Terminal / Finder / GitHub buttons | **Oleh** |
| Refresh on open (> 60 s), every 5 min, fetch every 30 min | Live (log shows runs); 30-min fetch not observed |

## Claude commands (§2.4)

| Scenario | Checked |
|---|---|
| Prompts verbatim, shell quoting (zsh/bash round-trip) | Auto |
| Terminal: new window, folder with spaces, task with quotes/newlines | Live (`--claude … --claude-path /bin/echo`) |
| Busy folder → worktree `cb-<slug>` on `claude/<slug>`; «Завершить» asks | Live |
| Terminal / Фон choice, «Запомнить выбор» | **Oleh** |
| Background rules: allowed vs denied actions | Live (real `claude -p`, 13 actions) |
| Background time limit, stop, result, PR link | Live (fake claude) + Live (real run) |
| Background result in Telegram | Live (API OK); **Oleh: message arrived?** |
| «Журнал» window, «Остановить» button | **Oleh** |
| Worktree removal (clean + pushed check) | Auto (temp repos); **Oleh: button** |

## Sessions (§2.3)

| Scenario | Checked |
|---|---|
| Hook install/update/remove, backup, idempotent | Auto + Live |
| States through a real session (start → running → done → ended) | Live (real `claude` in Terminal) |
| Waiting state, highlight, badge | Live (PermissionRequest event fed to the hook) |
| A real permission prompt → «ждёт ответа» | **Oleh** (this Mac auto-approves edits) |
| «Показать» → Terminal tab by tty | Live (`--show-session`); **Oleh: button** |
| Waiting notification once | **Oleh** (notifications were off until 2026-10-30, see DECISIONS) |
| Notification permission warning in the panel, Settings state + «Проверить» | Live (snapshot «выключены в macOS»; `--notifications-status` → authorized after Oleh enabled) |
| Click on a notification leads to its target | Live (test notification → «Помощь», click logged); targets per kind — Auto |

## Common commands and disk (§2.5)

| Scenario | Checked |
|---|---|
| Отчёт сейчас / Быстрая сводка → Telegram | Live (`--command`); **Oleh: messages arrived?** |
| Последний отчёт | **Oleh** |
| Очистка: проверить → output window | Live (`--app-command cleanup-check`, window + snapshot) |
| Очистка: выполнить | Live: skipped by cleanup.py (a build was running); **Oleh: run when idle** |
| Disk free, orange below 20 GB, Russian units | Live (snapshot) |

## Subscription limits (§2.8)

| Scenario | Checked |
|---|---|
| Endpoint response decoded; code-named objects ignored | Auto (real response shape) + Live (`--usage`) |
| % next to the icon, colours | Live (screenshot «17% · 58%», green/orange) |
| «Лимиты» block: bars, reset countdown, weeks, per-model week | Live (snapshot) |
| Forecast | Auto; **Oleh: appears after ~5 min of activity** |
| Per-project breakdown (session / today / week), heaviest session | Auto + Live (snapshot, `--token-usage`) |
| Threshold notifications, «Лимит восстановлен», Telegram option | Auto (logic); **Oleh: notification** |
| Background guard > 90 %, «Запустить после сброса» | Logic in code, not reachable live (session at 17 %); **Oleh when it happens** |
| `usage.json` | Live (written on start) |
| Widget registered and shown in the gallery | Live (`pluginkit`, chronod log) + Oleh (placed on the desktop, shows percentages) |
| Widget reads usage.json from its sandbox, follows updates | Live (widget log: 29 % → 30 %, same as usage.json) |

## Settings and help (§2.6, §2.7)

| Scenario | Checked |
|---|---|
| Start at login on/off | Live (`--login-item`); **Oleh: toggle** |
| Paths, claude path, launch mode, time limit, Telegram toggle, hooks buttons | **Oleh** |
| Settings tabs; appearance tab content | Live (`--app-command settings`, snapshot) |
| Text size «Очень крупный» in the panel | Live (snapshot: 546 × 1003 pt) |
| Theme, width, density, blocks, animations switches | Auto (persistence); **Oleh: look** |
| Помощь window | Live (`--app-command help`, snapshot) |
| help.txt block «🖥 ClaudePult», ≤ 4000 characters | Live (2429 characters) |

## Modes (SPEC-modes §9.1)

| Scenario | Checked |
|---|---|
| First start: current settings become «Разработчик — Олег», nothing changes | Auto + Live (`--modes`, settings unchanged) |
| Duplicate, enable, order, delete, last mode protected | Auto |
| Switcher in the panel with 2+ modes, switching applies folders/launch mode | Auto; **Oleh: duplicate the mode in Settings → Режимы and look** |
| Export all settings / one mode; no home path, no secrets | Auto + Live (`docs/modes/oleh-developer.claudepult`) |
| Import «Заменить» / «Добавить», tolerant to newer files | Auto; **Oleh: double-click a .claudepult file** |

## Menu bar builder (SPEC-modes §9.2)

| Scenario | Checked |
|---|---|
| Old setting migrates unchanged (icon only / session / session + week / ring) | Auto; Live (`--menubar-preview`: «✦• 34% · 58% ✋1», as before) |
| Presets, every element once, tolerant decoding of unknown elements | Auto |
| Number / ring / bar, «от N %», mono, model week, counters only > 0, countdown, disk below N GB, mode icon or name | Auto; Live («Всё» drawn dark and light) |
| Nothing to show → the sparkle stays, so the item can always be clicked | Auto |
| Width warning above 180 pt | Live («Всё» with sample data is ~400 pt) |
| Export / import carries the builder; old files without it migrate from `menuBar` | Auto |
| Settings → «Строка меню»: preset switch, toggles, order arrows, options, live preview | **Oleh: open the tab and try** |
| Reset countdown ticks every minute in the real menu bar | **Oleh: turn on «До сброса сессии» and watch** |

## AI services (SPEC-modes §9.3)

| Scenario | Checked |
|---|---|
| Agents found with version, «не установлен» with an install command otherwise | Auto (detection) + Live (`--services`: Claude Code 2.1.312 found, others not installed on this Mac) |
| Model-list endpoints of all six providers exist (answer «bad key», not «not found») | Live (requests with an invalid key, 2026-10-30) |
| Request headers (Anthropic `x-api-key` + `anthropic-version`, others Bearer), parsing of model lists, check results | Auto |
| Key saved to / read from / deleted in the Keychain through `security -i`, special characters intact | Live (a throw-away test item, deleted after) |
| Key never in exports; chosen models and compatible server are | Auto |
| OpenAI-compatible local server not running → «Сервер не отвечает» | Live (`--services check`) |
| Settings → «Сервисы AI»: save a key, «Проверить», pick a model | **Oleh: with a real key** |
| «Открыть в…» in a project opens Codex / Gemini in Terminal | **Oleh: after installing an agent** |
| Mode «Сервис по умолчанию» picker | **Oleh: look** |

## Folder projects (SPEC-modes §9.4, part 1)

| Scenario | Checked |
|---|---|
| Subfolders become projects, newest first; `_…` and hidden folders skipped; «одна папка» | Auto |
| `проект.md` read in any Markdown form (bullets, bold, synonyms), dates ISO and `dd.MM.yyyy` | Auto |
| Stage written back keeping the rest of the file and the list marker; card created when missing | Auto |
| Main file from the card, else the newest text file; words without link addresses; `.docx` counted | Auto + Live (`--folder-projects`: 1200-word `.docx` → 8:00) |
| Metrics: words, duration at the mode's pace, reading time, pages, sources, deadline, publish date, last edit | Auto + Live |
| «Новый проект» creates a folder with a card, refuses existing names and `/` | Auto |
| report.py is not run for a folder mode; folder projects are not listed for a report mode | Auto (store) |
| Panel: folder project rows, stage chips, overdue deadline in red, «Новый проект» | **Oleh: switch a mode to «папки» and look** |
| Settings → Режимы: source picker, stages, metrics, speech pace | **Oleh: look** |

## Command engine (SPEC-modes §9.4, part 2)

| Scenario | Checked |
|---|---|
| Placeholders, result names (`<время>`, `<файл>`, comparison suffix, unsafe characters), never overwrite | Auto |
| Agent / API wrappers as in docs/TEMPLATES.md | Auto |
| «Только файлы»: writes a new file in the folder; shell, web and reading outside the folder refused | Live (real `claude -p` in a temp folder, 2026-10-30) |
| «Файлы + поиск»: web page fetched and written to a file; shell refused | Live |
| API request and reply: path, no key header without a key, model, text, tokens | Auto + Live (`--api-complete` against a local OpenAI-compatible stub) |
| No key / no server → clear message | Live |
| Spend: tokens per period, cost only for priced providers | Auto |
| Commands in the panel, «Сравнить» window, spend section and budget notification | **Oleh: with a folder mode and a key** |
| Claude background command → notification opens the result file | **Oleh** |

## Calendar (SPEC-modes §9.5)

| Scenario | Checked |
|---|---|
| Dates from `проект.md` (deadline, publication with/without time) and `контент-план.md` rows (mode folder and project folders) | Auto + Live (`--calendar` on a sample folder) |
| Content plan read by its header (Russian/English), `\|` in cells, other columns and text kept | Auto |
| Moving a date writes it back (card line, plan cell; time kept); new plan row / project date | Auto (store on a temp tree) |
| Reminders: once per offset, the closest offset only, never for past dates | Auto |
| Overdue: date-only deadlines the next day, timed ones after the time | Auto + Live |
| Menu bar «Ближайшая дата календаря» | Auto (text) |
| Panel «Ближайшее», window «Календарь» (month/week, drag, double-click), reminder notifications | **Oleh: with a folder mode that has a calendar** |

## Templates and the built-in git scanner (SPEC-modes §9.6)

| Scenario | Checked |
|---|---|
| Six templates load from the app's resources in order; commands non-empty, services valid | Auto |
| A mode from a template: fresh id, unique name, chosen folder, enabled and current; developer → built-in scanner, generic prompts | Auto |
| Built-in scanner: branch, uncommitted (STATUS.md-only changes are «low»), stashes, local-only / unpushed branches (incl. pushed under the same name without tracking), worktrees and stale ones, PRs + CI via `gh`, STATUS.md summary with any «Needs …», latest entry, health | Auto (temp repo) + Live (`--git-scan ~/Projects`: same health and items as report.py for all six projects, except report.py's «commits but STATUS.md not updated», which depends on its daily window) |
| Generic prompts have no Oleh rules; session titles recognise both styles | Auto |
| Oleh's mode still runs report.py with his prompts | Live (`--modes`, log) |
| Settings → Режимы → «+» → template → folder dialog | **Oleh: try one template** |
