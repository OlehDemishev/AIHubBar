# Decisions

Decisions made where the spec is silent or does not match reality. Newest at the top.

## 2026-10-31 — Notch island events: from `Notifier`, requests from their files

Banners in the island (SPEC-notch §3.2) come from `Notifier.post` through one hook (`Notifier.island`), after the per-kind frequency check, so the island never shows more often than notifications would and every current and future notification is covered; the hook returns true when the person chose «только в острове» and the island is on screen, and then no system notification is posted. Permission requests are not taken from the notification: they follow `SessionStore.approvals` (the open request files), so a request stays exactly as long as Claude waits and goes when it is answered anywhere; answered ones are remembered until their file is gone so they don't flash back. «Сессия закончила» has no notification, so the island watches session states itself (working → done). «On screen» is the panel's `occlusionState` — false on a full-screen desktop, with the display asleep and on the lock screen — rather than a check of each case. The island's window is as big as the open card but takes clicks only where its black part is (`ignoresMouseEvents` follows the pointer); AppKit's prominent button styles turn grey in a window that is never key, so the request buttons have their own style.

## 2026-10-31 — Notch island: a module of the screen, not of the panel

«Остров у чёлки» (`ModuleKind.notch`, docs/SPEC-notch.md) is installed like the other optional modules but is no block of a profile's panel: `ModuleKind.isPanelBlock` is false, so installing it adds nothing to the current profile, «Добавить модуль» doesn't offer it, the catalog shows no «В профилях» row, and the assistant installs it separately from the profile's modules. The island lives at the top of the screen and doesn't change with the profile, like notifications. One window over the notch (borderless non-activating `NSPanel` above the main menu level) is always as big as the open card; at rest it ignores the mouse, and global plus local mouse monitors (no permission needed for mouse events) open it after 0.3 s on the notch or on a click and close it 0.4 s after the pointer leaves. The card says «Поиск и запуск…» instead of «Открыть панель», since the panel can't be opened from code. The island is started on the next main-queue turn after launch: `NSApp` doesn't exist yet in `App.init`.

## 2026-10-30 — Renamed to AI Hub Bar

Oleh's choice: «AI Hub Bar» (his root «AI Hub»; the app is no longer only about Claude). Renamed: everything a person sees — the app bundle (`AI Hub Bar.app`, executable `AIHubBar`), menu bar and panel, windows, notifications, Shortcuts actions, widget names, 13 languages, README / GUIDE / RELEASE, the release `.dmg` and appcast titles. Kept: bundle id `com.demishev.claudepult` (settings, Automation and notification permissions, login item), Swift module `ClaudePult`, Xcode project and scheme, `~/Library/Application Support/ClaudePult` and `~/Library/Logs/ClaudePult`, the Keychain service «ClaudePult API key», the «ClaudePult Release» signing certificate and its folder, the `*.claudepult` file type, the default notes folder «ClaudePult Notes» (existing notes stay where they are), widget and control kinds, the GitHub repository (renaming it is Oleh's call; GitHub redirects the old release URLs). `scripts/build-and-install.sh` moves an old `ClaudePult.app` to the Trash so two copies with one bundle id don't confuse macOS.

## 2026-10-30 — The hot key opens a search window, not the panel

`MenuBarExtra` (window style) can't be opened from code: `performClick` on its `NSStatusBarButton`, sending the button's action and posting mouse-down/up events into its status bar window all did nothing (checked live). So the global hot key (a Carbon `RegisterEventHotKey`, no Accessibility permission) opens a separate small «Поиск — ClaudePult» window with the same search as the panel. A third-party workaround (private `NSStatusItem` access) wasn't worth the risk.

## 2026-10-30 — Week forecast from the journals

The usage endpoint gives only the week's current percentage, and ClaudePult kept 3 hours of session history. Instead of waiting a week for its own history, the week's percentage is split over the days in the proportions of the weights in Claude Code's journals (`TokenRecord.weight`, already used for «Расход по проектам»), and the pace is the share of the last 24 hours. An estimate: the journals don't hold everything that counts (claude.ai chats), so the bars show where the week went, not exact percentages.

## 2026-10-30 — Answering permission requests from ClaudePult

**Checked live first:** with a PermissionRequest hook that sleeps, Claude Code shows its own dialog within ~2 s and doesn't wait for the hook; an allow printed by the hook later is applied («Allowed by PermissionRequest hook»). So a waiting hook never blocks the person at the terminal. **Protocol:** files in `Application Support/ClaudePult/approvals/` — `alive` (ClaudePult touches it every 15 s while the option is on; the hook waits only if it is younger than 30 s), `<id>.request.json` (written before the session record, with the hook's pid), `<id>.decision` (`allow` / `deny`). The hook stops waiting when the session moves on (answered in Claude), when ClaudePult goes away, after 290 s, or on SIGTERM (Claude's timeout), and always removes its files. ClaudePult ignores requests whose hook process is gone. The hook prints only that decision; everything else stays silent as before. The script keeps itself current even while settings.json still has the old 5 s timeout.

## 2026-10-30 — Panel as cards (design variant A)

Oleh picked variant A of three mock-ups (cards / tabs / Raycast-like list). Blocks are cards (`panelCard()`), not rows between dividers; Settings, Help and Quit moved from three large rows at the bottom to header icons with the same shortcuts; the profile switcher row became a header menu; limits are rings; sessions and projects take one line (details on hover or click). Folding blocks stays. `preferredColorScheme` never reached the `MenuBarExtra` window, so «Тёмная» left the panel light — the panel now sets its window's `appearance`.

## 2026-10-30 — Hover hints for icon-only controls (SPEC §3.1)

**Rule:** anything shown only as an icon gets `.help` with its name or a short explanation. **Menu bar item:** `MenuBarExtra` has no tooltip API, so `StatusItemTooltip` finds the `NSStatusBarButton` in the app's status bar window and sets its `toolTip` to `MenuBarComposer.accessibilityText` — the same words VoiceOver reads, now covering every element the item can draw (sessions, queued runs, reset countdown, forecast, nearest date, low disk, processor, memory, ☕, profile). If a macOS update changes that window, the tooltip silently disappears; nothing else depends on it.

## 2026-10-30 — Languages: one table per language; Spanish (SPEC-modes §9.9)

**A language is data.** Everything ClaudePult writes or sends in a language lives in `ContentStrings` (one value per `ContentLanguage`): card and plan file names, card field names, plan column names, the «idea» status, the agent and API wrappers, the generic developer prompts, and how a custom task starts and ends (for session titles). Reading accepts every language's names, so files from any language keep working; writing a value keeps the card's own language (the language whose field names it already uses). A test runs over every language and checks it is complete, so the next languages only add a table entry, template files and catalog translations.

**Spanish:** `proyecto.md` (Etapa, Fecha límite, Publicación, Formato, Archivo principal, Plataforma), `plan-de-contenido.md` (Fecha, Hora, Plataforma, Tema, Estado, Archivo), Spanish templates and prompts; placeholders stay the English ones (`{project}` …), the Russian ones keep working. Four Spanish strings were rephrased because «% de…» would read as the `% d` format specifier.

## 2026-10-30 — Languages: English content (SPEC-modes §9.9)

**Content language = interface language** (`ContentLanguage.current`, Russian when the interface is not English). It decides what ClaudePult writes and sends: template texts, the wrappers around tasks for agents and APIs, the generic developer prompts, new cards and content plans, the «идея»/«idea» status of a new plan row. Oleh's own developer prompts (his mode) stay Russian and unchanged.

**Templates:** a translation is `template-<id>.<language>.json` next to the Russian original; the loader takes the interface language's version, else the original. Translated templates keep the same ids and commands (checked by a test). Placeholders have English names (`{project}`, `{file}`, `{format}`, `{platform}`, `{duration}`, `{language}`, `{text}`, `<time>`, `<file>`); the Russian ones keep working, so modes created in one language still run in the other.

**Files:** `проект.md` / `project.md` and `контент-план.md` / `content-plan.md` are both read (the first that exists wins); a new one gets the interface language's name. Field names were already read in both languages; when ClaudePult writes a value it uses the language the card is already written in (all labels Latin → English), so a Russian card stays Russian under an English interface and the other way round.

## 2026-10-30 — Languages: English interface (SPEC-modes §9.9)

**Russian stays the source language** (`developmentLanguage: ru`, String Catalog with `sourceLanguage: ru`): the code keeps its Russian strings, translations live in `Localizable.xcstrings`. SwiftUI localizes literals in `Text`, `Button`, `Label`, `Toggle`, `Picker`, `Section`, `.help` … by itself; every other user-visible string (model titles, errors, notifications, Telegram texts, help items) is wrapped in `String(localized:)` — 539 places, done by a script with exclusions and then checked by building.

**Not translated, on purpose:** file formats (`проект.md` and `контент-план.md` field names and templates — English synonyms are already read), the prompts sent to AI services and their wrappers, the hook script, log lines and command-line output. Template JSON (mode names, stages, command texts) and these prompts get English versions in the next step; until then an English interface shows Russian template content.

**Catalog upkeep:** keys come from the compiler's `.stringsdata` (`SWIFT_EMIT_LOC_STRINGS`) via `xcrun xcstringstool sync`; translations were checked by a script for missing keys and matching format specifiers. Localized interpolation formats numbers by the system region («1 500 сл.»).

**Language choice:** Settings → Основные → «Язык интерфейса» writes the app's own `AppleLanguages` and relaunches; «Как в системе» removes it.

## 2026-10-30 — Setup assistant (SPEC-modes §9.7)

**A draft, saved only at «Готово».** `AssistantDraft` holds the mode plus the global choices the assistant asks about (menu bar preset, hidden panel blocks, reminder offsets); «Готово» writes them, creates the folder if it does not exist yet and adds the mode as current. Steps that only make sense for folder projects (stages, metrics, calendar, commands) are skipped for git sources. «Пропустить» keeps the template's value.

**Folder analysis.** The chosen folder's subfolders are counted; if git repositories are at least half of them the source becomes the built-in git scanner (card STATUS.md, permissions «код»), otherwise folder projects (card проект.md, «только файлы»). The person can switch it on the same screen.

**First start.** With `_daily-report/report.py` present (Oleh) the old settings still become his mode. Without it ClaudePult creates a starter placeholder (no projects) and opens the assistant, starting with «Перенести настройки?» (import of a `.claudepult` file); the assistant's mode replaces the placeholder.

**Panel block order** stays fixed (limits, sessions, «Ближайшее», projects, commands) — the assistant only switches blocks on and off; SPEC §5 «и их порядок» is left for later.

**Preview** draws the panel from the draft on sample data (names by template, stage chips, metrics as the real rows compute them, command chips) and the real menu bar renderer; `--assistant-preview` renders it to PNG for checks.

## 2026-10-30 — Templates and the built-in git scanner (SPEC-modes §9.6)

**Templates are JSON in the app** (`Resources/Templates/template-*.json`: id, title, description, folder hint, order, and a whole `Mode`). Adding a mode copies the template's mode with a fresh id, a unique name and the folder the person picks; from then on it is their mode. Texts are those of docs/TEMPLATES.md as written (Oleh chose «как есть»); two «Соцсети» commands were adapted so that commands never change existing files (see the note in TEMPLATES.md), and commands that read the whole project default to Claude.

**Built-in git scanner** (`GitScanner`) gives the same JSON shape as `report.py --json`, so the panel code is shared. Same rules for attention and health: uncommitted work (STATUS.md-only changes low), stashes, branches only on this Mac / unpushed (a branch pushed under the same name without tracking counts only unpushed commits), worktrees with changes and stale ones, PRs with CI via `gh`, «Needs …» items from the STATUS.md summary (any name after «Needs»), stale repos (7 days). Not taken over: report.py's «commits but STATUS.md not updated» (tied to its daily window), merged PRs and commit lists (report text only). Repositories are scanned in parallel. Compared live with report.py on ~/Projects: identical health and items otherwise.

**Prompt style.** Oleh's mode (`template == developer-report`) keeps the prompts of docs/SPEC.md §2.4 with `~/Projects/CLAUDE.md`; every other git mode uses the generic ones of docs/TEMPLATES.md §1 («работай по правилам проекта: CLAUDE.md / AGENTS.md, если они есть»). Session titles recognise both.

## 2026-10-30 — Calendar (SPEC-modes §9.5)

**No calendar of ClaudePult's own.** Every date lives in the person's files: `Дедлайн:` / `Публикация:` in `проект.md`, rows of `контент-план.md`. The calendar is read from them (all enabled modes with a calendar, on panel open if older than 60 s and every 5 min) and moving a date writes the file back — only that line or that cell changes.

**`контент-план.md`.** The first Markdown table with a «Дата»/«Date» column and a separator line is the plan; columns are matched by header (Дата, Время, Площадка, Тема, Статус, Файл, or English), others are kept. A new row gets the same number of cells as the header; a file without a table gets the standard one. Plans are read from the mode folder and from every project folder (a campaign's own plan). A row whose «Файл» exists opens that file.

**Overdue.** A date-only deadline is overdue from the next day, a timed one after its time. «Ближайшее» shows 7 days ahead plus overdue deadlines (until moved) and yesterday's publications and plan rows.

**Reminders** at the chosen offsets (default: a day before); for each entry only the closest offset that has come is announced, each once (keys in `calendar-reminded.json`), never after the date. Telegram is optional and off by default.

**Week starts** follow the system calendar (Monday in Russian). Colours go by mode. `.ics` export and the system Calendar (EventKit) stay for later (SPEC-modes §9.10).

## 2026-10-30 — Command engine (SPEC-modes §9.4, part 2)

**Where a command runs.** Models by API: ClaudePult sends the main file's text with the API wrapper from docs/TEMPLATES.md and writes the answer itself. Claude Code: background `claude -p` with the mode's permission profile, or Terminal when the mode's «Где запускать» is Terminal («спрашивать» runs in the background for folder modes — with «только файлы» nothing outside the folder can change). Other agents: Terminal only, task on the clipboard («вставьте ⌘V») — the same honest limit as stage 3 until their permission modes are checked live.

**«Только файлы» / «Файлы + поиск в интернете»** are Claude Code rules: allow `Read`, `Glob`, `Grep`, `Edit(./**)`, `TodoWrite` (+ `WebSearch`, `WebFetch`); deny `Bash`, `NotebookEdit` (+ web for files-only) and the secret-file reads of the code profile; `blockReadsOutsideWorkingDirectories`. Checked live with a real `claude -p` 2.1.312: the file was written, Bash and web were not even offered as tools, `~/.zshrc` was blocked; with web, a page was fetched into a file and Bash stayed unavailable. (The run also renewed the Keychain token, confirming the expired-token note.)

**Result files** are named from the template, `<время>` = `yyyy-MM-dd-HHmm`, `<файл>` = the input file's base name, `/ : \` replaced, `.md` added; an existing name gets `-2`, `-3` … The background run checks the file exists after success and says so if not.

**API.** Anthropic Messages (`x-api-key`, `anthropic-version: 2023-06-01`, `max_tokens` 16 000) and OpenAI-style chat completions for the others; every chat endpoint answered «bad key» to an invalid one (2026-10-30). Prices are not shipped — they change; the person enters dollars per million tokens per provider, and costs are shown only where a price exists. Spend is kept 400 days in `api-spend.json`; budget warnings once per month at 80 % and 100 %.

**«Сравнить»** runs the same command with the chosen services in parallel; names get ` (Claude)`, ` (OpenAI)` … before the extension; the «Сравнение» window shows the files side by side, refreshing every 2 s. No verdicts.

## 2026-10-30 — Folder projects (SPEC-modes §9.4, part 1)

**`проект.md` stays the person's file.** Fields are plain lines `Ключ: значение` (list markers and bold allowed; English synonyms `stage`, `deadline`, `publish`, `format`, `main file`, `platform` accepted for later languages). ClaudePult changes only the line it writes (`Этап:`), keeping everything else; a new card is created only where none exists. Empty fields in the template are not values.

**Main file and words.** The main file is `Главный файл:` from the card, else the most recently changed text file (`.md`, `.txt`, `.rtf`, `.docx`, `.fountain`). Words come from macOS word boundaries, counting only tokens with letters or digits; link addresses in Markdown are left out. Duration uses the mode's pace (150 words/min by default, SPEC-modes §3), reading time 200 words/min, a page 250 words. Sources: PDFs anywhere plus any file in `источники` / `sources` / `материалы`.

**Scanning.** Up to three levels deep and 2000 files per project, hidden files, `node_modules` and `build` skipped; folders starting with `_` are not projects (archive, templates). Off the main actor, on panel open if older than 60 s and every 5 minutes.

**report.py only for report modes.** `AppSettings.activeSource` (set when a mode is applied, not stored) tells `ProjectStore` to skip `report.py` and `FolderProjectStore` to scan; this is also what makes ClaudePult usable without `_daily-report`. A mode's source can now be switched in Settings; the built-in git scanner stays for stage 6.

**Stage colours** go from blue (first stage) to green (last), so progress is visible without reading.

## 2026-10-30 — AI services, connection part (SPEC-modes §9.3)

**Checked against the docs (2026-10-30), not memory.** Model lists: Anthropic `GET /v1/models` (accepts `x-api-key` and Bearer; we send `x-api-key` + `anthropic-version: 2023-06-01`), Google `…/v1beta/openai/models` (OpenAI-compatible, Bearer), DeepSeek `https://api.deepseek.com/models`, Mistral `/v1/models` (docs show both `{data: […]}` and a bare array — both parsed). OpenAI's docs refused the fetch (403) and xAI's docs do not list `/models`; for all six an unauthenticated request was made: each answered «bad key» (401, or 400 for Google and xAI), not 404, so the paths exist. A bad key may come back as 400/403 — it counts as «Ключ не подошёл» when the message names the key.

**Agents.** Codex CLI (`codex`, `codex exec`, `--sandbox read-only|workspace-write|danger-full-access`), Gemini CLI (`gemini -p`, `--approval-mode default|auto_edit|yolo|plan`), Copilot CLI (`copilot -p`, `--allow-tool` / `--deny-tool`) are confirmed by their docs. Since June 2026 the free Google sign-in and Google AI Pro/Ultra moved from Gemini CLI to **Antigravity CLI** (`agy`), so it is listed too; its flags were not checked. Cursor's CLI docs could not be read (404) — the binary name `cursor-agent` is from memory and only used to find the program. For now no agent but Claude Code runs in the background: they open in Terminal («Открыть в…») until their «no actions» modes are checked live on this Mac (SPEC-modes §11.1).

**Keys.** Written and read with `/usr/bin/security` (like the Claude Code token): an ad-hoc-signed app would be asked for Keychain access after every rebuild. The key goes to `security -i` on stdin, never as an argument (arguments are visible in `ps`); keys are limited to `A–Z a–z 0–9 . _ - ~ + / = :` (8–512 chars), which covers real keys and needs no quoting. «Проверить» lists models — no tokens spent. The OpenAI-compatible server (default Ollama `http://localhost:11434/v1`) works without a key.

**Moved to stage 4:** running a command with a chosen service (needs the command engine), API spend per day/month and the budget (needs those requests), sessions of other agents by process, «Сравнить». The mode's «Сервис по умолчанию» is stored now (`Mode.service`, nil = Claude Code), so templates can use it.

## 2026-10-30 — Menu bar builder (SPEC-modes §9.2)

**Config.** `MenuBarConfig` (JSON in UserDefaults key `menuBarConfig`, and in exports as `appearance.menuBarConfig`) always lists every element kind once; its order is the menu bar order and each element is on or off with its own options. Unknown kinds from newer files are dropped, missing ones are added switched off. The old `menuBarUsageMode` is only read to migrate (icon only → «Минимум»; session, session + week, ring → «Лимиты» with the same gauges), and exports still write a `menuBar` value derived from the config so older ClaudePult versions can import the file.

**Composer and renderer.** `MenuBarComposer.groups(config, data)` is a pure function (tested) that turns the config and the current data into groups of segments; `MenuBarRenderer` draws them into one non-template image as before. A lone symbol is still shown as a template image, like a system item. If nothing is left to show (icon hidden, no events), the sparkle is drawn anyway — an empty item could not be clicked.

**Separator.** The chosen separator («·», «|», space) goes only between two values (numbers, rings, bars); icons and counters are set apart by a 4 pt gap. With «·» this keeps Oleh's look «✦ 34% · 58% ✋1».

**✋.** The waiting counter is now the SF Symbol `hand.raised.fill` in the menu bar colour instead of the ✋ emoji, matching the other counters (bolt — running sessions, moon — background runs, clock — queue).

**Order** is changed with ↑ / ↓ buttons on each row (up = further left): a grouped `Form` on macOS does not support drag-to-reorder. **Width warning** above 180 pt: on a MacBook with a notch wider items can be hidden.

**Not yet:** «Ближайший дедлайн» is listed but disabled until the calendar (stage 5); per-mode additions come with mode blocks (stage 4). Running sessions in the menu bar count Claude Code sessions in state «running» from the hooks.

**Check without the screen.** `ClaudePult --menubar-preview <file.png> [preset]` draws the item with sample data on a dark and a light band, because the shell cannot capture the screen.

## 2026-10-30 — Usage endpoint: 429 backoff

The usage endpoint started answering HTTP 429 (seen at the 1-minute pace plus app restarts and command-line checks). It sends `Retry-After: 0` while still refusing, so that header is only trusted when it asks for longer than our own pause. Now: after a 429 no request is made for 5, 10, 20, 40, then 60 minutes (or longer if `Retry-After` says so); the panel says «Сервер лимитов просит запрашивать реже — следующая попытка в HH:mm» and the refresh button waits too. The active interval is 2 minutes instead of the spec's 1 (idle stays 5). The last snapshot is kept in `usage-snapshot.json` (up to 24 h), so a restart shows the limits at once and does not fetch again if the last fetch is younger than the active interval.

## 2026-10-30 — Modes, stage 1 (SPEC-modes §9.1)

**A mode is applied to `AppSettings`.** Each mode stores its own blocks (JSON in `Application Support/ClaudePult/modes/`); the active mode pushes the ones that already exist in the app — projects folder, `_daily-report` folder, launch mode, the projects and common-commands blocks — into `AppSettings`, which the rest of the app keeps reading. That keeps stage 1 free of behaviour changes; later stages read the mode directly where a block has no `AppSettings` counterpart (stages, templates, calendar).

**Migration.** On the first start without modes, the current settings become one mode, source «git via report.py», common commands `_daily-report`, card STATUS.md. Its default name is the neutral «Разработчик (мой)» (the macOS account's full name does not reliably give a first name — here it is «Demishev Oleh»); Oleh's mode was renamed to «Разработчик — Олег».

**Moved settings.** Projects folder and `_daily-report` folder left Settings → Основные, the launch mode left Settings → Claude, and the projects/commands toggles left «Внешний вид»: they are per mode now (Settings → «Режимы»). Limits and sessions stay global.

**Files.** `*.claudepult` is JSON (`format`: `claudepult-settings` for everything, `claudepult-mode` for one mode, `version`), declared as a UTI (`com.demishev.claudepult.settings`, conforms to JSON) with ClaudePult as owner, so a double click opens the import. Home paths are written as `~/…`; nothing secret is in the file (keys and tokens live only in the Keychain). Decoding is tolerant: unknown blocks or values from newer versions fall back to defaults instead of failing. Import «Добавить режимы» gives modes fresh ids and unique names; «Заменить все настройки» replaces modes, general settings, appearance and the menu bar setting. Folders missing on this Mac are shown in red with «Выбрать…».

**Panel switcher** appears only with two or more enabled modes; at least one mode always stays enabled and one always exists.

## 2026-10-30 — Clickable notifications and the notification permission

**Found:** notifications had never been shown since stage 4. `requestAuthorization` returned `UNErrorDomain 1` («Notifications are not allowed for this application») — the first system prompt had been declined or dismissed, and macOS does not ask again. The app cached the refusal and stayed silent: no «ждёт ответа», no background results, no limit alerts. Ad-hoc signing is not the cause: after Oleh switched notifications on in System Settings, the same build reports `authorized` and banners arrive.

**Now:** the permission is read before every notification (turning it on works without a restart); a refusal is logged; the panel shows «Уведомления ClaudePult выключены…» with «Включить…» (System Settings → Notifications → ClaudePult) while they are off; Settings → Основные shows the state with «Разрешить» / «Открыть настройки» / «Проверить» (test notification). CLI: `--notifications-status`, `--app-command test-notification`.

**Clicks.** Each notification carries a target in `userInfo`: waiting session → «Показать» (its Terminal tab, Claude app or folder); background run → its PR if there is one, else «Журнал» (buttons «Открыть PR» / «Журнал»); report / summary → `latest.html`; cleanup → the cleanup output window; the test notification → Помощь. Banners also show while ClaudePult is active. Checked: the click on the test notification reached the app («Notification click: openWindow(id: "help")»).

## 2026-10-29 — Widgets

**Built after all, without an App Group.** Stage 8 assumed a WidgetKit extension needs an App Group and therefore a signing team. A widget extension must be sandboxed, but it can read ClaudePult's data through the sandbox entitlement `com.apple.security.temporary-exception.files.home-relative-path.read-only` = `/Library/Application Support/ClaudePult/`; with ad-hoc signing macOS registers and runs the extension (checked: `pluginkit` lists `com.demishev.claudepult.widget`, the widget gallery shows ClaudePult, and the widget's log shows it reading `usage.json` with the same values as the file). Inside the sandbox `NSHomeDirectory()` is the container, so the real home comes from `getpwuid`.

**What it shows**: small — a ring with the session %, coloured like the app, and the reset countdown; medium — session and week bars with resets and «обновлено …». No data → «Нет данных — откройте ClaudePult». ClaudePult asks WidgetKit to reload after every usage update; the widget's own fallback is every 5 minutes.

**Packaging**: XcodeGen target `ClaudePultWidget` (app-extension, embedded in `Contents/PlugIns`), its Info.plist and entitlements generated from `project.yml`.

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

**Widgets not built in this stage** — the App Group reasoning turned out wrong; see «Widgets» above, where they were built.

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

**«Показать».** Terminal.app sessions: AppleScript finds the tab whose `tty` matches and brings its window forward. Desktop-app sessions (`CLAUDE_CODE_ENTRYPOINT=claude-desktop`): find the app's record whose `cliSessionId` (or `previousCliSessionIds`) is the hook's `session_id` in `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json` and open `claude://code/continue?session=local_…` — the link the app itself offers; without a record, just open Claude. Otherwise the folder in Finder. The tty check comes first because the entrypoint variable can be inherited.

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
