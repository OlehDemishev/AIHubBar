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
| «Показать» → Terminal tab by tty; desktop-app session → that session in Claude | Live (`--show-session`); Oleh: button checked 2026-10-30 |
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

## Setup assistant (SPEC-modes §9.7)

| Scenario | Checked |
|---|---|
| Steps: import only on a first launch; stages, metrics, calendar, commands only for folder projects; back / next / skip | Auto |
| Template choice keeps a chosen folder; folder analysis suggests «git-репозитории» when repos dominate | Auto |
| First start without `_daily-report`: starter mode, assistant opens; «Готово» replaces the starter with the new mode | Auto (store) |
| Oleh's first start logic unchanged (report.py present → his mode) | Auto + Live |
| Preview pane: menu bar, limits, «Ближайшее», sample projects with stages and metrics, commands | Live (`--assistant-preview` for video, developer, social) |
| The assistant window itself (pickers, folder dialog, «Готово») | **Oleh: Settings → Режимы → «+» → «Помощник…»** |

## Languages (SPEC-modes §9.9, English)

| Scenario | Checked |
|---|---|
| Every Russian UI string is in the String Catalog with an English translation; format specifiers match | Auto (script check: 0 missing, 0 mismatched, 0 stale) |
| File formats, prompts, the hook script, logs and the CLI stay as they were | Review of the wrapping rules; tests of card/plan parsing still green |
| English output: git scanner attention items, calendar texts, assistant preview | Live (`-AppleLanguages '(en)'`) |
| Plural «файл/файла/файлов» in Russian, «file/files» in English | Auto (Russian) + Live (English) |
| Settings → Основные → «Язык интерфейса» + «Перезапустить» | **Oleh: switch to English and back** |

## Languages: English content (SPEC-modes §9.9)

| Scenario | Checked |
|---|---|
| Templates in English and Russian, same ids and commands, only known placeholders | Auto |
| English placeholders and result names (`{project}`, `<time>`, `<file>`), English agent/API wrappers, English generic developer prompts; Oleh's prompts unchanged | Auto |
| `project.md` / `content-plan.md` read like the Russian names; a card keeps its language when a value is written; new cards and plans in the interface language | Auto |
| Session titles recognise English prompts | Auto |
| Assistant preview of «Video» fully in English | Live (`--assistant-preview … -AppleLanguages '(en)'`) |

## Languages: Spanish (SPEC-modes §9.9)

| Scenario | Checked |
|---|---|
| Every language in the table is complete: all card fields and plan columns, prompts with their placeholders, cards and plans round-trip, session titles | Auto (one test per language) |
| Templates exist in every language with the same ids | Auto |
| 707 interface strings in Spanish, format specifiers match (strings rephrased where «% d» would read as a specifier) | Script check |
| Spanish output: git scanner, assistant preview of «Redes sociales» | Live (`-AppleLanguages '(es)'`) |

## Languages: Portuguese (Brazil) and French (SPEC-modes §9.9)

| Scenario | Checked |
|---|---|
| Language table complete, cards and plans round-trip, templates in both languages, interfaces shipped | Auto (per-language tests) |
| 707 interface strings each, format specifiers match | Script check |
| Assistant preview «Textos» (pt-BR) and «Vidéo» (fr), French git scanner items | Live (`-AppleLanguages`) |

## Languages: German, Japanese, Indonesian, Korean, Italian, Arabic, Polish, Ukrainian (SPEC-modes §9.9)

| Scenario | Checked |
|---|---|
| Language table complete for all thirteen languages, cards and plans round-trip, templates in every language, every `.lproj` ships | Auto (per-language tests) |
| 707 interface strings in each new language, format specifiers match, no risky «% d»-like sequences | Script check |
| Assistant previews «Wideo» (pl), «Відео» (uk), «動画» (ja), «فيديو» (ar) fully translated; Arabic mirrors right-to-left | Live (`-AppleLanguages`) |
| Git scanner plurals: Polish «1 plik / 21 plików», Ukrainian «21 файл / 54 файли» | Live (`--git-scan`) |
| Reading by a native speaker (at least ja, ko, ar), the Arabic panel, menu bar and windows by eye | Oleh |

## Onboarding (SPEC-modes §9.8)

| Scenario | Checked |
|---|---|
| Readiness rows: service found / other service only / nothing / not yet scanned; hooks need Claude Code, outdated, missing; notifications allowed / not asked / denied; login item on / off (optional) / needs approval | Auto (`ReadinessTests`) |
| First launch starts with «Добро пожаловать», then «Перенести настройки?»; later launches start at the template | Auto (`AssistantDraftTests`) |
| `--readiness` on this Mac: all four rows done, exit 0; German and Arabic (mirrored) renders | Live |
| 22 new strings in all 12 languages, format specifiers match | Script check |
| A real first start on a clean account: the welcome screen, each button (install hooks, allow notifications, System Settings, login item, «Сервисы AI»), «Проверить снова» after coming back from System Settings | Oleh |
| docs/GUIDE.md reads well for someone new | Oleh |

## UI quick fixes (after the UI review, 2026-10-30)

| Scenario | Checked |
|---|---|
| A session resumed in a new process (Claude app restart, `claude --resume`) shows as running, not «завершена» | Auto (hook under a process named `claude`) + live (this session after the fix) |
| An app update replaces an outdated hook script by itself while the hooks are installed | Auto + live (`--hooks status`: installed) |
| Agent version without the repeated product name («2.1.312») | Auto + live (Сервисы AI) |
| Limits tab: thresholds shown once, footnote points to «Строка меню»; Sessions tab: no «Обновить hooks» while installed | Live (window captures) |
| Panel: one refresh (⌘R) for projects and limits; stale limits dimmed with «данные … назад»; the warning wraps instead of being cut | Live (panel snapshot) |

## Panel polish (UI review, 2026-10-30)

| Scenario | Checked |
|---|---|
| Week reset on the title line; a model week at 0 % is hidden; a model week's reset only when it differs from the week's | Auto (`shownOtherWindows`) + live (panel snapshot) |
| «Проекты» header with the count and «с проблемами: N» | Live (panel snapshot) |
| Badges read «2 файла», «1 PR» | Live (panel snapshot) |

## Settings tidy-up (UI review, 2026-10-30)

| Scenario | Checked |
|---|---|
| One «Claude Code» tab (path, session hooks, subscription limits, background runs) instead of «Claude», «Сессии», «Лимиты» | Live (window capture) |
| Modes list: the checkbox is the only mark, the current mode says «текущий», full name in a tooltip | Live (window capture) |
| Services: installed agents first, the rest under «Ещё агенты (N)» | Live (window capture) |
| Menu bar: the icon element's option is «Символ», not a second «Значок» | Code |
| Assistant: no «Пропустить» on the template step; Help: «Всё готово · Подробнее» when nothing is left | Live (Help capture) |
| Reordering menu bar elements by dragging | Not done: arrows stay (drag in a grouped Form is unreliable) |

## Collapsible panel blocks (UI review, 2026-10-30)

| Scenario | Checked |
|---|---|
| A click on a block's title folds it; the choice is kept (`collapsedBlocks`) | Auto (`CollapsedBlocksTests`) + live (panel snapshot) |
| Folded «Лимиты» still show session and week %, «Сессии» keep «ждут ответа», «Ближайшее» shows the count (red if overdue), «Проекты» the count | Live (panel snapshot) |

## Claude Code sign-in renewal (2026-10-30)

| Scenario | Checked |
|---|---|
| A one-word `claude -p` request renews the expired token (11:02 → 20:11) | Live (by hand, token never printed) |
| The request leaves no session file, no hook record, no transcript (`--no-session-persistence`, `--setting-sources ""`, `--tools ""`) | Live |
| At most one attempt an hour; arguments without `--bare` (which skips the keychain) | Auto (`LoginRenewalTests`) |
| ClaudePult renews by itself the next time the token expires and the limits keep updating | Not yet seen: the token was renewed by hand during the check; due around 20:11 |

## Profiles stage 1: model (SPEC-profiles §9.1, 2026-10-30)

| Scenario | Checked |
|---|---|
| A mode's modules follow its blocks: limits, sessions, upcoming (calendar on), projects (a source), reports (`_daily-report`); hidden blocks stay hidden; a kind keeps its place | Auto (`ProfileModuleTests`) |
| Mode files and state from before profiles are rewritten with modules and the installed list; the next start reads the same | Auto + live (Oleh's mode: limits, sessions, projects, reports) |
| Modules a newer version knows are skipped, not an error | Auto |
| `.claudepult` export is version 2 with modules and installed; version 1 files still import and get modules | Auto |
| The panel looks the same | Live (installed, nothing reads modules yet) |

## Profiles stage 2: panel from modules, Profiles and Modules tabs (SPEC-profiles §9.2, 2026-10-30)

| Scenario | Checked |
|---|---|
| The profile's modules decide the panel: order and visibility are the profile's own; a module that becomes possible (calendar on) is added shown; old global blocks no longer matter | Auto (`ProfileModuleTests`) |
| Selecting a profile applies its panel and its menu bar; «Строка меню» changes only the current profile's | Auto |
| Oleh's profile after the update: modules limits, sessions, projects, reports; panel in that order | Live (`--modes`, panel snapshot) |
| Settings → «Профили» → «Панель» (toggles, ↑↓) and «Модули» (catalog, in which profiles, limits and reminder settings) | Live (window captures) |
| «режим» → «профиль» everywhere in the interface, 13 languages (gender fixed in de, it; particles in ko; Arabic «ملف التعريف»), custom template names | Script check (no mode word left except «background mode») |
| Reordering and hiding blocks by hand in «Профили» → «Панель», switching between two profiles with different menu bars | Oleh |

## Profiles stage 3: empty start and new assistant (SPEC-profiles §9.3, 2026-10-30)

| Scenario | Checked |
|---|---|
| Without `_daily-report`: no profile, nothing installed, the assistant is due; still so on the next start | Auto (`emptyStartWithoutDailyReport`) |
| The last profile can be deleted: ClaudePult is empty, nothing installed, no assistant pushed on later starts | Auto |
| With `_daily-report` (Oleh): the first profile is made from the existing settings, as before | Auto + live (`--modes` after install) |
| Assistant «Что будет в панели»: without «Проекты» the project steps are skipped; switching projects back on restores source and calendar; «Ближайшее» only with folder projects | Auto (`modulesDecideTheSteps`) |
| Limits are not fetched or scanned while no profile uses «Лимиты AI» | Code (`UsageStore.isActive`) |
| The empty panel («Создайте первый профиль», «Помощник…», «Импортировать файл…») and the new assistant step on screen | Oleh — can't be shown here without removing Oleh's profiles |

## Profiles stage 4: «Ресурсы Mac» and optional modules (SPEC-profiles §9.4, 2026-10-30)

| Scenario | Checked |
|---|---|
| A real reading: processor, memory 16 ГБ, disk, network, graphics, no battery on this Mac, top processes | Live (`--resources`, compared with `sysctl`, `df`, `pmset`) + auto (`aRealReadingIsSane`) |
| Alerts once per event: processor only after 5 minutes above 90 %, again only after it cleared; memory critical; disk below the limit with a margin to clear; battery below 15 % only on battery | Auto (`alertsOncePerEvent`) |
| «Процессор» and «Память» in the menu bar: number with a chip symbol, ring or bar, «от N %»; nothing without the module | Auto (`menuBarShowsProcessorAndMemory`) |
| Install adds to the current profile; a profile can add, move and drop it; «Снять» removes it everywhere; built-in modules are not installed by hand | Auto (`OptionalModuleTests`) |
| The block in the panel with real figures | Live (panel snapshot; the module was added to Oleh's profile for the check and the profile restored) |
| Installing from Settings → «Модули», «Добавить модуль» in a profile, the menu bar elements, a real notification | Oleh |

## Profiles stage 5: «Не спать» (SPEC-profiles §9.5, 2026-10-30)

| Scenario | Checked |
|---|---|
| Rules in order: manual (until off or a timer that ends by itself), while Claude works, on power, external display, chosen apps; only «пока работает Claude» on by default; old settings decode | Auto (`KeepAwakeTests`) |
| Without the module nothing is held, a manual hold included | Auto (`KeepAwakeControllerTests`) |
| ☕ in the menu bar only while held | Auto |
| The «Разработчик» template ticks the module in the assistant, others don't | Auto |
| With the module and this Claude session working: `pmset -g assertions` shows «ClaudePult keep awake» (PreventUserIdleSystemSleep) within seconds of launch, the panel says «держу: работает Claude»; after the profile was restored — no assertion | Live (module added to Oleh's profile for the check, profile files restored) |
| Timers, «Отпустить», «Не гасить и экран», the power / display / apps rules on a laptop | Oleh |

## Profiles stage 6: quick commands, toggles, «Утилиты Mac» (SPEC-profiles §9.6, 2026-10-30)

| Scenario | Checked |
|---|---|
| What each kind of command runs (zsh script, Terminal, `shortcuts run`, a link or a `~` path), empty commands refused, the examples valid; the notification text is the last output line, cut to 140 | Auto (`QuickToolsTests`) |
| Only «Очистить корзину» asks first | Auto |
| «Утилиты Mac» exists in all 13 languages with no source and the four tools shown; «Свой» stays last; the assistant ticks its modules, hides limits and sessions and skips the project questions; adding it from Settings needs no folder and installs its modules | Auto (`UtilitiesTemplateTests`) |
| The panel with both modules (real window capture): two command buttons, six toggles, desktop icons shown as on; «Мой IP в сети» clicked — the address appeared under the buttons, `exit 0` in the log | Live (modules added to Oleh's profile for the check, profile restored) |
| Dark mode, desktop icons (restarts Finder), lock, display off, eject, empty Trash — they change the Mac, not run here | Oleh |


## Second wave: «История буфера» and «Заметки» (SPEC-profiles §9.7, 2026-10-30)

| Scenario | Checked |
|---|---|
| Concealed / transient copies and copies from excluded apps are not recorded; a repeat moves up and keeps its pin; pinned entries survive the limit and «Очистить»; blank copies ignored | Auto (`ClipboardNotesTests`) |
| Note names from `.md` files only, hidden files skipped, free names «Заметка 2» …; writing, reading, creating and removing notes in a folder | Auto (`NotesStoreTests`, temporary folder) |
| The panel with both modules (real window capture): copies from Terminal appear on top with «только что»; a copy marked `org.nspasteboard.ConcealedType` did not appear; the notes block made its folder and a first note | Live (modules added to Oleh's profile and a temporary notes folder for the check; profile, setting and clipboard restored) |
| Pin, search, click to copy back, «Помнить после перезапуска», a copy from 1Password, typing a note and switching tabs | Oleh |

## Second wave: «Не спать» with the lid closed (SPEC-profiles §9.7, 2026-10-30)

| Scenario | Checked |
|---|---|
| The sudoers rule allows only `pmset -a disablesleep 0` and `1`; unsafe user names refused; the rule text passes `visudo -c` | Auto (`LidSleepTests`) + `visudo -cf` |
| Wanted only while a rule holds, the option is on, the permission is there and the Mac has a lid; on battery below 20 % let go | Auto |
| Undoes only its own change: sleep turned off by another app is left alone; `SleepDisabled` read from `pmset -g` | Auto |
| Old rules decode without the option | Auto |
| Settings on this Mac mini (real window capture): «У этого Mac нет крышки», the switch and «Разрешить…» disabled, «Сейчас сон уже отключён другим приложением» (Vorssaint's `SleepDisabled 1`); ClaudePult ran no `pmset`/`sudo` (log, `pmset -g`) | Live (module installed temporarily, profile restored) |
| «Разрешить…» with the password, the lid closed while Claude works, the battery floor, «Убрать…» | Oleh — needs a laptop and the admin password |

## Hover hints for icon-only controls (SPEC §3.1, 2026-10-30)

| Scenario | Checked |
|---|---|
| Accessibility walk of the panel with every module shown and of all seven settings tabs: icon-only controls without a hint found (☕ and timers, quick-command editor arrows, trash and icon picker, clipboard row icon, worktree label, calendar arrows, assistant «remove stage», the menu bar item) and given one | Live (modules added to Oleh's profile for the walk, profile and folded blocks restored) |
| The menu bar tooltip names every element that is on and has something to show, and nothing switched off | Auto (`MenuBarTests.tooltipNamesEverythingShown`) |
| The menu bar item's `AXHelp` (its tooltip) reads «ClaudePult, сессия 10 %, неделя 81 %, есть проекты с проблемами»; ☕ in the panel says «держу: работает Claude» | Live |
| Seeing the tooltips appear under the mouse | Oleh (synthetic mouse moves don't make macOS show tooltips) |

## Menu bar elements reordered by dragging (2026-10-30)

| Scenario | Checked |
|---|---|
| Dropped on an element to the right it lands after it, to the left before it; onto itself nothing changes; every element stays exactly once | Auto (`MenuBarTests.dragMovesOntoTarget`) |
| Settings → «Строка меню»: chips of the switched-on elements under the preview; «Ждут» dragged onto «Значок» (real mouse events) moved to the front, preview and list followed | Live (Oleh's profile and menu bar restored afterwards) |

## Translation review (2026-10-30)

| Scenario | Checked |
|---|---|
| No Russian inside other languages' strings, no Russian-only letters in Ukrainian (built `.lproj` tables) | Auto (`TranslationTests.noRussianLeft`) |
| Help and settings name the files ClaudePult writes in that language (`project.md`, `content-plan.md` …) | Auto (`TranslationTests.fileNamesMatchWhatIsWritten`) |
| Quoted UI names («Модули», «Строка меню» …) match those elements' own translations | Script over the catalog (left: «Команды» meaning the macOS Shortcuts app, German «Eigene/Eigener» grammar) |
| Reading the texts as a native speaker | Oleh / native speakers |

## Panel as cards, design variant A (2026-10-30)

| Scenario | Checked |
|---|---|
| Oleh's panel expanded and folded (real window captures): cards, header with profile and icons, two limit rings with resets, one-line sessions and projects, labelled toggle tiles, «Ресурсы Mac» card | Live |
| Panel theme «Тёмная» makes the panel dark (it stayed light before) | Live (theme set for the capture, back to «Как в системе») |
| Every icon-only control in the panel has a hover hint (accessibility walk) | Live |
| Hover over a session row shows its actions; clicking a project row opens its details; the profile menu with two profiles | Oleh |

## Answering permission requests from ClaudePult (2026-10-30)

| Scenario | Checked |
|---|---|
| The real hook script: allow and deny from ClaudePult reach Claude as decision JSON; without ClaudePult nothing waits; answered in Claude (PostToolUse) the wait ends; files cleaned | Auto (`ApprovalTests`, runs python3) |
| Old requests and requests from a cancelled hook are ignored; bad ids can't escape the folder | Auto |
| Notification buttons map to allow / deny / show; PermissionRequest gets a 300 s timeout, old 5 s installs are «нужно обновить» | Auto |
| Live: Claude Code 2.1.314 (haiku, default mode, isolated settings) asked to run `touch`; the panel showed «Bash: touch …» with «Отклонить» / «Разрешить»; «Разрешить» pressed → «Allowed by PermissionRequest hook», file created | Live |
| The buttons on the macOS banner itself; Oleh's own hooks after «Обновить hooks» | Oleh |

## What Claude is doing now (2026-10-30)

| Scenario | Checked |
|---|---|
| The real hook keeps the last tool call (file names as base names, commands cut to 80); Stop clears it; the words per tool | Auto (`CurrentActionTests`) |
| This session's row in the panel read «запускает scripts/build-…» while the build ran (Oleh's own hooks, real window capture) | Live |
| «тихо N мин» after 10 minutes without a tool call | Oleh (needs a stuck session) |

## Week forecast and days (2026-10-30)

| Scenario | Checked |
|---|---|
| The week's percentage split over 8 calendar days of a Monday-10:00 window by journal weights, sums to the total; forecast from the last 24 h (runs out / lasts / unknown without journals) | Auto (`WeekUsageTests`) |
| Live with Oleh's data: 84 % on Friday evening → «неделя кончится Сб 04:56 при таком темпе», bars for Mon–Mon with today highlighted | Live |
| The once-per-week notification on the banner | Oleh |

## Answering permission requests from Telegram (2026-10-30)

| Scenario | Checked |
|---|---|
| Message escapes project, tool and command; buttons carry `allow:`/`deny:` + request id; presses from other chats, tampered ids and unknown verbs are dropped; the next update offset | Auto (`TelegramApprovalTests`) |
| Settings → Claude Code shows «Ответы из Telegram»: switch, token field (Keychain), chat id, «Проверить», the note about a separate bot | Live (real window capture) |
| A real bot: a request with buttons, «Разрешить» from the phone reaching Claude | Live (2026-10-30, Oleh's second bot: «Permission allowed from Telegram», file created) |

## PR and CI alerts (2026-10-30)

| Scenario | Checked |
|---|---|
| CI pending→fail, fail→ok and a PR gone between two reports; no repeat while still failing; null PR data or a project leaving the list says nothing | Auto (`PullRequestAlertTests`) |
| The notification's click target is the PR (https only) | Auto |
| Settings → «Модули» → «Проекты» has the two switches | Live (accessibility text) |
| A real CI failure arriving as a notification | Oleh (next red CI) |

## Search, hot key and Shortcuts actions (2026-10-30)

| Scenario | Checked |
|---|---|
| Search order (sessions, projects, quick commands, commands), wrong-layout queries, no destructive cleanup in results; hot key presets distinct; the Shortcuts limits text from `usage.json` | Auto (`PanelAccessTests`) |
| ⌃⌥C from another app opened «Поиск — ClaudePult» with the cursor in the field; «завис» and «ыгкм» found the Survikon session and project; Esc clears, Esc again closes | Live (synthetic keys) |
| The three actions are in the app's App Intents metadata | Live (`Metadata.appintents`) |
| Running the actions from the Shortcuts app and Siri; the search field in the panel itself | Oleh |

## Widget «Сессии и проекты» and the Control Center toggle (2026-10-30)

| Scenario | Checked |
|---|---|
| The status file has exactly the keys the widget decodes; Darwin notifications on/off reach the app's handler | Auto (`WidgetStatusTests`) |
| Live: `widget-status.json` written (2 running, 4 red projects), the extension registered (`pluginkit`), a posted «off» request logged «Keep awake off from Control Center» | Live |
| Adding the widget from the gallery; the control in Control Center switching «Не спать» (with the module installed) | Oleh |

## Night queue (2026-10-30)

| Scenario | Checked |
|---|---|
| The next night start (later today or tomorrow); queue files saved before keep loading | Auto (`NightQueueTests`) |
| An expanded project shows «На ночь» next to «Следующий шаг» with its hint; «Своя задача…» has «На ночь» | Live (accessibility) — not pressed: it would really run at 01:00 |
| A real night: runs start at the hour, the Mac stays awake, the morning summary (notification and Telegram) | Oleh |

## Context fullness (2026-10-30)

| Scenario | Checked |
|---|---|
| The last main-thread usage line of a journal (subagent lines and user lines skipped); window 200k / 1M; a missing journal | Auto (`ContextUsageTests`) |
| Live: the panel showed «контекст 85 %» for Survikon and «контекст 79 %» for this session | Live |
| The 90 % notification | Oleh (a long session) |

## Session rows open on a click anywhere (2026-10-30)

| Scenario | Checked |
|---|---|
| A click on a session row's text (not the icon) opens it: a fake session in the scratchpad folder opened that folder in Finder (the fallback when there is no Terminal tab or app session) | Live (fake session removed afterwards) |
| A background run's row opens its log; the icons still work | Code review; Oleh |

## Widgets in 13 languages (2026-10-30)

| Scenario | Checked |
|---|---|
| The widget extension has its own string catalog: «Лимиты Claude», «Сессии и проекты», the reset texts and the «Не спать» control in 12 more languages, no Russian inside | Auto (`TranslationTests.widgetIsTranslated`, built tables) |
| The widget gallery in English | Oleh (system language; the app's own language setting doesn't reach extensions) |

## Opening sessions from their rows (2026-10-30)

| Scenario | Checked |
|---|---|
| A click on the Survikon row's name opened that session in the Claude app (its `lastFocusedAt` changed at the click; the log shows the `claude://code/continue?session=local_…` link) | Live |
| `claude` started in the Claude app's own terminal brings Claude forward instead of opening the folder in Finder | Code; Oleh |

## Release without an Apple Developer account (2026-10-30)

| Scenario | Checked |
|---|---|
| History before going public: no tokens, keys or secret files in 182 commits; author e-mails in commit headers (left as they are, Oleh's call) | Script scan |
| Keys made once as files, not in the login keychain: «ClaudePult Release» certificate (to 2036) and the Sparkle Ed25519 key | Live |
| `scripts/release.sh 0.2.0`: Release build 0.2.0 (183), signed inside out, `codesign --verify --deep --strict` passes, the widget keeps its sandbox, no get-task-allow, designated requirement bound to the certificate, the binary loads Sparkle and runs, `.dmg` checksum valid, appcast with a verified Ed25519 signature; Gatekeeper rejects it (expected without Developer ID) | Live (not published) |
| Tests with Sparkle in the host app | Auto (192 green) |
| Publishing, downloading on another Mac, «Open Anyway», a real Sparkle update from one release to the next | Oleh — needs the repository public and two releases |
| Re-check on main after the second wave, hints, drag and translation fixes: `scripts/release.sh 0.2.0` → build 202, deep strict verify OK, widget sandbox kept, no get-task-allow, requirement bound to the certificate, `.dmg` checksum valid, appcast length equals the `.dmg` and its Ed25519 signature verifies, the binary runs (`--modes`), no temporary keychain left; Gatekeeper rejects as expected | Live (2026-10-30, not published) |

