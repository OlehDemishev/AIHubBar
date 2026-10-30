# Status

<!-- summary:start -->
**Stage:** SPEC-modes and SPEC-profiles done (release tooling ready without Developer ID, not published yet)
**Updated:** 2026-10-30

**Now:**
- merged: menu bar drag reordering (PR #93), translation review (PR #94), release build re-checked on main (PR #95)
- nothing in progress; the rest of Next waits for Oleh (translations read, CHECKLIST findings, Windows/Linux go-ahead, publishing)
- hover hints for icon-only controls and the menu bar item merged (PR #91)
- second wave merged: «История буфера» and «Заметки» (PR #87), «Не спать» with the lid closed (PR #89)
- release without an Apple Developer account merged (PR #85): Sparkle, self-signed signing, `scripts/release.sh`, MIT license; nothing published yet
- Windows and Linux specs merged (PR #73); implementation waits for Oleh

**Next:**
- standing rule (SPEC §3.1): every new icon-only control gets a hover hint; finish each UI stage with the accessibility walk
- fix whatever Oleh finds in the translations (automated checks pass; a native read for ja, ko, ar is still worth it)
- stage 8: done without Developer ID (self-signed + Sparkle, PR #85; re-checked on main); notarization only if Oleh buys Developer ID; publishing is Oleh's step (Needs Oleh)
- Fix whatever Oleh finds in docs/CHECKLIST.md
- Windows and Linux versions (docs/SPEC-windows.md, docs/SPEC-linux.md) — only when Oleh says; stage 0 (fact checks in VMs) first

**Needs Oleh:**
- hover over the menu bar item and the panel icons: tooltips should name what each one is
- on a laptop: Settings → «Модули» → «Не спать» → «Разрешить…» (admin password once), then «И с закрытой крышкой»
- on this Mac mini sleep is already off system-wide (`SleepDisabled 1`, set by Vorssaint's `/etc/sudoers.d/vorssaint-clamshell`): the Mac never sleeps while it stays so; `sudo pmset -a disablesleep 0` turns it back on if Vorssaint isn't needed
- try «История буфера» and «Заметки»: Settings → «Модули» → «Установить» (copy, pin, search; type a note)
- check the Trash for a test note «Заметка.md» from an early test run and delete it
- back up `~/Library/Application Support/ClaudePult-release/` (signing certificate and update key; without them updates break)
- to share ClaudePult: make the repository public, then `scripts/release.sh 0.2.0 --publish` (docs/RELEASE.md)
- try «Быстрые команды» and «Быстрые переключатели» (Settings → «Модули» → «Установить»), or the «Утилиты Mac» template; the toggles change the Mac, so they were not pressed during checks
- try «Не спать»: Settings → «Модули» → «Установить»; with Claude working the panel says «держу: работает Claude» (check with `pmset -g assertions`)
- try «Ресурсы Mac»: Settings → «Модули» → «Установить», then the panel block; optionally «Процессор» / «Память» in Settings → «Строка меню»
- try Settings → «Профили» → «Панель» (hide or move a block) and two profiles with different menu bars (Settings → «Строка меню» edits the current one)
- decide SPEC-windows §10 and SPEC-linux §10: Tauri 2 as one codebase for Windows and Linux, Windows code signing, first-wave Linux desktops
- after ~20:11 today: check that the limits keep updating by themselves (the sign-in renewal runs when the token expires)
- read docs/GUIDE.md as a newcomer would
- review the languages: Settings → Основные → «Язык интерфейса» → a language → «Перезапустить» (and back); Arabic should mirror right-to-left
- try Settings → Профили → «+» → «Помощник…»: the new «Что будет в панели» step (untick «Проекты» and the project questions disappear)
- try the calendar in a folder profile: «Календарь» → «+ контент-план», a `Дедлайн:` in a `проект.md`, then the panel «Ближайшее» and the «Календарь» window
- try folder projects: duplicate a profile, set «Источник» → «папки» on a folder with a few subfolders, add stages (e.g. «идея, сценарий, монтаж, готово») and metrics
- try Settings → «Строка меню» (presets, order, options, preview) and the ticking reset countdown
- try Settings → Профили (duplicate the profile → switcher appears in the panel) and a double-click on a .claudepult file
- try Settings → Профили → «+» → a template; template texts can still be reviewed in docs/TEMPLATES.md
- for live checks of AI services: install Codex CLI (`brew install --cask codex`) and Gemini CLI (`brew install gemini-cli`) or Antigravity CLI, put API keys in Settings → «Сервисы AI» and press «Проверить» (optional: Ollama for a free local model)
- optional later: Apple Developer Program (Developer ID, notarization) to drop «Open Anyway»; decide on the name before wide sharing (SPEC-modes §10.4)
- try the «Внешний вид» settings tab (theme, width, density not checked by eye)
- optional, in _daily-report (not changed by ClaudePult): report.py/bot.py could read `~/Library/Application Support/ClaudePult/usage.json` (`five_hour`, `seven_day`, `updated`) for a /limits bot command or a limits line in the report
- go through the «Oleh» rows of docs/CHECKLIST.md (buttons inside the panel, Settings, notifications, Telegram messages) — automation cannot click inside ClaudePult
- hooks are installed in ~/.claude/settings.json; backup of the original: ~/.claude/settings.json.claudepult-backup-20261029T192827
- delete or archive the old repo `OlehDemishev/ClaudeBar`; turn on start at login if wanted
<!-- summary:end -->

## 2026-10-30 — Release build re-checked on main (branch `chore/release-check`)

Done: stage 8 is closed as far as it goes without Apple: `scripts/release.sh 0.2.0` on today's main (second wave, lid rule, hints, drag, translation fixes) builds and signs; SPEC-modes stage 8 and the STATUS plan now say so (notarization only with a Developer ID; publishing is Oleh's).
Checked: build 0.2.0 (202); `codesign --verify --deep --strict` OK; widget keeps its sandbox; no get-task-allow; designated requirement bound to the «ClaudePult Release» certificate; `.dmg` checksum valid; appcast length = `.dmg` size, Ed25519 signature verifies; the release binary runs `--modes`; the temporary keychain is gone; Gatekeeper rejects (expected without Developer ID). Nothing published.
Left: publishing (repository public, `scripts/release.sh 0.2.0 --publish`) — Oleh.

## 2026-10-30 — Translation review (branch `fix/translation-review`)

Done: automated review of the 12 machine translations. Found and fixed: the English interface named Russian files (`проект.md`, `контент-план.md`, `результат-<время>.md`, «хуки (Claude).md», Russian card field names in the help) although English content uses `project.md`, `content-plan.md`, `result-<time>.md` and English field names — 12 strings; the lid-closed footer kept the Russian module name «Не спать» in all 11 other languages; Ukrainian called the help window «Довідка» where the window is «Допомога». New `TranslationTests` keep it so: no Cyrillic in non-Cyrillic languages, no Russian-only letters in Ukrainian, file names in texts equal to what ClaudePult writes per language.
Checked: 205 tests green; scripts over the catalog: format specifiers, quoted UI names against their own translations, Cyrillic leaks, untranslated copies.
Left: a native read (ja, ko, ar first) — the checks catch leaks and mismatches, not awkward wording.

## 2026-10-30 — Menu bar elements reordered by dragging (branch `feat/menubar-drag`)

Done: Settings → «Строка меню» shows the switched-on elements as chips under the preview, in menu bar order; dragging one onto another moves it there (rightwards after, leftwards before — `MenuBarConfig.move(_:onto:)`), each chip's hover hint is the element's full name. The grouped Form keeps its ˄ ˅ buttons. 13 languages.
Checked: 203 tests green; live: «Ждут» dragged onto «Значок» with real mouse events moved to the front; Oleh's profile and menu bar settings restored.
Left: —

## 2026-10-30 — Hover hints for icon-only controls (branch `feat/hover-hints`)

Done: Oleh asked for a short hint, or at least the function's name, on everything shown only as an icon. Walked the panel (all modules shown) and all settings tabs through Accessibility, listing controls with neither a name nor a hint; added `.help` to ☕ and the timers in «Не спать», the quick-command editor (arrows, trash, icon picker), the clipboard row icon, the worktree label in sessions, the calendar's previous/next arrows and the assistant's «remove stage». The menu bar item now has a tooltip (`StatusItemTooltip` sets the status bar button's `toolTip`) with a summary of everything it draws; `MenuBarComposer.accessibilityText` covers all elements. Made a standing rule in SPEC §3.1. 13 languages.
Checked: 202 tests green; live: the menu bar item's AXHelp is the summary, ☕ has its hint; profile and folded blocks restored.
Left: seeing tooltips pop up under a real mouse (synthetic moves don't trigger them) — Oleh.

## 2026-10-30 — Keep awake with the lid closed (branch `feat/lid-closed-awake`)

Done: last item of the SPEC-profiles second wave. «Не спать» gets «И с закрытой крышкой»: a power assertion doesn't survive a closed lid, so ClaudePult runs `sudo -n pmset -a disablesleep 1` while any rule holds and `0` when none does, on quit, when the module is removed and on battery below 20 %. «Разрешить…» asks for the administrator password in macOS's dialog (`osascript … with administrator privileges`) and installs `/etc/sudoers.d/claudepult` (checked by `visudo` under a dotted name sudo ignores, then moved in), allowing only those two commands; «Убрать…» turns sleep back on and removes it. ClaudePult undoes only what it did (remembered across launches, so a crash is fixed on the next start); sleep turned off by another app is left alone and the settings say so. Macs without a lid get the section disabled. Panel shows «и с закрытой крышкой» while it holds. 13 languages.
Checked: 201 tests green; rule text `visudo -cf` OK; live on this Mac mini: the section says there is no lid and that sleep is already off by another app; no `pmset`/`sudo` run by ClaudePult (log, `pmset -g`); profile restored.
Left: the real path (password, closed lid, battery floor, removing) needs a laptop — not run here (Mac mini, and the password is Oleh's). Found: Vorssaint keeps `SleepDisabled 1` on this Mac.

## 2026-10-30 — Clipboard history and notes modules (branch `feat/clipboard-notes`)

Done: two optional modules from the SPEC-profiles second wave. «История буфера» watches the pasteboard only while installed (every 0.7 s): text and copied files, limit 20/50/100/200, search, pins, a click copies back; secrets are never recorded (nspasteboard.org concealed/transient/auto-generated markers, 1Password markers, and anything copied while a password manager or Keychain Access is in front; the app list is editable in «Модули»); memory only unless «Помнить после перезапуска» (`clipboard.json`, 0600). «Заметки»: Markdown files in `~/Documents/ClaudePult Notes` (changeable), tabs, autosave after 1 s and on closing the panel, delete to the Trash, open in the default editor. Both in the catalog, the assistant's «Что будет в панели» step, collapsible blocks, 13 languages.
Checked: 196 tests green (`xcodebuild test`); String Catalog synced, all new strings in 12 translations; live: modules added to Oleh's profile with a temporary notes folder, the panel showed copies on top, a concealed copy was not recorded, the notes block made a first note; profile, setting and clipboard restored.
Left: keep awake with the lid closed (separate PR, needs a sudoers rule and Oleh's admin password). One early test run moved a test «Заметка.md» to the real Trash (fixed: tests now delete in a temporary folder). Pin, search, copy-back, «Помнить после перезапуска» and typing notes were not clicked through by hand.

## 2026-10-30 — Release without an Apple Developer account (branch `feat/release-without-apple`)

Done: history checked before going public (no secrets; author e-mails stay — Oleh's call). MIT `LICENSE`. Sparkle 2.6.4 via SPM: feed `releases/latest/download/appcast.xml`, `SUPublicEDKey`, daily checks, «Обновления» in Settings → Основные («Проверять раз в день», «Проверить сейчас»). One-time keys as files in `~/Library/Application Support/ClaudePult-release/` (not the login keychain): a self-signed «ClaudePult Release» code signing certificate (`scripts/release-tools/make-signing-cert.sh`) and an Ed25519 update key (`scripts/release-tools/sparkle-key.swift`, CryptoKit). `scripts/release.sh <version> [--publish]`: Release build with the commit count as build number, signed inside out through a temporary keychain (Sparkle helpers, framework, widget, app; entitlements kept, get-task-allow dropped), `.dmg`, Ed25519 signature and appcast; `--publish` makes the GitHub release. `docs/RELEASE.md` explains setup, backups, a release and the first launch («Open Anyway»).
Checked: a trial `scripts/release.sh 0.2.0` (not published) — 0.2.0 (183), deep strict verify, widget sandbox kept, no get-task-allow, designated requirement on the certificate, the release binary loads Sparkle and runs, `.dmg` valid, appcast signature verified; `xcodebuild test` — 192 tests green with Sparkle in the host; 3 new strings in all 12 languages. CI not set up; checks run locally.
Left: nothing published (the repository is private); a real update between two releases is untested until there are two; Gatekeeper still asks once («Open Anyway») without a Developer ID.

## 2026-10-30 — Profiles stage 6: quick commands, toggles, «Утилиты Mac» (branch `feat/quick-tools`)

Done: SPEC-profiles §9.6, the last stage. Optional module «Быстрые команды»: a library of buttons (script in the background through zsh in the home folder with the last output line as a notification and under the buttons, script in Terminal, a Shortcuts shortcut, open a link / file / folder / app; «Спрашивать перед запуском»), two harmless examples, an editor in «Модули». Optional module «Быстрые переключатели»: dark mode and desktop icons with their state, lock screen (the system's own lock, falling back to turning the display off), turn the display off, eject external disks, empty the Trash after a confirmation; which ones show is set in «Модули». New template «Утилиты Mac» in all 13 languages: no projects, Ресурсы / Не спать / Команды / Переключатели, limits and sessions hidden; added from Settings it needs no folder; in the assistant it ticks its modules and skips the project questions. «Свой» moved to the end.
Checked: `xcodebuild test` — 192 tests green (new: command kinds, notification text, confirmation, library decoding, the template in 13 languages, the assistant and Settings paths; the template list test updated); catalog synced, 38 new strings in all 12 languages. Live: both modules added to Oleh's profile for the check — a real capture of the open panel (screencapture of the panel window) showed the buttons and all six toggles, and a click on «Мой IP в сети» put the result under the buttons (`exit 0`); profile files restored after. CI not set up; checks run locally.
Left: the toggles were not pressed (they change the Mac); per-profile choice of shown commands (all are shown); the second wave of modules.

## 2026-10-30 — Profiles stage 5: «Не спать» (branch `feat/keep-awake`)

Done: SPEC-profiles §9.5. Optional module «Не спать»: `KeepAwakeController` holds a power assertion (PreventUserIdleSystemSleep, plus display sleep when «Не гасить и экран» is on) while a rule applies and releases it otherwise — System Settings are not touched. Rules: manual («до выключения» switch, 15 min / 1 h / 2 h timers, «Отпустить»), while Claude works (a session running or a background run — on by default), on power, with an external display, while chosen apps run; checked 3 s after launch, every 15 s and when the panel opens. Panel block with the reason («держу: работает Claude», «держу ещё 47 мин»…), ☕ menu bar element, rules in «Модули»; the «Разработчик» template ticks the module in the assistant. The assertion name is ASCII («ClaudePult keep awake») because `pmset` shows non-ASCII names empty.
Checked: `xcodebuild test` — 185 tests green (new: rules and their order, decoding, status text, ☕, the developer default, nothing without the module; an old test's «unknown module» example changed to a fictional one); catalog synced, 22 new strings in all 12 languages. Live: with the module added to Oleh's profile and this session working, `pmset -g assertions` showed «ClaudePult keep awake» within seconds and the panel «держу: работает Claude»; profile files restored — no assertion. CI not set up; checks run locally.
Left: closed-lid mode (second wave, needs an admin password once); the power, display and apps rules not tried on a laptop.

## 2026-10-30 — Profiles stage 4: «Ресурсы Mac», the first optional module (branch `feat/resources-module`)

Done: SPEC-profiles §9.4. `SystemMonitor` reads processor (tick differences), memory as Activity Monitor counts it and memory pressure, disk free for important use, network rates (32-bit counters followed per interface), battery (IOKit power sources), graphics load when macOS reports it, and the five busiest processes (`ps`) — every 2 s while the panel is open, every 30 s otherwise, and only while the module is installed; no permissions. Panel block «Ресурсы Mac» (collapsible, shows CPU and RAM when folded, opens Activity Monitor). Alerts once per event: processor above 90 % for 5 minutes, critical memory, disk below the chosen GB, battery below 15 % on battery; settings in «Модули». Menu bar elements «Процессор» and «Память» (number with a chip symbol, ring or bar, «от N %»). Optional modules: «Установить» in «Модули» installs and adds to the current profile, «Снять» removes from every profile, a profile has «Добавить модуль» and «Убрать из профиля»; the assistant offers «Ресурсы Mac» too. CLI `--resources`.
Checked: `xcodebuild test` — 179 tests green (new: alerts, `ps` parsing, a real reading, menu bar elements, optional modules in the store, the assistant); catalog synced, 37 new strings in all 12 languages with no «% + letter» traps. Live: `--resources` against `sysctl`, `df`, `pmset`; installed; the block shown in the panel with real figures (added to Oleh's profile for the check, the profile files restored after). CI not set up; checks run locally.
Left: per-profile choice of shown figures (all are shown); temperatures and fans (not in the first wave).

## 2026-10-30 — Profiles stage 3: empty start and new assistant (branch `feat/empty-start`)

Done: SPEC-profiles §9.3. Without `_daily-report` ClaudePult now starts with no profile and nothing installed (no placeholder profile): the panel says «Создайте первый профиль» with «Помощник…» and «Импортировать файл…» (the import opens Settings → «Профили» to confirm), the assistant opens by itself, and the limits are neither fetched nor scanned while no profile uses «Лимиты AI». The last profile can be deleted; ClaudePult is then empty again and its modules stop. With `_daily-report` the first profile is still made from the existing settings. The assistant's «Блоки панели» step became «Что будет в панели» right after the template: Лимиты AI, Сессии агентов, Проекты, Ближайшее as checkboxes with what each does; without «Проекты» the folder, stages, metrics, calendar, service, commands and launch steps are skipped; «Ближайшее» needs folder projects. A new profile starts with every block shown instead of copying the current profile's hidden blocks.
Checked: `xcodebuild test` — 173 tests green (new: empty start, deleting the last profile, modules decide the steps; two old tests updated from the placeholder and «last mode stays»); catalog synced, 5 new strings in all 12 languages, 2 stale removed. Live: installed; Oleh's profile and modules unchanged. CI not set up; checks run locally.
Left: the empty panel and the new step were not seen on screen — that needs a Mac without profiles. The «Утилиты Mac» template comes with its modules (stages 4–6).

## 2026-10-30 — Profiles stage 2: panel from modules, menu bar per profile, rename (branch `feat/profiles-panel`)

Done: SPEC-profiles §9.2. The profile's modules now decide the panel: the panel draws the current profile's shown modules in its order. Which modules a profile has follows its settings (limits and sessions always, «Ближайшее» with the calendar, «Проекты» with a source, «Отчёты» with `_daily-report`); showing and order are the profile's own (Settings → «Профили» → «Панель», toggles and ↑↓). The old global «Блоки панели» in «Внешний вид» are gone; the old flags are still written for older versions. Each profile has its own menu bar (old profiles take the one they had); «Строка меню» edits the current profile's, switching profiles switches the bar. New tab «Модули»: the catalog with what each module does, which profiles show it, and its global settings — «Лимиты подписки» moved here from «Claude Code», calendar «Напоминания» from «Основные». The five existing modules are built in; installing and removing come with the first optional module (stage 4). «Режим» → «профиль» in the whole interface in all 13 languages (41 strings carried over with gender and particles fixed for de, it, ko, ar; 11 new strings), custom template names, README and GUIDE.
Checked: `xcodebuild test` — 170 tests green (new: profile decides order and visibility, selecting a profile applies its panel and menu bar); catalog synced with nothing stale or untranslated, format specifiers match, no «mode» word left except «background mode». Live: installed from the worktree; Oleh's profile keeps limits, sessions, projects, reports and the panel draws them in that order; «Профили» and «Модули» tabs captured. CI not set up; checks run locally.
Left: hiding and reordering by hand and two profiles with different menu bars — for Oleh to try.

## 2026-10-30 — Spec: Windows and Linux versions (branch `docs/spec-windows-linux`)

Done: docs/SPEC-windows.md and docs/SPEC-linux.md — how ClaudePult maps to each system (tray instead of the menu bar, credentials file instead of the Keychain, hook as a small binary, terminals and «Показать», background runs, notifications, secrets, autostart, XDG / %LOCALAPPDATA% paths, modules from SPEC-profiles), what works worse than on Mac, distribution, stages 0–8 and open questions. Proposed: Tauri 2, one codebase for Windows and Linux; the Mac app stays Swift. README links the specs.
Checked: docs only; Mac-specific code located by grep (osascript, security, SMAppService, NSWorkspace, SIGTERM) to make sure every such place has a counterpart in the specs. Items marked «проверить» are unverified facts for stage 0.
Left: no implementation (Oleh: spec only for now); decisions in §10 of both specs.

## 2026-10-30 — Profiles stage 1: the model (branch `feat/profiles-model`)

Done: SPEC-profiles §9.1. `ModuleKind` (limits, sessions, upcoming, projects, reports — the modules that exist today) and `ProfileModule`; a mode carries its `modules` in panel order. Until stage 2 the mode's blocks still decide what the panel shows, so the list is synced from them on every save (kinds keep their place, new ones go in panel order, unused ones drop). Installed modules live in `state.json`; everything a profile uses gets installed. On load, mode files from before profiles are rewritten with modules. `.claudepult` export is version 2 (modules, installed); version 1 files still import. Modules a newer version knows are skipped. `--modes` prints each profile's modules and the installed list. The rename «режим» → «профиль» moves to stage 2, where these strings get rewritten anyway (42 strings × 13 languages would otherwise be translated twice).
Checked: `xcodebuild test` — 168 tests green (new `ProfileModuleTests`: modules from blocks, old files migrate and reload the same, unknown kinds skipped, v2 export and v1 import); catalog synced, 3 module names in all 12 languages. Live: Oleh's modes folder backed up to the session scratchpad, installed — his mode now has limits, sessions, projects, reports, `state.json` lists them installed, the panel is unchanged. Built in a worktree because another session works in the main checkout. CI not set up; checks run locally.
Left: stage 2.

## 2026-10-30 — «Показать» opens the desktop-app session itself (branch `fix/show-desktop-session`)

Done: for sessions of the Claude desktop app «Показать» (panel and notification) used to only activate Claude, which looked like nothing happened when Claude was already in front. Now ClaudePult finds the app's own record (`~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json`, `cliSessionId` or `previousCliSessionIds` = the hook's `session_id`, not archived) and opens `claude://code/continue?session=local_…`, the link the app itself offers; without a record it still just opens Claude. `--show-session <id>` handles desktop-app sessions too. Help text updated in all 12 languages; README, DECISIONS, CHECKLIST updated.
Checked: `xcodebuild test` — 164 tests green (new `desktopSessionLink`); installed; live: `--show-session` switched the Claude window to another ClaudePult session and back (the app's `lastFocusedAt` moved to the opened session each time). The button inside the panel is not clickable by automation. CI not set up; checks run locally.
Left: Terminal.app is the only terminal whose tab is found; iTerm, Warp and IDE terminals still open the folder.

## 2026-10-30 — Spec: profiles made of modules (branch `docs/spec-profiles`)

Done: `docs/SPEC-profiles.md`, variant C agreed with Oleh. Modules are installed once from a catalog (permissions and background work come with installing); a profile picks which installed modules to show, in what order and with which of its own settings; ClaudePult starts empty, a profile comes from the assistant or Settings. The spec lists the catalog (the existing blocks plus first-wave Ресурсы Mac, Не спать with «пока работает Claude», Быстрые команды, Быстрые переключатели; second wave and what not to build), the new assistant steps, the Settings tabs, the migration from modes (Oleh's setup unchanged, `.claudepult` v2) and six stages. Ideas taken from Vorssaint (GPL-3.0) — no code.
Checked: docs only; no code changed.
Left: Oleh to confirm the open questions in §10 before stage 1.

## 2026-10-30 — Renew the Claude Code sign-in automatically (branch `feat/renew-login`)

Done: the limits stopped updating because the Claude Code token in the Keychain expired at 11:02 — only `claude` renews it, and the work happens in the Claude app, whose own Claude Code doesn't. When the limits answer «вход устарел», ClaudePult now sends a one-word request through `claude` (Haiku, no tools, no MCP, no settings so no hooks, no session saved), at most once an hour, and asks for the limits again. Setting «Продлевать вход Claude Code сам» on the Claude Code tab, on by default. ClaudePult still never reads, stores or writes the token itself.
Checked: by hand the request renewed the token 11:02 → 20:11 (token never printed) and left no session file, hook record or transcript (test leftovers removed); `xcodebuild test` — 162 tests green (new `LoginRenewalTests`); catalog synced, 2 strings in all 12 languages; installed, `--usage` reads the limits again (19 % / 73 %). CI not set up; checks run locally.
Left: the automatic path itself runs only at the next expiry (~20:11).

## 2026-10-30 — Collapsible panel blocks (branch `feat/collapsible-blocks`)

Done: every panel block (Лимиты, Сессии, Ближайшее, Проекты, Команды) folds with a click on its title; the choice is kept between openings. Folded, a block still shows what matters: session and week %, «ждут ответа», the number of upcoming dates (red if one is overdue), the number of projects and the problems.
Checked: `xcodebuild test` — 161 tests green (new `CollapsedBlocksTests`); catalog synced, 2 new strings in all 12 languages. Live: installed, panel snapshot with three blocks folded (the setting was put back afterwards). CI not set up; checks run locally.
Left: menu bar elements still move with arrows.

## 2026-10-30 — Settings tidy-up from the UI review (branch `feat/settings-tidy`)

Done: one «Claude Code» tab (path, session hooks, subscription limits, background runs) replaces the three small tabs «Claude», «Сессии», «Лимиты» — six tabs instead of eight. Modes list: the checkbox (in the switcher) is the only mark, the current mode says «текущий», the full name is in a tooltip, the list is wider. AI services: installed agents first, the others under «Ещё агенты (N)». Menu bar: the icon element's option is «Символ». Assistant: no «Пропустить» on the template step. Help: when nothing is left to do, readiness is one line «Всё готово · Подробнее». README and GUIDE point to the new tab.
Checked: `xcodebuild test` — 160 tests green; catalog synced, 5 new strings in all 12 languages. Live: installed; Claude Code, Modes and Services tabs and the Help window captured. CI not set up; checks run locally.
Left: menu bar elements still move with arrows (dragging inside a grouped Form is unreliable); collapsible panel blocks.

## 2026-10-30 — Panel polish from the UI review (branch `feat/panel-polish`)

Done: limits take less room — the week's reset sits on its title line, a model week at 0 % is hidden and repeats no reset that equals the week's. The projects get a header like the other blocks, with the count and «с проблемами: N». Project badges say «2 файла» and «1 PR» instead of a bare number. «Очистка: выполнить» was already red with a confirmation (the debug snapshot just doesn't draw tints), so it stays.
Checked: `xcodebuild test` — 160 tests green; catalog synced, the new string in all 12 languages. Live: installed, the panel captured (snapshot) with the new limits, header and badges. CI not set up; checks run locally.
Left: Settings tabs, assistant and Help items from the review; collapsible panel blocks.

## 2026-10-30 — UI quick fixes from the review (branch `fix/ui-quick`)

Done: the session hook follows a resumed session to its new `claude` process (after the Claude app restarted overnight, a live session showed as «завершена»), and ClaudePult rewrites an outdated hook script itself while the hooks are installed. Panel: one refresh (⌘R) for projects and limits; limits that failed to refresh are dimmed with «данные … назад», and the warning wraps instead of being cut. Settings: the thresholds field no longer repeats its value as a label; the Limits footnote points to «Строка меню»; «Обновить hooks» only when needed; agent versions without the repeated product name.
Checked: `xcodebuild test` — 160 tests green (new: hook under a process named `claude`, script self-update, version parsing); catalog synced (2 keys gone, 2 changed, all 12 languages). Live: installed; hook script updated by itself, this session's record moved to the live process and shows «работает»; Limits, Sessions, Services tabs and the panel captured. CI not set up; checks run locally.
Left: the rest of the review (see Next).

## 2026-10-30 — Modes settings without the grey sidebar (branch `fix/modes-sidebar`)

Done: the list of modes in Settings → Режимы used the sidebar style, whose grey material ran up under the Settings tabs; the list background is now hidden, so the whole tab has the window colour and the divider starts below the tabs.
Checked: built and installed; the Settings window captured with `screencapture -l` — one colour, no grey strip. CI not set up; checks run locally.
Left: nothing.

## 2026-10-30 — Onboarding and guide for people (branch `feat/onboarding`)

Done: the assistant on a new Mac now starts with «Добро пожаловать в ClaudePult» — what the app is plus readiness checks with one button each: AI service (Claude Code, other agents, API keys; «Проверяю…» until the first scan), Claude Code session hooks, notifications, start at login (optional). The same list is at the top of «Помощь» and re-checks when ClaudePult comes back to the front. CLI `--readiness [file.png]`. `docs/GUIDE.md` — a page for people: what it does, modes, install, first start, everyday use, privacy, languages, troubleshooting, uninstall; README links to it. 22 new strings in all 12 languages.
Checked: `xcodebuild test` — 159 tests green (new `ReadinessTests`, first-launch steps in `AssistantDraftTests`); catalog sync — nothing stale or untranslated beyond the usual 20 non-text keys; format specifiers match. Live: `--readiness` on this Mac (all done, exit 0), German and Arabic renders (Arabic mirrored); `scripts/build-and-install.sh --test` installed, Oleh's mode unchanged. CI not set up; checks run locally.
Left: the welcome screen and its buttons not seen on a real first start (this Mac has modes already, and ImageRenderer can't draw the buttons); signing, notarization and Sparkle wait for Developer ID.

## 2026-10-30 — Remaining eight languages (branch `feat/all-languages`)

Done: German, Japanese, Indonesian, Korean, Italian, Arabic, Polish and Ukrainian added together — table entries in `ContentLanguage` (card and plan file names, fields, columns, wrappers, prompts; Ukrainian shares `контент-план.md` with Russian), six templates each (`template-*.<lang>.json`), 707 interface strings each, `CFBundleLocalizations` extended. File-count plurals for Ukrainian (as Russian) and Polish. The CLI assistant preview now renders right-to-left for Arabic, as the app's windows do.
Checked: `xcodebuild test` — 155 tests green (per-language completeness, round-trips, templates and `.lproj` for all 13 languages); script check of every catalog (0 missing, 0 format mismatches, no risky «% d» sequences); `xcstringstool sync` — nothing stale. Live with `-AppleLanguages`: assistant previews in pl, uk, ja, ar (Arabic mirrored), git scanner plurals in pl/uk/ja; `scripts/build-and-install.sh --test` installed, Oleh's mode still active (`--modes`). CI not set up; checks run locally.
Left: translations are machine-made — native review needed (ja, ko, ar at least); Arabic panel, menu bar and windows not checked by eye; numbers follow the system region, not the interface language.

## 2026-10-30 — Portuguese (Brazil) and French (branch `feat/portuguese-french`)

Done: both languages added as data — table entries (`projeto.md` / `plano-de-conteudo.md`, `projet.md` / `plan-de-contenu.md`, field and column names, wrappers, prompts), six templates each (`template-*.pt-BR.json`, `template-*.fr.json`), 707 interface strings each.
Checked: `xcodebuild test` — 155 tests green (per-language completeness and round-trips now cover five languages, every language's `.lproj` ships); no compiler warnings; script check of both catalogs (0 missing, 0 format mismatches). Live with `-AppleLanguages`: assistant previews «Textos» (pt-BR) and «Vidéo» (fr) fully translated; French git scanner items. CI not set up; checks run locally.
Left: de, ja, id, ko, it, ar (RTL), pl, uk.

## 2026-10-30 — Spanish, and one table per language (branch `feat/spanish`)

Done: language texts for files and prompts moved into one table per language (`ContentStrings`); Spanish added: 707 interface strings, six templates (`template-*.es.json`), prompts and wrappers, `proyecto.md` / `plan-de-contenido.md`. Reading accepts every language's file and field names.
Checked: `xcodebuild test` — 154 tests green incl. a completeness test run for every language; no compiler warnings; script check of the catalog (0 missing, 0 format mismatches). Live with `-AppleLanguages '(es)'`: git scanner items and the assistant preview of «Redes sociales» fully Spanish. CI not set up; checks run locally.
Left: the remaining languages.

## 2026-10-30 — English templates, prompts and files (branch `feat/english-templates`)

Done: English versions of all six templates (`template-*.en.json`), language-aware loading; English agent/API wrappers and generic developer prompts; English placeholders and result-name tokens alongside the Russian ones; `project.md` and `content-plan.md` read and created in English, cards keep their own language when written. Oleh's prompts unchanged.
Checked: `xcodebuild test` — 151 tests green (templates in both languages with the same commands, placeholders, wrappers, prompts, card/plan language, both file names); no compiler warnings; catalog has no untranslated or stale keys. Live: the assistant preview of «Video» with `-AppleLanguages '(en)'` is fully English. CI not set up; checks run locally.
Left: the other languages of §13.

## 2026-10-30 — English interface (branch `feat/localization`)

Done: SPEC-modes §13 / stage 9, first language. String Catalog with Russian as the source and all 707 interface strings translated to English; 539 non-SwiftUI strings wrapped in `String(localized:)` (file formats, prompts, hook script, logs and CLI deliberately left alone); English-aware «file/files»; Settings → Основные → «Язык интерфейса» with relaunch.
Checked: `xcodebuild test` — 146 tests green (one expectation updated: localized numbers are grouped); no compiler warnings; a script confirms 0 untranslated keys, 0 format-specifier mismatches, 0 stale keys. Live with `-AppleLanguages '(en)'`: git scanner items, calendar texts and the assistant preview come out in English. CI not set up; checks run locally.
Left: template JSON and prompts are still Russian (next step); the language picker was not clicked by eye.

## 2026-10-30 — Setup assistant (branch `feat/assistant`)

Done: SPEC-modes §5 / stage 7. Window «Помощник»: template or «С нуля», folder with analysis and suggested source, stages, metrics, calendar + reminders, AI service («Подключить…» opens the services tab), commands, launch place and background permissions, panel blocks, menu bar preset, name and icon; live preview of the panel and the menu bar on sample data. Opens from Settings → Режимы → «+» → «Помощник…», and by itself on a first start without `_daily-report` (step 0: import a `.claudepult` file); the finished mode replaces the starter placeholder. CLI `--assistant-preview`.
Checked: `scripts/build-and-install.sh --test` — 146 tests green (steps, template/folder logic, folder analysis, starter → assistant mode); no compiler warnings. Live: previews for video, developer and social rendered and looked through (system progress bars do not render off-screen → drawn bars instead); Oleh's mode unchanged. CI not set up; checks run locally.
Left: the assistant window's controls were not clicked through (automation cannot click in ClaudePult windows); panel block order is fixed.

## 2026-10-30 — Templates and the built-in git scanner (branch `feat/templates`)

Done: SPEC-modes §4 / stage 6. Six templates as JSON in the app («Разработчик (GitHub)», «Видео», «Тексты», «Ресёрч», «Соцсети», «Свой») with the texts of docs/TEMPLATES.md; Settings → Режимы → «+» adds a mode from a template after choosing its folder. Built-in git scanner for the «git-репозитории» source (same JSON and health rules as report.py, PRs/CI via `gh`); generic developer prompts for every git mode except Oleh's; source picker gains «git-репозитории». CLI `--git-scan <folder>`.
Checked: `xcodebuild test` — 142 tests green (scanner on a temp repo incl. the porcelain leading-space case, CI states, STATUS parsing, templates loading and adding, prompt styles); no compiler warnings. Live: `--git-scan ~/Projects` gives the same health and attention items as report.py for all six projects (two fixes found that way: porcelain trimming, same-name branches); Oleh's mode unchanged. CI not set up; checks run locally.
Left: adding a mode from a template was not clicked through (folder dialog); template texts await Oleh's review.

## 2026-10-30 — Calendar (branch `feat/calendar`)

Done: SPEC-modes §6 / stage 5. Dates from `проект.md` (deadline, publication) and `контент-план.md` (mode folder and project folders) of all enabled folder modes with a calendar; panel block «Ближайшее» (7 days, overdue in red, click opens); window «Календарь» (month/week, all modes or current, colour per mode, drag to move — written back to the file, double-click to add a plan row or a project date); reminders (offsets in Settings → Основные, once each, optional Telegram); menu bar element «Ближайшая дата календаря» enabled; calendar picker per mode. CLI `--calendar [folder]`.
Checked: `xcodebuild test` — 137 tests green (plan parsing/writing/appending, scanner on a temp tree, store moves and new rows, reminder selection, texts); no compiler warnings. Live: installed; `--calendar` on a sample folder lists an overdue deadline, a timed publication and plan rows with platforms and statuses; Oleh's report mode has no calendar and is unchanged. CI not set up; checks run locally.
Left: the panel block, the calendar window (drag, double-click) and reminder notifications were not seen by eye; `.ics` / EventKit later.

## 2026-10-30 — Command engine (branch `feat/command-engine`)

Done: SPEC-modes §3/§11 / stage 4, part 2. Command templates per folder mode (editor in Settings → Режимы) plus «Своя задача»; running with the chosen service — model by API (ClaudePult sends the main file, writes the answer to a new file), Claude Code in the background with the mode's permissions or in Terminal, other agents in Terminal with the task on the clipboard; results never overwrite (`-2`, `-3`). Permission profiles «Только файлы проекта» and «Файлы + поиск в интернете». «Сравнить» with 2–3 services and a side-by-side window. API spend (tokens per request, prices and monthly budget in «Сервисы AI», month line in the limits block, notifications at 80/100 %). CLI `--api-complete`, `--background-settings <profile>`.
Checked: `xcodebuild test` — 130 tests green (placeholders, names, wrappers, API requests/replies, spend, profiles, old run files); no compiler warnings. Live: real `claude -p` with «только файлы» wrote the result file and was refused shell, web and `~/.zshrc`; with «файлы + поиск» fetched a page into a file, shell refused; `--api-complete` against a local OpenAI-compatible stub returned text and tokens; missing key / dead server give clear errors. CI not set up; checks run locally.
Left: the panel commands, «Сравнить» window and spend section were not seen by eye; no real API key on this Mac yet. Stacked on `feat/folder-projects`.

## 2026-10-30 — Folder projects (branch `feat/folder-projects`)

Done: SPEC-modes §3 / stage 4, part 1. Mode source «папки» (every subfolder is a project) and «одна папка»; card `проект.md` (stage, deadline, publish date, format, main file, platform — plain Markdown, written back line by line); stages per mode with switching from the panel; metrics per mode (words, duration with the mode's pace, reading time, pages, sources, deadline — red when overdue, publish date, last edit) counted on the main file incl. `.docx`/`.rtf`; «Новый проект» and «Создать проект.md» in the panel. Settings → Режимы: source picker, stages, metrics, pace. report.py runs only for report modes. CLI `--folder-projects <folder>`.
Checked: `xcodebuild test` — 120 tests green incl. card parsing/writing, dates, metrics, scanner on a temp tree, store create/stage/source switch; no compiler warnings. Live: installed; `--folder-projects` on a sample folder: 1200-word `.docx` → «8:00», overdue deadline, publish date, sources, card stage; Oleh's report mode unchanged. CI not set up; checks run locally.
Left: the folder panel was not seen (switching Oleh's mode only to look was not done); command engine, «только файлы», API spend and «Сравнить» are the next PR of stage 4.

## 2026-10-30 — AI services: connection (branch `feat/ai-services`)

Done: SPEC-modes §11 / stage 3, connection part. Service layer (`AIService`: Claude Code, agents, API providers), agent detection with version (Codex CLI, Gemini CLI, Antigravity CLI, Copilot CLI, Cursor CLI), API keys in the Keychain via `security -i` (stdin, never logged or exported), «Проверить» = model list (no tokens), model choice, OpenAI-compatible server (Ollama default). New Settings tab «Сервисы AI»; «Сервис по умолчанию» per mode (`Mode.service`); «Открыть в…» in a project's Claude block for installed agents; export carries the services config (not keys). CLI `--services [check]`. Claude Code behaviour unchanged. Flags and endpoints checked against the docs; details and what could not be checked in DECISIONS.md.
Checked: `scripts/build-and-install.sh --test` green incl. new AIService tests (ids, requests and headers, model-list parsing, check results, key validation, detection, tolerant config, export round-trip); no compiler warnings. Live: `--services check` (Claude Code 2.1.312 found, others not installed, no keys, local server not running → honest message); all six model-list endpoints answer «bad key» to an invalid key; a throw-away Keychain item round-tripped through `security -i` and was deleted. CI not set up; checks run locally.
Left: running commands with other services, API spend and «Сравнить» come with the command engine (stage 4); Settings tab and «Открыть в…» need Oleh's eye with a real key / installed agent.

## 2026-10-30 — Expired Claude Code token message (branch `fix/token-expired-message`)

Done: when the OAuth token in the Keychain has expired, the limits block now says «Вход Claude Code устарел — обновится при следующем запуске claude в Терминале (если нет: claude → /login)» instead of asking to log in; a missing token still asks to log in. A repeated usage error is logged once, not every 2 minutes.
Checked: `scripts/build-and-install.sh --test` green incl. a test for both texts; installed, the log shows the new text. Found: the Keychain item «Claude Code-credentials» expired at 02:22 and is not renewed by Claude Code inside the desktop app (it has its own login) nor by `claude auth status`; only a real request from the terminal `claude` renews it (not run here, to keep Oleh's limits untouched). CI not set up; checks run locally.
Left: ClaudePult itself never refreshes the token (by design, SPEC §2.8).

## 2026-10-30 — Menu bar builder (branch `feat/menubar-builder`)

Done: SPEC-modes §7 / stage 2. The menu bar item is built from elements: icon (sparkle, other symbol, the mode's icon or none), red project dot, session / week / model week (number, ring or bar; always or from N %), reset countdown («2:14» / «2 ч 14 мин», ticks each minute), forecast, waiting / running sessions / background runs / queued launches (only > 0), free disk below N GB, current mode (icon or name); «Ближайший дедлайн» waits for the calendar. Presets «Минимум» / «Лимиты» / «Всё» / «Свой», separator, small text, colour by level or mono. New Settings tab «Строка меню» with live preview («Сейчас» / «Пример со всем») and a width warning; the old picker in «Внешний вид» is gone. The old setting migrates unchanged; exports carry the config (old files still import). CLI `--menubar-preview`. `docs/modes/oleh-developer.claudepult` re-exported with the builder config.
Checked: `xcodebuild test` — 105 tests green incl. migration of all four old settings, presets, tolerant decoding, composer cases (Oleh's look, thresholds, mono, model week, counters, countdown, disk, mode, empty fallback, separator rule), export round-trip and old-export migration; no compiler warnings. Live: installed; `--menubar-preview` with the saved config draws «✦• 34% · 58% ✋1» as before, «Всё» draws every element in dark and light (~400 pt, triggers the warning). CI not set up; checks run locally.
Left: the Settings tab and the ticking countdown need Oleh's eye (automation cannot click inside ClaudePult). Seen in passing: the Claude Code OAuth token in the Keychain expired at 02:22 and ClaudePult then says «Войдите в Claude Code» although Claude Code refreshes the token by itself on its next request — the message should say to wait / open Claude Code instead (small follow-up).

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
