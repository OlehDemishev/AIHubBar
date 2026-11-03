# Status

<!-- summary:start -->
**Stage:** Mac: 0.5.0 published, beta 0.5.1-beta.1 on the beta channel (refactoring stages 0–8 done; «Раскладка» still in beta). Windows/Linux (`desktop/`, Tauri 2): postponed by Oleh 2026-11-02 after stages 1–3 main parts
**Updated:** 2026-11-03

**Now:**
- `feat/telegram-menu`: Telegram menu always at the bottom of the chat (persistent reply keyboard) — PR open
- merged 2026-11-03: #241 Codex session states, #240 quick command shortcuts, #238 «Быстрый запрос», #236 content spec, #242 «Telegram» stage 1

**Next:**
- next beta or 0.5.1 carries stage 8 (#230–#232) and #236–#242: 0.5.1-beta.1 was built from 27c5e2d, before them
- Telegram (docs/specs/SPEC-telegram.md): stage 2 — sessions and requests in the bot, approvals bot moved in, notification settings
- content (docs/specs/SPEC-content.md, agreed): stage 1 — walkthrough of the «Тексты» profile on a sample folder, then «Версии», then batch tasks
- Windows/Linux postponed: no work until Oleh brings it back (where it stopped: docs/specs/SPEC-windows.md §9, stage 2–3 leftovers)

**Needs Oleh:**
- Telegram: after the menu PR is installed, send /menu once — the menu appears at the bottom; then try 📊 and 🧹. Delete `_daily-report/bot.py` and `install-bot.sh`
- «Быстрый запрос»: Settings → Modules → «Быстрый запрос» on, then ⌃⌥P from Terminal or Xcode — send one task to the background and one to Codex
- Settings → Codex → «Установить hook», then once in `codex` type `/hooks` and trust AI Hub Bar's hooks (Codex skips untrusted hooks); then check a Codex row in «Сессии» goes «ждёт» on an approval prompt
- quick command shortcuts: Settings → Modules → «Быстрые команды» → a command → «Сочетание клавиш», record one and press it
- GitHub → repository Settings → Social preview: upload docs/images/social-preview.png (only by hand)
- Settings → Copilot → «Установить hook»: then start `copilot` and check its row in «Сессии» (the agent wasn't allowed to install it into ~/.copilot itself)
- look at the new Settings and say what to change next
- MacBook Air: update to 0.5.0 through Sparkle (Settings → General → Updates) and check the island at the real notch
- «Раскладка»: tried live in TextEdit, Safari, Chrome (⌥⇧ too); Telegram and Notes are yours to try (not typed into by the agent)
- older, still open: Mac mini Claude CLI sign-in, crash report alert from 16:46, Chinese model keys, ja/ko/ar translations, docs/CHECKLIST.md «Oleh» rows, social preview image, old repo `OlehDemishev/ClaudeBar`
<!-- summary:end -->

## 2026-11-03 — Telegram: the menu at the bottom of the chat (branch `feat/telegram-menu`)

Done: Oleh asked for a menu that is always there instead of `/` commands. `BotMenu` (persistent reply keyboard: 🏠 Главная · 📊 Отчёты / 🧹 Мак · ❓ Команды); a press opens that screen as a new message and deletes the press and the earlier menu screens (kept while a report or cleanup edits one); 🏠 from the menu, /menu, /start, «Проверить» and the chat binding carry the menu. Spec §2 and §8 updated: Oleh connected the `_daily-report` bot (one chat with the reports); the wrong `report.py --setup-telegram` hint removed (it keeps an existing token). No new strings.
Checked: scripts/check.sh green; 2 new tests (the menu's markup and titles read back, a message carries inline buttons or the menu). Live: Oleh's bot answered (`help.txt` screenshot); the bottom menu itself not yet tried live.
Left: stages 2–4 as before; their sections join the bottom menu.

## 2026-11-03 — «Telegram» module: spec and stage 1 (branch `feat/telegram-bot`)

Done: docs/specs/SPEC-telegram.md (one bot inside AI Hub Bar with its own menu: screens, callback data, safety, state, settings, migration, 4 stages; Oleh's answers: no PR merging from the phone, the Mac mini answers, `bot.py` retired, a new bot). Stage 1: optional AI module «Telegram» (`Modules/TelegramModule.swift`, `Services/TelegramBotController.swift`, pure logic in `Models/TelegramBot.swift`): token in the Keychain (`telegram-bot`, the send-only bot's account), chat linked by a `t.me/<bot>?start=<code>` link (or the chat already set / the `_daily-report` one), «Этот Мак отвечает боту» (desktop on, laptop off by default; HTTP 409 shown as «Бота читает другой Мак»), «Взять бота из _daily-report», `setMyCommands` (/menu, /report, /status, /clean, /help), screens 🏠 / 📊 / 🧹 / ❓ edited in place, `report.py` / `cleanup.py` one at a time, /clean asks first, messages older than 30 min and action presses right after a gap skipped, only the linked private chat answered. Approvals: if the approvals bot is the same bot, its own `getUpdates` stops and the module hands it the ✅/❌ presses. Settings → General → Telegram is now a pointer to the module; the help fact, the site help and the old «Основные → Telegram» pointers updated. 67 new strings in 12 languages. `_daily-report/help.txt`: the bot section now lists AI Hub Bar's commands; the `bot.py` maintenance lines removed.
Checked: scripts/check.sh (strings, desktop texts, all Mac tests with warnings as errors); 14 new tests in `TelegramBotTests` (update parsing, only the linked private chat, stale messages, route round trip and tampered data, commands as in bot.py, screens and escaping, hours since the morning report). Not checked live: Oleh hasn't connected the new bot yet.
Left: stage 2 (sessions and requests in the bot, moving the approvals bot, which events come — the approvals section's texts still describe a separate bot), stage 3 (tasks and run control), stage 4 (settings in the bot, all limits, «Не спать», morning report time). `report.py` sends through the `config.json` bot, so until Oleh points it at the new bot the reports come from the old one.

## 2026-11-03 — four feature PRs merged (main session)

Done: merged #241 (Codex states), #240 (quick command shortcuts), #238 («Быстрый запрос») and #236 (content spec) in that order. String catalog conflicts resolved by a three-way JSON merge (no string lost: 1538 base + 26 + 10 + 17). While «Быстрый запрос» is on, its key is one of the app's own keys in `CommandHotKeys.reserved`, so a quick command can't take it (test in `CommandHotKeysTests.theAppsOwnKeys`); this closes the hotkeys entry's Left.
Checked: scripts/check.sh green on each combined branch before its merge; CI green on every PR.
Left: nothing from the merges.

## 2026-11-03 — Spec: content as modules and the «Тексты» profile (branch `docs/content-spec`)

Done: the October texts-mode draft (`docs/SPEC-content.md`, d4fbcd8) re-read against today's app as `docs/specs/SPEC-content.md`. Most of it already exists through SPEC-modes/profiles (folder projects, `проект.md`, stages, words and running time, commands with results next to the source, «только файлы» permissions, night queue, calendar, «Тексты» template) and is reused as is. New: optional module «Версии» (hidden draft versions in Application Support, own store without git, texts and the card only, before every AI run and on changes, compare and restore in the card) and batch tasks inside «Проекты» (one command over several projects, sequential, now / at night / after the reset). Quick prompt left to its own spec. Oleh's answers: walkthrough first, own store, texts only, batch tasks in this wave; versions every 10 min on changes, all of the last 24 h, then one a day for 30 days. Row in `docs/specs/README.md`.
Checked: docs only; claims about what exists checked against the code (`FolderProject`, `CommandTemplate`, `BackgroundPermissions`, `NightQueue`, templates) and DECISIONS.md / CHECKLIST.md.
Left: stage 1 (walkthrough).

## 2026-11-03 — «Быстрый запрос»: a task to an agent from any app (branch `feat/quick-prompt`)

Done: new optional AI module «Быстрый запрос» (docs/specs/SPEC-quick-prompt.md). A Carbon hot key (⌃⌥P by default; ⌃⌥A, ⌃⇧Space, off — on the module's page; registered only while the module is on) opens a small floating window: task, project, agent, «Фон» / «Терминал»; ⌘↩ sends, Esc closes. The project starts as the one in front (front window's document or a project name in its title, read only if Accessibility is already granted), else the last one, else the most recently active. Claude Code goes through `LaunchController` like «Своя задача…» (worktree, the 90 % limit question and «Запустить всё равно» shown in the window); other installed agents open in Terminal with the task on the clipboard. `AIHubBar --app-command quick-prompt` opens it (module off → its Settings page). Help fact in «Сессии агентов», site help JSON exported, REFERENCE updated, 17 new strings in 13 languages. `GlobalHotKey` changes are additive (one more id, `registerQuickPrompt`).
Checked: scripts/check.sh green (warnings as errors), new `QuickPromptTests` (project choice, agents and modes, keys, settings decoding); installed with scripts/build-and-install.sh, `--app-command quick-prompt` with the module off logs and opens the module's page (screenshot).
Left: the window itself not tried live (Oleh was using the screen; turning the module on would change his setup) — see Needs Oleh. Other agents get the task through the clipboard; passing it as their first prompt waits for their flags to be checked live.

## 2026-11-03 — quick command shortcuts (branch `feat/command-hotkeys`)

Done: every «Быстрая команда» can have a global shortcut (SPEC-profiles §4.3, was second wave): a recorder in the command's editor («Записать», ✕ clears, Esc cancels; ⌘/⌃/⌥ or a lone F1–F20), stored with the command (`hotKey`, optional — old libraries decode), registered by the new `CommandHotKeys` while the module is installed and on, in any profile; a press runs the command like its button, «Спрашивать перед запуском» as an alert. The editor names conflicts: the app's own keys (search, island ⌃⌥Y/⌃⌥N) win, the first command in the library wins a duplicate, keys macOS refused; warnings for macOS's own keys and ⌘-only keys. The panel shows the key on the button (hover hint, VoiceOver label). `GlobalHotKey` got additive registration of N command keys and a recorder hand-off. Strings in all 12 languages, module summary and footnote updated, help JSON re-exported, SPEC-profiles and REFERENCE updated. The command library isn't in `.claudepult` files, so neither are the shortcuts.
Checked: scripts/check.sh green (warnings as errors), new CommandHotKeysTests (storage with/without a shortcut, names, conflicts, registration bookkeeping, asking before a run). Live, this branch's Release build run from build/: with the module on and F19 on «Мой IP в сети», the log showed «1 registered» and a posted F19 ran the command (exit 0); Oleh's settings put back afterwards (module off again, default library). The editor and the panel were not looked at on screen.
Left: if «быстрый запрос» (parallel branch) adds its own global key, add it to `CommandHotKeys.reserved` after both are merged. Panel search still runs a quick command without «Спрашивать перед запуском» (older behaviour, not changed here).

## 2026-11-03 — «ждёт» for Codex CLI; Antigravity researched (branch `feat/agent-waiting`)

Done: Codex 0.166 has stable lifecycle hooks (`~/.codex/hooks.json`, Claude-shaped, snake_case payload with `session_id` = thread id). `CodexHooks` merges AI Hub Bar's entries into that file (backup first, other hooks untouched, a file left empty is removed); Settings → Codex → «Состояние сессий Codex» with «Установить hook» / «Снять hook» and hover hints; `AIHubBar --codex-hooks status|install|uninstall`. The shared hook script (format 5) takes `--agent codex`: `PermissionRequest` → «ждёт» with the same notification as Claude's, `UserPromptSubmit` / `PostToolUse` → «работает» (`apply_patch` shows the file it edits), `Stop` / `Interrupt` → «готово», `SessionEnd` → ended (3 s timeout, Codex's maximum). A Codex hook session hides its thread row. `HookJSONFile` now holds the JSON read / backup / write that Claude's installer had; the read error names the file. Antigravity: its hooks (`PreToolUse`, `Stop`, …) have no event for an approval prompt and its run status has no waiting value, so nothing was built — findings in SPEC-ai-services stage 7. Strings in all 13 languages, help fact «Codex и Copilot», site/help exported, REFERENCE and specs README updated.
Checked: `scripts/check.sh` green (strings, all Mac tests with warnings as errors; new `CodexHooksTests` — 6 tests on payloads from Codex's hooks docs); installed with `scripts/build-and-install.sh`, Settings → Codex shows the section, `--codex-hooks status` → notInstalled. Live: a `codex exec` with our hook passed by `-c hooks.…` ran nothing — Codex skips untrusted hooks silently (`--dangerously-bypass-hook-trust` was not used), so no live session states yet. An `agy -i` probe stopped at agy's first-run colour-scheme screen and was closed unanswered.
Left: Oleh installs and trusts the hook, then a live check (whether the TUI's hooks run in `codex` itself or the shared app-server daemon decides what «Показать» finds). Approving Codex prompts from AI Hub Bar (its `PermissionRequest` answer has Claude's shape) — not offered until checked live. Codex's `request_user_input` question has no hook event. The `codex exec` probe left a thread in a scratch folder that shows in «Сессии» for 3 hours.

## 2026-11-03 — overview PDFs for 1.0 (branch `docs/overview-1.0`)

Done: docs/AI-Hub-Bar-Overview-en.pdf and -ru.pdf now 9 pages: a new page 5 «The notch, put to work» (notch island: ears, events, permission requests, file drop) with Layout fix (beta); the cover with the new tagline and bullets for the island and Mac tools; Copilot CLI sessions and Claude's task list on «At a glance» and «Agent sessions»; the notch island card instead of Calendar on page 2 (Calendar stays in Mac tools). Icon paths fixed after the AIHubBar rename.
Checked: every page rendered to PNG and looked at in both languages; nothing runs into the footer.
Left: the cover's panel mock-up still shows the older panel (no island).

## 2026-11-03 — social preview for the 1.0 site (branch `chore/social-preview-1.0`)

Done: docs/overview/hero.html redrawn as the site's hero: «Your AI and your Mac, one click away», the island at the notch asking for a permission and the panel with several services and Claude/Copilot sessions; the icon path fixed after the AIHubBar rename. Rendered docs/images/hero.png (README header, 2x) and social-preview.png (1280×640), copied to site/. README alt text updated.
Checked: both images looked at after rendering; nothing overlaps.
Left: the GitHub repository's own social preview (Settings → General → Social preview) is uploaded by hand — Oleh. The overview PDFs still have the old tagline.

## 2026-11-03 — 1.0 site published (branch `chore/status-site-published`)

Done: on Oleh's «Публикуй» merged #234; the Pages workflow deployed it.
Checked: https://olehdemishev.github.io/AIHubBar/ serves the new page (title, styles); help.html still loads its topics, no console errors.
Left: the social preview image is still the old one.

## 2026-11-03 — site draft for 1.0 (branch `feat/site-1.0`)

Done: new landing page in site/ (index.html, new styles appended to style.css; help.html untouched): hero with a Mac screen top (the island asking for a permission, the panel with limits of several services and Claude/Copilot sessions), «works with», AI (limits, sessions, commands), the notch island (rest, events, file drop), Layout fix (beta) with a typing demo, Mac tools tiles, profiles and templates, install, privacy (3 points), final CTA.
Checked: local preview at 1440 px light and dark and at 375 px (no horizontal scroll); feature claims checked against the code (toggles, keep-awake rules, island hot keys ⌃⌥Y/⌃⌥N).
Left: waiting for Oleh's review; not merged, since merging site/ to main publishes it. Social preview image still the old one.

## 2026-11-03 — beta 0.5.1-beta.1 published (branch `chore/status-beta-0.5.1`)

Done: Oleh ran `scripts/release.sh 0.5.1-beta.1 --publish` on main `27c5e2d` (build 526): quick drops on the island, the «Своя задача» hint, Copilot session states. Refactoring stage 8 (#230–#232) is not in it.
Checked: release v0.5.1-beta.1 has the DMG and appcast; the beta channel's appcast lists 0.5.1-beta.1 (526, channel beta) and 0.5.0 (516).
Left: release.sh's check printed one warning (`try?` in ServicesSettings) — fixed in #231.

## 2026-11-03 — refactoring stage 8, part 3: large files, warnings (branch `refactor/stage-8-files`)

Done: whole types moved out of the largest files, no code changes: `NotchSettings` (ears, summary, screens, place), `NotchPanel` (hosting view, panel, full-screen detector), `NotchText`, `NotchShapes`, `HubFetch` (parsing, forecast, fetching), `MenuBarComposer` (data, segments, composer), `KeyboardLayouts`, `MenuBarOrderViews` (drag and drop, chips, palettes), `CommandLineActions` (what the CLI commands do). The largest file is now `HelpIllustrations` (713 lines, one scene per type). `scripts/check.sh` treats Swift warnings as errors (not CI: GitHub's Xcode is older and may warn differently); fixed the one it found (KVO closure in `ResizableSettingsWindow`). SPEC-refactor: stage 8 done.
Checked: scripts/check.sh green with warnings as errors.
Left: nothing from the audit, apart from the renames that need a migration (SPEC-refactor §8, by design).

## 2026-11-03 — refactoring stage 8, part 2: wiring and tests (branch `refactor/stage-8-wiring`)

Done: `AppSettings.betaUpdates` no longer flips Sparkle's channel from its `didSet` — `AppContainer.followBetaUpdates` observes it (tests changing the setting no longer touch the global). Telegram settings read the bot from the Keychain 3 times less (no reload on Enter, after «Определить», before «Проверить»). JSON settings save through `setEncoded`. `MenuBarData.without` (a switch per module) replaced by `MenuBarConfig.without`, which turns off the elements the module registry gives a switched-off module. Fixed both compiler warnings. New tests: the CLI command table (usage lines, unique flags, `--help`, missing values, usage errors), `--app-command` names, `AppRequests` window requests, the Sparkle channel.
Checked: scripts/check.sh green; installed build, the menu bar shows limits, disk, CPU and memory as before.
Left: large files, warnings as errors. `@Persisted` dropped: property wrappers don't work inside `@Observable` classes.

## 2026-11-03 — refactoring stage 8, part 1: store errors (branch `refactor/stage-8-errors`)

Done: stores report errors under one name, `lastError` (was also `error` in UsageStore and ClaudeConfigStore, `saveError` in NotesStore). `AppLog.attempt` logs the writes that used to fail silently with `try?`: profiles and their state, the night queue, runs, usage snapshot and history, command spend, calendar reminders, widget files, limit history, the MCP stash restore, clipboard history. Stage 8 added to SPEC-refactor §9; STATUS no longer calls the refactoring «full».
Checked: scripts/check.sh green (strings, desktop strings, Mac tests with the new AppLogTests).
Left: the other stage 8 parts (global hooks, `@Persisted`, tests, large files, warnings as errors).

## 2026-11-03 — Plan run while Oleh was away (no branch of its own, recorded here)

Done: Oleh asked at 04:27 to go through the plan without questions until 12:00. Merged: #226 (island quick drops, «Своя задача» hint, live «Раскладка» check), #227 (docs after the refactoring), #228 (Copilot CLI session states). Looked into and closed without code: the test host writing into the real log (already guarded by `AppLog.writesFile`, no test lines in the log during a full run); one error naming across stores (kept as decided in stage 6).
Checked: each PR's own checks and CI; the installed app is the build of main `39a09ea`.
Left: refused to the agent and left to Oleh — publishing the beta (a public release) and installing the Copilot hook into ~/.copilot (another program's config). Windows/Linux untouched (postponed).

## 2026-11-03 — Copilot CLI sessions with states (branch `feat/copilot-session-states`)

Done: the spec's leftover «a waiting signal for agents without hooks» — Copilot CLI turns out to have hooks (docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference). Given Claude-style PascalCase names (SessionStart, UserPromptSubmit, Notification, PostToolUse, Stop, SessionEnd) it sends Claude Code's snake_case payload, so the existing hook script serves it with `--agent copilot`: it finds the `copilot` process, writes `sessions/<id>.json` with `agent: copilot`, and never opens an approval request (PermissionRequest isn't registered: Copilot runs it before its own rules; the `permission_prompt` notification means a real prompt). `CopilotHooks` writes its own file `~/.copilot/hooks/aihubbar.json` (other hooks untouched; removing = deleting the file); Settings → Copilot has «Состояние сессий Copilot» with «Установить / Обновить / Снять hook»; CLI `--copilot-hooks [status|install|uninstall]`. Copilot sessions then are ordinary rows (its icon next to the project), count for the menu bar and island, notify «Copilot ждёт ответа — …»; the plain Copilot thread row is hidden while its session row is there. The script is kept current at start while our file is there. Codex and Antigravity: no hooks; Antigravity's run status has only IDLE / RUNNING / BUSY / CANCELING, nothing for «waiting».
Checked: `scripts/check.sh` green (new `CopilotHooksTests`: a Copilot session through start → prompt → permission notification → tool → stop → end; no approval files for Copilot; Claude records stay Claude, old files too; the hook file's events, no PermissionRequest, no «*» matcher (Copilot matchers are regexes); status and removal; no duplicate thread). Installed build: Settings → Copilot shows the section (read through the accessibility API and captured), `--copilot-hooks status` → notInstalled.
Left: not seen with a real Copilot session — installing the hook into ~/.copilot was refused to the agent as a persistent change to another program's config; Oleh installs it with the button. Payload field names come from the docs, not from a live run.

## 2026-11-03 — Docs refreshed after the refactoring (branch `docs/refresh-after-refactor`)

Done: the stale statements the audit listed and a few more. `docs/specs/SPEC-hub.md` and the specs table say its leftovers (forecast, per-service alerts, menu bar, widget) were done in SPEC-ai-services; `SPEC.md` notes that `report.py` feeds only Oleh's report profile and the built-in `GitScanner` reads projects otherwise; `CHECKLIST.md` says its rows are as of their check day and names what was renamed since. `REFERENCE.md` points to `docs/specs/` and `docs/status/`, says the Xcode project is `AIHubBar.xcodeproj`, and its test command had a broken `-scheme AI Hub Bar` (now `AIHubBar`). `TEMPLATES.md`: the templates' path (`AIHubBar/Resources/Templates/`) and the app's name.
Checked: relative links in docs and specs resolve (a script over every relative link); the test command from REFERENCE is the one `scripts/check.sh` runs.
Left: specs and `DECISIONS.md` keep «ClaudePult» where they were written under that name (history); `~/Projects/_daily-report/help.txt` still titles the block «🖥 ClaudePult» (outside this project).

## 2026-11-03 — Island: quick drops land, readable «Своя задача» hint (branch `fix/notch-drop-early`)

Done: why a file drag onto the island sometimes didn't land: the window took the mouse only after a drag event inside the drop zone, and macOS sends a drag only to a window that took the mouse before the pointer got there — a quick release right after arriving fell through. Now, while a file drag is going on, the window takes the mouse 40 pt around the zone (`NotchIsland.dragMargin`) and accepts the drop only over the zone itself (`dragOver`, also lights the island from the window's own drag callbacks). The accessibility walk of the drop card found the «Своя задача» button's hint was the raw placeholder «{текст}»: `CommandTemplate.hint` gives it words (island and panel), translated into 12 languages.
Checked: `scripts/check.sh` green (new: the custom task's hint has no placeholder). Live, a real Finder drag of a scratch file driven by posted mouse events, released at once on arrival: 0.5.0 — 1 of 9 landed (12 / 9 / 8 steps), the fix — 7 of 9; with a pause before release both always land. Accessibility tree of the drop card read through the AX API: card label «AI-команды для drop-test.md», file name, folder, «Отмена», «Своя задача» with its hint, the result note.
Left: drags into apps under the 40 pt margin around the notch are refused while a file is dragged there; at rest on a screen without a notch the island window is an empty accessibility group (nothing is shown, VoiceOver lists it as «Остров у чёлки»).

## 2026-11-03 — «Раскладка» checked live, no fixes needed (no branch, recorded here)

Done: posted key events into a new TextEdit document, a local page in Safari and in Chrome: «ghbdtn» + space → «привет » with the layout switched to Russian; «руддщ» + double Shift → «hello»; ⌥⇧ on a selection «Привет hello» → «Ghbdtn hello» (the Cyrillic word converted, the Latin left), clipboard put back. Logged «fixed a word, en → ru» / «converted the selection» each time.
Checked: the text read back from TextEdit by AppleScript and from the browsers by ⌘A ⌘C; documents and tabs closed unsaved.
Left: Telegram and Notes not typed into (Oleh's accounts); a learned word (double Shift right after a fix) not tried live so as not to add a test word to his list; with no fixes there is no new beta.

## 2026-11-03 — Release 0.5.0 (branch `chore/status-release-0.5.0`)

Done: `scripts/release.sh 0.5.0 --publish` from main `0b337e2` (build 516): v0.5.0 is GitHub's latest release with the `.dmg`, the appcast and the overview PDFs; the beta channel's appcast now points to 0.5.0 too. Release notes: the new help (app and site) and what the refactoring changed for people — a switched-off module really stops, exports keep switched-off modules, the profile editor keeps outside changes, permission answers and notes are no longer lost silently, less work while drawing, `AIHubBar --help`.
Checked: release.sh ran `scripts/check.sh` first (green). The `.dmg` mounts, holds one widget extension (`AIHubBarWidget.appex`), passes `codesign --verify --deep --strict` (signed «ClaudePult Release»), version 0.5.0. `releases/latest/download/appcast.xml` → 0.5.0 build 516 with the v0.5.0 `.dmg` URL; the beta appcast → 0.5.0.
Left: an update from 0.4.0 through Sparkle on another Mac isn't tried yet (MacBook Air).

## 2026-11-03 — refactoring stage 7: docs and names (branch `refactor/stage7-docs-names`)

Done: specs moved to `docs/specs/` with a `README.md` table of what each one is and where it stands; paths to them fixed in code comments, scripts, docs and `desktop/` (old journal entries left as written). October's 96 journal entries moved to `docs/status/2026-10.md`; `STATUS.md` keeps November and points there at the bottom. In code `Mode` → `Profile` (`ProfileStore`, `ProfileTemplate`, `ProfileInfo`, `ProfileEditor`, `ProfilesSettings`, files renamed; the alert picker's own `Mode` became `AlertMode`); property names and JSON keys unchanged, so saved profiles load as before. Project, targets, scheme and module: `ClaudePult*` → `AIHubBar*` (`AIHubBar/`, `AIHubBarTests/`, `AIHubBarWidget/`, `AIHubBar.xcodeproj`, `AIHubBarApp`, `AIHubBarShortcuts`); scripts and CI follow. Not renamed (users' data): bundle ids, Application Support / Logs / Notes folders, the Keychain item, the hook, sudoers, widget kinds, `.claudepult`, UserDefaults keys, the signing certificate. `build-and-install.sh` and `release.sh` now build a fresh app bundle: a reused one kept the old `ClaudePultWidget.appex` next to the new one (two widgets with one bundle id).
Checked: `scripts/check.sh` green (strings, desktop strings, all Mac tests). Installed: one widget extension registered (`AIHubBarWidget.appex`), profiles, notifications permission and «Раскладка»'s Accessibility carried over, the panel opens with the developer profile; CLI `--modes`, `--notifications-status`, `--help`.
Left: comments in older docs still say ClaudePult where they mean the app; the repository folder stays `~/Projects/ClaudePult`.

## 2026-11-03 — refactoring stage 6: services (branch `refactor/stage6-services`)

Done: module alerts go to Telegram through one `Telegram.notify(toggle, html:, settings:)` (seven copies of «setting on and a bot set up → send» in usage, other AIs, background runs, the night summary, PRs and calendar reminders); it uses the same `TelegramToggle`s as the module pages' «Telegram» chip (that `AppSettings` extension moved next to the settings). `AppSettings` reads each kind of value one way (`bool/int(_:default:)`, `positiveInt`, `value`, `decoded`, `setEncoded`) — same keys and the same meaning per key: 0 stays midnight for the night start, and «not set» for limits and sizes. The command line is a table of commands (flags, values needed, usage line, handler) in the old order, replacing a 238-line `if` chain; `--help` prints it.
Checked: all Mac tests green (403; new: settings storage keeps the meaning of 0 and round-trips). CLI on the built app: `--help`, `--modes`, `--sessions`, `--background-settings`, an unknown `--app-command` (usage, exit 2).
Left: one error naming across stores (`error` / `lastError` / `message` …) wasn't done: it means touching many screens for names alone.

## 2026-11-03 — refactoring stage 5: app composition (branch `refactor/stage5-composition`)

Done: `App/AppContainer.swift` — the 29 stores and controllers, the hooks between them and the background start moved out of `ClaudePultApp.init` (the App is 168 lines of scenes now). Every window and the notch island get the same environment through `.appEnvironment(app)` (12 hand-kept lists, 1–21 stores each, a missing one crashing at runtime). The module services are one table of (module, service) pairs behind a `ModuleService` protocol instead of eight `isActive` closures. «Claude is working» is one `ClaudeActivity` for the menu bar, the widget and «Не спать» (counted three ways before). The clipboard checks every 5 s instead of 0.7 s while its module is off; Telegram answers check every 10 s instead of 2 s while switched off.
Checked: `scripts/check.sh` green. Installed build, live: menu bar item, notch island window, the panel with glass and all its blocks (one posted click to open, one to close), help window via `--app-command help`.
Left: the test host still writes to the real `~/Library/Logs/ClaudePult` log (log lines only, no data).

## 2026-11-03 — refactoring stage 4: views by folders and shared pieces (branch `refactor/stage4-views`)

Done: `Views/` split into `Settings/`, `Panel/`, `MenuBar/`, `Notch/`, `Windows/`, `Support/` (+ `Help/`), moved without code changes in their own commit. SettingsView.swift (738 lines) became the window shell plus `SettingsControls`, `GeneralSettings`, `AppearanceSettings`, `ClaudeSettings` and `Support/WindowTweaks`; ModulePage.swift (785) became `ModulePage`, `ModuleCatalog`, `PanelBuilder`. Shared: one flow layout (`FlowRow` and `FlowLayout` were the same), one `ContentHeightKey` (panel and notch had a private copy each), `IconTile` (Settings' `PaneIcon` and the help's hand-copied tile), `UsageLevel.color` (views used the AppKit menu bar colour through `Color(nsColor:)`). 33 icon-only buttons now carry a label VoiceOver reads (the text of their tooltip, already translated); the pin button's title was never translated (a ternary of literals is plain text) — fixed. `PanelGlass`: reapplying on every panel update is kept on purpose (SwiftUI can bring the backdrop back; `apply` only hides what's new), but the panel no longer rewrites its window state and appearance when they didn't change.
Checked: `scripts/check.sh` green (all Mac tests, catalog unchanged: no new keys). Installed build, live: the panel opened with one posted click on the menu bar item — glass background and glass cards as before; Settings «Основные» and «Модули» look as before.
Left: —

## 2026-11-03 — refactoring stage 3: navigation (branch `refactor/stage3-navigation`)

Done: the Settings page is one key (`settingsPage`, `SettingsPane` as raw value: «general», «module.limits», «service.claude»); the three old keys (`settingsTab` + `servicesTab` / `settingsModule`, and the older «claude» tab) are migrated once and removed; `SettingsView.Tab` and the pane↔tab mapping are gone. Views open Settings one way — `@Environment(\.openSettingsPage)` (route + activate + open), replacing six hand-written variants; the assistant's «Подключить другой сервис…» opens Codex's page instead of whichever AI was viewed last. Windows have `WindowID` (scenes, `openWindow`, `dismissWindow`, `AppRequests`, CLI names); ids stored as text in notifications and widget links are converted at that boundary. UI state keys are in `StorageKey` (`collapsedBlocks` was spelled out in 12 places); the profile «Панель» edits is reset on every start. All in `Views/Navigation.swift`.
Checked: all Mac tests green locally (402: the old tab tests replaced by raw-value round trip, migration of the old keys, and leaving a new key alone). Installed build: Oleh's stored page migrated (old keys gone), writing `module.notch` opens «Остров у чёлки», `--app-command help` opens help.
Left: —

## 2026-11-03 — refactoring stage 2: one source of truth (branch `refactor/stage2-one-truth`)

Done: one rule for modules that go quiet — `ModeStore.isSilenced` (installed but not working: switched off, or a beta module without beta builds) — now used by notifications and the menu bar data alike (the menu bar looked only at `switchedOff`); a module no profile uses still speaks, as Oleh chose. `apply` no longer writes the old panel block flags (`hiddenBlocks`): the panel is `panelModules`, the flags are only read for files from before profiles; the export's legacy `showLimits`/`showSessions`/`menuBar` come from the current profile; the look's reset leaves the flags alone; the panel's redundant `settings.shows(.projects)` check is gone. The menu bar has one writer, `ModeStore.setMenuBar` (profile + the settings' copy for no profile), and one reader, `ModeStore.menuBar` — the menu bar item, its editor, module pages and the assistant use them (`MenuBarEdit.store` removed). The assistant keeps unticked built-in modules as `Set<ModuleKind>` instead of `PanelBlock`s; views use `Mode.moduleList` instead of re-normalizing.
Checked: all Mac tests green locally (400 → 402; three assertions that pinned the old flag writes now check `panelModules`/`menuBar`; new: one silence rule, legacy export fields from the profile, one menu bar writer). Installed build: «Строка меню» shows Oleh's profile config, and the real menu bar draws it (capsules, his lines, live data).
Left: `MenuBarData.without` still lists each module's fields (could move into the registry); panel cards — stage 4.

## 2026-11-03 — refactoring stage 1: module registry (branch `refactor/stage1-module-registry`)

Done: `ClaudePult/Modules/` — one file per module (`LimitsModule.swift` … `NotchModule.swift`) holding its `ModuleDefinition` (section, symbol, title, summary, tagline, flags, search words, places, menu bar elements, notifications and the module's own switches for the island, Telegram and alerts, how a built-in module is brought into a profile), its Settings sections (moved out of SettingsView.swift: 1363 → 749 lines) and its «Панель сейчас» line (`ModuleUI`). `ModuleKind.title/summary/…`, `ModuleGroup.modules`, `MenuBarElement.Kind.module`, `NotificationKind.module/of`, `ModulePlace.of`, `MenuBarEdit.primaryKinds`, `ModuleSwitch.enableAction/unavailableReason` and the module page's island/Telegram/alerts bindings now read the registry instead of switching over kinds. Texts moved word for word by a script: the string catalog didn't change.
Checked: `scripts/check.sh` green (all Mac tests, catalog: no new or lost keys); new `ModuleRegistryTests` (every module defined once, sidebar order as before, every place on a module's page has something behind it, menu bar elements and notifications have one owner at most). Installed build: «Сессии агентов», «Ресурсы Mac» and «Панель» look as before.
Left: the panel cards (`MenuPanelView`), `MenuBarData.without`, the assistant's module logic and the services' `isActive` still switch over kinds — stages 2 and 5. «Сессии агентов»'s summary still says hooks are in «Сервисы AI» → Claude Code (they moved to its own page): fix with its translations.

## 2026-11-03 — refactoring stage 0: safety net and audit bugs (branch `refactor/stage0-safety`)

Done: Oleh took the proposed answers (docs/SPEC-refactor.md §10). The test host now runs on its own throwaway UserDefaults suite and a temp profiles folder (`TestHost`), and the widget test calls `WidgetRequests.handle` instead of posting system-wide Darwin notifications that reached the installed app. Audit bugs fixed: switched-off modules travel in exports and «Заменить всё» takes the file's (`SettingsBundle.off`); `ModeEditor` takes the store's version when the profile changes elsewhere; a permission answer that can't be written is logged and the request stays open; a note that can't be saved shows «Не сохранено» in the panel; the help window's double `.defaultSize`; `--modes`/`--calendar`/`--export-settings` use a read-only `ModeStore`; `claude` lookup and the Telegram config read once instead of on every redraw; «Сравнение» rereads a file only when it changed; help picture colours and «мин»; the hooks hint opens «Сессии агентов». New: `FileFormatTests` pin the keys of profile files, state.json, exports and the menu bar config; `scripts/strings-check.py`, `scripts/strings-sync.sh`, `scripts/check.sh` (release.sh runs it first); `.github/workflows/mac.yml` (catalog check on Linux, tests on macos-26).
Checked: `scripts/check.sh` green (catalog 0 problems, desktop texts current, all Mac tests); the sync script found and the check now passes for the 2 new strings.
CI (first runs on this PR): GitHub's `macos-26` image has Xcode up to 26.6, not 27 — two expressions split and one method-reference binding setter replaced by a closure (Swift 6.3 crashed in IRGen on it); tests run with `-testLanguage ru -testRegion RU`; tests that needed `~/Projects/_daily-report` now make their own (`TestFolders.dailyReport()`); the approval hook test waits up to 20 s for a cold Python start. Result: 395 tests green on GitHub (Xcode 26.6) and locally (Xcode 27.2).
Left: `PanelGlass` reapplied on every panel update — moved to stage 4 (needs a live look at the glass).

## 2026-11-03 — refactoring audit (branch `docs/refactor-audit`)

Done: on Oleh's «Начни с аудита» — four read-only audits in parallel (modules, views and navigation, services and wiring, tests and tooling), key findings re-checked in the code, plan written to docs/SPEC-refactor.md: 9 bugs to fix first (exports lose switched-off modules; «module off» decided four ways; ModeEditor's stale copy; tests run the real app on real data and poke the installed copy; a permission answer or a note can be lost silently; the help window's double `.defaultSize` from #206; read-only CLI commands write; heavy work in `body`), the module registry, the legacy panel layer, navigation, big files, app composition, polling, AppSettings, CLI, tooling (Mac tests not in CI though the repo is public), docs, safe and unsafe ClaudePult names; 8 stages.
Checked: claims spot-checked against the code (ModeStore export/import, ClaudePultApp init order, WidgetStatusTests, Approvals/NotesStore writes, help window scene, MenuPanelView projects check); no code changed.
Left: Oleh's decisions (§10) before stage 0.

## 2026-11-03 — help: new window and a site page (branch `feat/help`)

Done: Oleh asked for a modern help with animation and pictures, in the app and on the site (docs/SPEC-help.md). The help window is rebuilt: 15 topics in five sections with search (first match opens, matching cards highlighted), each page with a big icon, «Открыть в настройках», an animated picture drawn from the app's own pieces (the real menu bar renderer, module icons; Reduce Motion — still last frame, «Показать ещё раз»), «Как начать» steps and «Что умеет» cards; readiness on «Начало», feedback under the topics. Old help texts that are still true kept their wording and translations; 87 new strings translated into 12 languages by a separate agent with the catalog as glossary. `AIHubBar --help-export <file>` writes the help as JSON in the process language; `scripts/export-help.sh` writes `site/help/<language>.json` for all 13. `site/help.html` renders them with CSS-animated scenes (language picker, browser language by default, RTL for Arabic, reduced motion, compact contents on phones); «Help» link in the site's header.
Checked: `xcodebuild test` 389 green (new HelpTests). Help window seen on this Mac (screenshots of 6 topics mid-animation). Site checked in the built-in browser via the `site` preview: ru, en, ar (RTL), phone width; no console errors; no Cyrillic in the 11 non-Slavic JSON files.
Left: the site page goes live after merge (Pages workflow). Translations are machine-made and not reviewed by native speakers.

## 2026-11-03 — release 0.4.0 (branch `chore/status-release-0.4.0`)

Done: on Oleh's «Давай релиз 0.4» published 0.4.0 from main `b4ccf4f` (build 458) with `scripts/release.sh 0.4.0 --publish`; release notes list what's new since 0.3.0 (Settings around modules, menu bar dividers and capsules, beta builds). «Раскладка» stays a beta feature (only with «Бета-версии» on).
Checked: 385/385 Mac tests on main; the app signed «ClaudePult Release»; `releases/latest/download/appcast.xml` gives 0.4.0 (458), the DMG downloads (200, 12.7 MB); the release is the latest one, not a pre-release; the beta channel's appcast also points to 0.4.0.
Left: the overview PDFs attached to the release are the 0.3.0 ones (they don't show the new Settings).

## 2026-11-02 — Settings, second wave: 12 items (branch `feat/settings-polish`)

Done: reorder without a mouse (⌃/⌄ in «Панель»; «Левее / Правее / Убрать» on menu bar chips via inspector, context menu and VoiceOver); a profile's blocks edited only in «Панель» (profile picker, «Добавить модуль»; «Профили» shows a line and a link); notification frequency on each module's page, not in «Основные»; icons on every settings row (`IconRow`); long footnotes fold to their first sentence with «Подробнее»; built-in modules missing from the profile get «Включить в профиле» (calendar, `_daily-report`) or «Открыть профиль»; «Фоновые задачи» moved to «Сессии агентов», Telegram chip there explained; «Панель сейчас» shows live data of each block; «Сервисы AI» folded in the sidebar; the Settings window grows (SwiftUI drops `.resizable` after each layout, a KVO observer puts it back). 25 new strings translated; all ~97 new strings of both waves reviewed by a separate agent, 32 fixes (German «Sie», ja 制限, ko 배열, uk phrasing, «строка» = menu bar).
Checked: `xcodebuild test` 385 green. Live on this Mac with posted mouse events: drag in «Панель» (block moved and back), ⌃ button, divider dragged onto a menu bar chip then removed with «Убрать», window resized to 1100 × 800 and stays; screenshots of «Панель» at both sizes.
Left: none known. The panel preview is a live miniature, not the panel view itself (that one takes over its window).

## 2026-11-02 — Settings rebuilt around modules (branch `feat/settings-redesign`)

Done: Oleh chose variant A + tiles from B + builder from C (docs/SPEC-settings.md). Every module, built-in ones too, has a main switch (`state.json` → `off`): off stops its background work, panel block, menu bar data and notifications and keeps its place in the profiles, so «only AI» or «only the layout switch» works. Settings sidebar by section (AI, Сервисы AI, Работа, Mac) with a page per module: big header with the switch, «Где показывать» chips (panel, menu bar, island, notifications, Telegram — shortcuts to existing settings), its settings with icons, text 13.5 pt. «Модули» is tiles with sets (Только AI, Только раскладка, Утилиты Mac, Всё); «Панель» is the profile's blocks with drag, switches and a sketch. Menu bar: dividers placed by hand any number of times (space, wide space, ·, |, thin line, /, ›, new group; drawn only between two visible elements), «Капсулы по группам» look, new editor (live preview, order chips with drag, element palette by module, inspector). Hooks/approvals moved from Claude Code to «Сессии агентов». New strings translated into all 12 languages.
Checked: `xcodebuild test` 382 tests green (new: ModuleSwitchTests, MenuBarDividerTests, sidebar sections). Installed build: screenshots of a module page, «Модули», «Панель», «Строка меню»; dividers and capsules drawn to PNG and looked at.
Left: drag-and-drop in «Панель» and «Строка меню» not tried by hand (no mouse checks this time). The island chip shows only while «Остров у чёлки» is on.

## 2026-11-02 — «Раскладка» works live: signed local builds, real access check (branch `fix/layout-access`)

Done: Auto-fix did nothing for Oleh: the key tap never started. The app had no Accessibility access although System Settings showed AI Hub Bar on — the entry was made for an older ad-hoc build, and every ad-hoc build has a new signature. Now `scripts/build-and-install.sh` signs with the «ClaudePult Release» certificate (shared `scripts/release-tools/sign-app.sh`, also used by `release.sh`), so the permission survives builds. The switcher tries the tap itself as the access check (`AXIsProcessTrusted` said no while the list said yes), logs Accessibility / input monitoring / posting once, asks macOS, and fades the menu bar language until access is there. Oleh ran `tccutil reset Accessibility com.demishev.claudepult` and allowed again.
Checked: live on this Mac, build 438, TextEdit with real key events: «ghbdtn»+space → «привет », the «hello» keys in the Russian layout → «hello », layout switched both ways (log: «fixed a word, en → ru», «ru → en»); double Shift right after a fix → «ghbdtn », layout back to English, word learned (then removed from the list again). `xcodebuild build` clean.
Left: ⌥⇧ on a selection and other apps (Telegram, Chrome) not tried. TextEdit capitalises the first word itself («Привет»).

## 2026-11-02 — «Раскладка» always visible in Modules (branch `fix/beta-module-visible`)

Done: Oleh couldn't find «Раскладка»: with «Бета-версии» off the module was hidden from the catalog, so the search led to an empty place. Now beta modules are always listed with the «бета» badge, a note and a «Включить бета-версии» button instead of «Установить»; the search finds «Раскладка» and its switches regardless. `betaUpdates` tells Sparkle itself (AppSettings), wherever it is switched on. Build 435 installed on this Mac.
Checked: `xcodebuild test` — 370 green; build 435 opened on Settings → Модули on screen (the list itself not scrolled to «Раскладка»: the app's windows can't be driven from here).
Left: «Раскладка» not tried live (Accessibility is Oleh's).

## 2026-11-02 — Settings search finds «Бета-версии» and «Раскладка» (branch `fix/settings-search-layout`)

Done: The Settings sidebar search finds «Бета-версии» (General) and, with beta on, «Раскладка» and its switches (Modules). Build 432 installed on this Mac with `scripts/build-and-install.sh` — 0.3.0 from Releases had none of #195, which is why Oleh couldn't find the settings.
Checked: `xcodebuild test` — 370 green (new: searchFindsBetaAndTheLayoutModule); the installed build has the new strings and keys.
Left: «Раскладка» still not tried live (Accessibility is Oleh's).

## 2026-11-02 — Windows/Linux postponed (branch `chore/status-postpone-desktop`)

Done: Oleh postponed the Windows and Linux builds. Taken out of Next and Needs Oleh; the code in `desktop/` and its CI stay as they are.
Checked: STATUS only.
Left: where it stopped — rest of stage 2 (Telegram, spend per project, own thresholds), rest of stage 3 («Показать», alive check, permission answers), then stage 4 (docs/SPEC-windows.md §9); SPEC-windows §10 defaults and signing still Oleh's.

## 2026-11-02 — beta builds and «Раскладка», auto layout switch in beta (branch `feat/layout-switcher`)

Done: Beta (canary) builds: Settings → General → «Бета-версии» points Sparkle at the beta channel's appcast (release tagged `beta`) and lets it take `<sparkle:channel>beta</sparkle:channel>` items; `scripts/release.sh X.Y.Z-beta.N --publish` makes a GitHub pre-release and every publish rewrites the beta appcast with the newest release + newest beta (`scripts/release-tools/beta-feed.py`); docs/RELEASE.md «Beta builds». `ModuleKind.isBeta`: such a module shows in the catalog with a «бета» badge and works only with beta on. New optional module «Раскладка» (docs/SPEC-layout.md), beta: a word typed in the wrong layout is retyped after space/Enter/Tab and the layout switches, checked by the system spell checker (ru, en, uk, de, fr, pt, es); double Shift converts the last word or takes a fix back and learns the word (⌘Z learns too); ⌥⇧ converts the selection via the clipboard and restores it; language badge in the menu bar blinks on a switch; skips terminals, password fields, digits, one-letter words. Translations for 12 languages. Decisions in DECISIONS.md.
Checked: `xcodebuild test` — 369 tests green (14 new in LayoutSwitchTests, one on this Mac's real ABC/Russian layouts and dictionaries); Debug build without warnings in new code; `beta-feed.py` merged sample appcasts correctly, `bash -n scripts/release.sh`. CI has no Mac checks.
Left: not tried live — the key tap needs Accessibility, which only Oleh can grant (Needs Oleh). No beta published, so the beta appcast URL is 404 until the first one. Typing goes through synthetic key events: apps that read key codes instead of text (some games, remote desktops) may get wrong letters.

## 2026-11-02 — release 0.3.0 (branch `chore/status-release-0.3.0`)

Done: on Oleh's «смержим все изменения и сделаем релиз последней версии» — nothing was left unmerged (no open PRs or branches); published 0.3.0 from main `c0fd510` (build 424) with `scripts/release.sh 0.3.0 --publish`, instead of the earlier plan to publish from `91d6c2b`. Release notes list what's new since 0.2.2.
Checked: 355/355 Mac tests on main; the app signed «ClaudePult Release», Sparkle signature valid; `releases/latest/download/appcast.xml` gives 0.3.0 (424), the DMG downloads (200, 11.8 MB); the release is marked Latest.
Left: not checked on the MacBook Air at a real notch. The Windows/Linux version is not part of this release.

## 2026-11-02 — local builds no longer «update» back to 0.2.2 (branch `fix/local-build-version`)

Done: Oleh saw the old Settings again: the installed app was 0.2.2 (build 345) again. A build from `scripts/build-and-install.sh` was numbered 0.1.0 (1), so Sparkle offered the published 0.2.2 as an update and, when installed, replaced the build from main (20:51). The script now numbers builds like `release.sh` (build = commit count, version = newest tag), and the app from main is reinstalled.
Checked: `scripts/build-and-install.sh` → «0.2.2 (422)» in the installed Info.plist, the app runs; 422 > 345, so Sparkle has nothing to offer.
Left: a release from an older commit (0.3.0 from `91d6c2b`, build 400) is not offered to builds from main either — as it should be.

## 2026-11-02 — Windows and Linux, stage 3 «Сессии», main part (branch `feat/desktop-sessions`)

Done:
- **`claudepult-hook`** — a Rust port of the Mac's Python hook, format 3. It writes the same session file: state, current action, task list, `prompt_at`, the once-a-minute throttle with task-list calls always written. It adds `wt_session`. It finds the Claude process by walking the parents: a Toolhelp snapshot on Windows, `ps` on Linux. It never prints and always exits 0, even on a panic.
- **`core/hooks.rs`** — the Mac's merge and removal in exec form (`command` + `args`, so no shell and no quoting), with a backup, an idempotent reinstall, other hooks kept, and a non-object file left alone.
- **`core/sessions.rs`** — the Mac's rules: visible (stale after 2 h, ended kept 15 min), order, the action in words, task-list progress, files older than a week deleted.
- **The app (`sessions.rs`)**:
  - the folder read every 3 s;
  - the panel's sessions card: state dot, project, what it waits for or does, «1/3»;
  - an orange dot on the tray ring while one waits;
  - Settings → Hooks: status, install/update/remove.
- **On a Mac** the install is refused unless `CLAUDE_CONFIG_DIR` points elsewhere (both in the UI and in the command), so the dev build can't touch the Mac app's hooks.
- **The installer** carries `claudepult-hook` and `claudepult` next to the app (`app/tauri.bundle.conf.json` + `scripts/stage-binaries.sh`; CI uses them).
- **1 new text** with 12 translations.
- **A fix found here:** `strings.py` now also takes texts from `core/` and only calls on a `Strings` value. Before, the limits texts would have stayed Russian on Windows. Carried back into #190.

Checked:
- `cargo test --workspace` on the Mac — 28 core, the socket round trip, 3 hook integration tests with the real binary;
- a local bundle had `AIHubBar`, `claudepult`, `claudepult-hook` side by side (then removed);
- the app run on the Mac: the built hook fed two sessions in the dev folder, and the panel showed «Ambo — Нужно разрешение: Bash» (orange) and «ClaudePult — правит sessions.rs, 1/3» (blue) (captured);
- Settings showed Hooks «нужно обновить» (it sees the Mac app's own hook) with the buttons disabled;
- the fake sessions were removed.

Left:
- «Show»;
- the alive check (sessions go stale by time only);
- answering permission requests;
- the Claude desktop app's sessions;
- the drawn dot and the hook seen only on the Mac; on Windows only CI.

## 2026-11-02 — Windows and Linux, stage 2 «Лимиты», main part (branch `feat/desktop-limits`)

Done:
- **`core/usage.rs`** — the Mac's `Usage.swift` / `UsageService.swift` with the same rules:
  - the token from `<claude dir>/.credentials.json`, read for each request, never kept;
  - the request with the Mac's headers (ureq, rustls);
  - the tolerant parsing: `five_hour`, `seven_day`, `seven_day_<model>`, per-model weeks from `limits`, extra usage;
  - reset times compared to 10 minutes;
  - levels, the 30-minute forecast;
  - alerts once per window, with only the highest new threshold;
  - pauses after 429 (5→60 min, a short `Retry-After` not trusted);
  - polling every 2 min while the session grows, else 5;
  - `usage.json` in the same format.
- **`core/texts.rs`** — countdowns, resets, the tray hint, the forecast, errors and alert texts from the Mac catalog. All the keys already existed there.
- **`core/tray_icon.rs`** — the session ring drawn in RGBA in the level's colour, with an optional dot.
- **The app (`limits.rs`)** — a background thread, notifications at 50 / 80 / 95 % (tauri-plugin-notification), `usage.json` and `usage-notified.json` in the data folder, the tray icon and hint updated after each answer, the panel's «Лимиты» card (rings, other weeks, forecast, error) with ↻.

Checked:
- `cargo test --workspace` on the Mac — 22 core tests and the socket round trip;
- `strings.py --check`;
- the app run on the Mac with a temporary `CLAUDE_CONFIG_DIR` and a fake token: a real request to the limits server answered 401, and the panel showed «Сессия Claude Code истекла (HTTP 401): claude → /login» (captured);
- the real token was not used.

Left:
- not seen with a real token: the rings and the drawn tray icon (on the Mac the token is in the Keychain, and the CLI here is signed out);
- Telegram, spend per project, custom thresholds, history for the forecast after a restart.

## 2026-11-02 — Windows and Linux, stage 1 «Каркас» in `desktop/` (branch `feat/desktop-skeleton`)

Done: Oleh said «переделку под Windows» and stepped away; SPEC-windows §10 was taken as proposed (Tauri 2, `desktop/` here, Windows 10 22H2 + 11, WSL later; signing stays his — DECISIONS.md). Stage 0 was checked against current documentation and source instead of a VM (a research pass over Claude Code docs 2.1.316, Windows Terminal source, Microsoft and Tauri docs): confirmed the token file, `~/.claude` paths, hooks (Git Bash or PowerShell, exec form), installers, `wt -w … focus-tab`, toasts, autostart; three corrections written into SPEC-windows (Ctrl+Break probably skips `SessionEnd`, `wt` sessions are outside our process tree, hooks in exec form); open: the desktop app's session folder and `claude://code/continue`. Stage 1: a Rust workspace — `core` (paths: `%LOCALAPPDATA%\ClaudePult`, `~/.local/share/claudepult`, on a Mac only `ClaudePult Desktop Dev`; tolerant `settings.json`; 13 languages with the system's preferred list, English fallback, `%@`/`%lld`/positional placeholders; the `claudepult` link — named pipe / abstract socket / `/tmp` socket, one-line protocol), the app `AIHubBar` (tray icon and menu, the panel at the icon or the tray corner, hide on blur, the settings window with language and start at sign-in, the «^» hint on Windows, one running copy, everything also through `claudepult --app-command panel|settings|quit`), the console `claudepult`. Texts from the Mac catalog by `desktop/scripts/strings.py` (5 new texts added to the catalog with 12 translations; `--check` fails on a missing key or translation). Icons from the Mac icon. `.github/workflows/desktop.yml`: texts check, `cargo test` on Windows and Ubuntu, NSIS installer and `.deb` as artifacts (free: the repository is public). Found and fixed on the way: `ClaudePult` and `claudepult` overwrite each other on case-insensitive disks (the app is now `AIHubBar`); a socket file left by a test blocked the link (now taken over).
Checked: `cargo test --workspace` on the Mac — 10 pass (9 unit + a real socket round trip); `strings.py --check`; `npx tauri build --debug --no-bundle` on the Mac; the app run on the Mac: `claudepult --app-command settings / panel / nope / quit` — settings window and panel captured, unknown command → exit 2, quit ends the app. Mac app tests 355 / 355 (the catalog changed). Windows and Linux: see the PR's CI run.
Left: nothing run live on Windows or Linux; the tray icon is the app icon (drawn icon is stage 2); the panel has no content yet; no code signing.

## 2026-11-02 — «Скрыть остров» in the panel header (branch `feat/notch-hide-in-panel`)

Done: a laptop icon in the ✦ panel's header (next to ⚙) hides and shows the notch island (`laptopcomputer` / `laptopcomputer.slash`, hint «Скрыть / Показать остров у чёлки»), only while the island module is installed — the last open item of notch stage 3 besides VoiceOver. 2 strings in 13 languages; SPEC-notch §9, REFERENCE updated.
Checked: `xcodebuild test` — 355 / 355 pass; Release build installed. The panel itself not opened (it needs a click on the menu bar while Oleh is away).
Left: a look at the icon in the panel.

## 2026-11-02 — Notch island stage 5: a file on the island → AI commands (branch `feat/notch-file-drop`)

Done: dragging a file or folder to the notch makes the island a drop target («Отпустите — AI-команды для файла»); the dropped item opens a card with its icon, name and folder, «Команды профиля «…» · service», the current profile's commands plus «Своя задача» (a field, Enter runs), «Отмена» / Esc. Running goes through `CommandEngine` like a folder project's commands: `FolderProject.dropped` makes the file's folder (or the dropped folder) the project and the file its main file; the profile's service; the result is a new file next to it; a «Запущено: …» banner follows. Detection: at rest the window ignores the mouse, so the global monitor watches `leftMouseDragged` with a new drag pasteboard `changeCount` holding files; over the zone at the notch (notch + 56 pt, card width) the window takes the mouse and `NotchHostingView` accepts the drop. The card with a file doesn't close when the pointer leaves. Works on the pill too. Setting «Файл на остров — AI-команды», on by default. First file of several; nothing is copied anywhere. 6 new strings in 13 languages; SPEC-notch §9, REFERENCE updated.
Checked: `xcodebuild test` — 355 / 355 pass (new `NotchFileDropTests`: a file runs in its folder with itself as the main file and the result named next to it, a folder is the project, the setting's default). Live with the simulated notch: a test window started a real file drag driven by posted mouse events; a global-monitor probe saw the drag events; the island logged «черновик.md» dropped, the card opened (captured), «Своя задача» showed the field and took typed text (captured). Simulation flag removed afterwards, app restarted.
Left: one of two test drags didn't land (the drag ended with no drop) — cause not found, to watch on the Air with Finder; a command was not run to the end (the CLI's sign-in has expired here); a leftover test folder only in the scratchpad.

## 2026-11-02 — Notch island stage 4: Claude's task list in the island (branch `feat/notch-live-activity`)

Done: the hook (format 3) keeps the session's task list in `todos` (up to 20, text cut to 120) and `prompt_at`: `TodoWrite` replaces the list, `TaskCreate` adds a task with the id from `tool_response.task.id`, `TaskUpdate` changes status / subject / `activeForm` or removes it (`"deleted"`); task-list calls skip the once-a-minute throttle; a new request after a finished list drops it, `Stop` keeps it, `SessionEnd` and a fresh start drop it. Field names read from Claude Code 2.1.314 itself (a live `claude -p` probe failed: the CLI's sign-in has expired here). `Session` reads `todos` / `prompt_at` (`progress`, `currentTodo`). The sessions ear: ring and «3/7» for the working session given a request last (older records without `prompt_at` count from their start), else for a single working session the dot and «4′»; hint and VoiceOver «ClaudePult: сделано 1 из 3, Пишет тесты, 4 мин». The card: steps under that session (✓ / ● activeForm / ○, up to 7 around the current one, «ещё N»), each working session's time since its request. «Готово»: «3/3 · 2 мин · файлов: 9» (files from git after the banner's short wait). Setting «Ход работы Claude в ушке сессий», on by default; off gives the old behaviour. The island's window is now 440 pt tall under the notch so the longer card isn't cut. 7 new strings in 13 languages; SPEC-notch §9, REFERENCE updated.
Checked: `xcodebuild test` — 352 / 352 pass (new `NotchLiveActivityTests`: the hook with `TodoWrite` twice in a row, `TaskCreate` / `TaskUpdate` incl. deleted and unknown ids, when the list goes, the 20 limit, old records; which session the ear follows; texts; the seven-step window; the setting's default). Live with the simulated notch: the installed hook updated itself; fake events for a session «live-check-1» gave the ear «1/3» with a ring, the card its three steps and «2 мин», and after the list was done and `Stop` the banner «Готово: ClaudePult · 3/3 · 2 мин · файлов: 9» — all captured. The first try showed the card following the wrong session (one without `prompt_at` that had just used a tool); fixed and covered by a test. The fake session file and the simulation flag removed afterwards.
Left: not seen with a real Claude session making a plan (needs the CLI signed in, or the MacBook Air); VoiceOver not walked live; 0.3.0 must be published from `91d6c2b` so this stage goes into the next version.

## 2026-11-02 — Build 0.3.0 for the MacBook Air (branch `chore/status-build-030`)

Done: `scripts/release.sh 0.3.0` from main at #182 — Release build, signed «ClaudePult Release», `AIHubBar-0.3.0.dmg` (11 MB, build 400) and `appcast.xml` signed for Sparkle in `build/release/0.3.0/`. Not published: no GitHub release, so installed copies don't see it yet.
Checked: the .dmg mounts and holds the app and the Applications link; version 0.3.0 / 400; `codesign --verify --deep --strict` passes, authority «ClaudePult Release»; the release app launched here in place of the dev copy — island placed, `test-island` banner captured, log clean apart from HTTP 429 on the limits API after several restarts in a row (its own back-off); the dev copy started again afterwards. Tests: 343 / 343 on the merged code (#181).
Left: the island at a real notch, full screen and two screens only on the MacBook Air; publishing after Oleh's check — a later `--publish` run gets a new build number, and the .dmg changes.

## 2026-11-02 — Notch island stage 3, part 3: all screens, island quick toggle (branch `feat/notch-all-screens`)

Done: «Где показывать» got «все экраны» (`NotchScreen.all`): `NotchGeometry.choose` now returns one place per screen — the notch where there is one, the pill on the others when the pill is on; the other two choices still give one island. `NotchIsland` keeps `places` (geometry + full screen per screen) and one panel per place; the same banner goes to every screen, the card opens only on the screen hovered or clicked (`openIndex`), clicks pass through everywhere else; ears and full screen are per screen, and only when every screen has a full-screen app does the island drop everything but requests and waits. `NotchIslandView(index:)` draws one place. The simulated notch (`notchSimulate`) now goes through the same screen list, so it works with every choice. Quick Toggles got «Остров» (shows / hides the island, lit while it is shown), listed only while the island module is installed. 2 new strings in 13 languages; SPEC-notch §9 and REFERENCE updated.
Checked: `xcodebuild test` — 343 / 343 pass (new: every screen with and without the pill, the simulated notch, the toggle listed only with the island, the toggle hides and shows it). Live on the Mac mini (one screen): Release build installed, the pill and a `test-island` banner captured; with `notchSimulate` the notch and its ears captured (184×32, as before), then the flag removed.
Left: no second screen here, so «все экраны» with two screens is checked only by tests — needs the MacBook Air with a monitor; the toggle not tried in the panel (Quick Toggles is not installed in Oleh's profile, left as is); «Скрыть остров» in the ✦ menu and a live VoiceOver walk not done.

## 2026-11-02 — Notch island stage 3, part 2: full screen, ⌃⌥Y / ⌃⌥N, first-setup window (#179)

Done: the island's panel joins full-screen spaces (`.fullScreenAuxiliary`); `FullScreenDetector` sees another app's normal window over the whole screen (window bounds from `CGWindowList`, no permission), checked on space and app changes — then no ears, and only requests and waits (`NotchEventQueue.keepOnly`, no «done» banners). `GlobalHotKey` now tells its keys apart (`EventHotKeyID` from the event) and registers ⌃⌥Y / ⌃⌥N while «Горячие клавиши ⌃⌥Y / ⌃⌥N для запросов» is on; `NotchIsland.answerByKey` answers the request on the banner or first in the card once it has been shown 0.6 s (`NotchClickGuard.keysArmed`, no pointer movement needed). `NotchSetupView` — the first-setup window (§6.1) with four questions: requests (island and notification / island only), the summary's place (Oleh's ask), the pill, the hot keys; `NotchSettings.setupDone` keeps it from coming back, closing it unanswered keeps the defaults. It opens by itself a few seconds after launch while unanswered: the first try crashed (the hook was set while the app was still being made, before `NSApp`), the second never showed (the request came before the menu bar label could open it) — now `AppRequests.takeWindow` lets the label open a request made before it appeared. `--app-command notch-setup` opens it too. 15 new strings in 13 languages; SPEC-notch §9 and REFERENCE updated.
Checked: `xcodebuild test` — 333 / 333 pass (new `NotchFullScreenAndKeysTests`: a full-screen window vs a zoomed one, the menu bar layer and our own, on a second screen; keys need only time; full screen keeps requests and waits; setup answers decode). Live: with the setup flag reset, the window opened by itself after launch (`Notch island: asking for the first setup`), 480 pt wide, captured; left open for Oleh to answer.
Left: full screen and the hot keys not tried live (no notch here; the pill would show them); «on all screens» and the Quick Toggles switch not done.

## 2026-11-02 — Feedback and crash reports (branch `feat/feedback`)

Done: Settings → General → «Обратная связь» and the bottom of the Help window: «Предложить идею…» / «Сообщить о проблеме…» open the repository's issue forms with `version` and `macos` filled through the link. 3 s after launch the app reads its own `AIHubBar-*.ips` / `ClaudePult-*.ips` in `~/Library/Logs/DiagnosticReports` written since the last check (first check: one day back; unit-test crashes skipped) and asks «Сообщить на GitHub…»: bug form with title `Crash: <exception> in <app frame>`, 8 top frames of the crashed thread, report's version, last 25 log lines (home → `~`, account → `USER`, cut so the link stays under 7 500 characters); a redacted `.txt` copy of the full report is shown in Finder to drag in. «Больше не предлагать» / a switch in Settings. No server, the app sends nothing itself. 11 new strings in 12 languages; GUIDE (privacy, troubleshooting) and REFERENCE updated. Code: `ClaudePult/Services/Feedback.swift`.
Checked: `xcodebuild test` — 335 tests pass (6 new: parsing, skipping other apps' and test-host reports, folder scan, link fields, log cut, redaction); built and installed — on launch the app found the real crash of 16:46 (notch branch build, nil unwrap in `NotchIsland.update()` from `needsSetup.didSet` in `ClaudePultApp.init()`) and showed the alert; the 15:43 test-host crash was skipped.
Left: the «Сообщить на GitHub…» click (browser form, Finder) not pressed by the agent — Oleh's check; release builds' dSYMs are not kept, so app frames of stripped builds may show only offsets; automatic sending (Sentry or a Cloudflare Worker → Telegram) is a possible later step.

## 2026-11-02 — Notch island: live activity stage in the spec (branch `docs/notch-live-activity`)

Done: docs/SPEC-notch.md gets §3.4 «Живая активность сессии» and a new stage 4 in §9 (drag-and-drop moves to stage 5): while Claude works, the sessions ear shows a progress ring and «3/7» from its plan (`TodoWrite`, or `TaskCreate` / `TaskUpdate` in newer Claude Code, read by the existing `PostToolUse` hook), the card lists the steps, «Сессия закончила» adds progress, minutes and changed files. Oleh agreed to it as the stage after 0.3.0; a now-playing remote in the notch was discussed and dropped (other notch apps already do it, §8).
Checked: docs only; the hook already receives every `PostToolUse` (matcher `*`, `HookInstaller`), so the data source exists; Task* field names are left to check against live hook data at the start of the stage.
Left: the stage itself, after 0.3.0.

## 2026-11-02 — Notch island stage 3, part 1: pill, screen choice, summary where Oleh wants it (#173)

Done: `NotchSettings` gets `summary` (Oleh's ask: «в строке меню и в острове» · «только в острове» · «только в строке меню»), `screen` (экран с чёлкой · главный экран), `pill` (nil = on only when the Mac has no notch screen) and `hidden`; old settings decode to the defaults. `NotchGeometry.choose` picks the chosen screen's notch, else the main screen's pill; the pill is a zero-height «notch» at the menu bar's bottom edge, so the window hangs under the menu bar, nothing shows or takes hover at rest, and `IslandShape` draws it rounded all round with a faint edge. With «только в острове» the menu bar uses `MenuBarConfig.iconOnly` (icon and the projects' red dot) while the ears are on screen; with «только в строке меню» the island has no ears. Settings → Модули → «Остров у чёлки»: a new first section (hide, summary, where, pill), the ears in «Ушки и карточка». `AIHubBar --app-command test-island` pushes a trial banner through the island. 13 new strings in 13 languages. The docs went in a follow-up PR: the script that wrote them failed on its encoding after the code was already merged.
Checked: `xcodebuild test` — 328 / 328 pass (new `NotchPlacementTests`: notch screen first, main screen's pill, no pill when off, the pill under a 30 pt menu bar with nothing to hover, old settings and the pill default, `iconOnly` keeps something to click). Live on this Mac mini with an LG monitor (no notch): the log says `Notch island at {{1180, 1050}, {200, 0}}`, and `test-island` showed the black pill centred under the menu bar with «AI Hub Bar: остров работает» (screen captured).
Left: «только в острове» and the screen choice on a Mac with a notch (Needs Oleh); part 2 — full screen, hot keys, first-setup window, all screens, VoiceOver / Reduce Motion walk.

## 2026-11-02 — Chinese models by API (branch `feat/chinese-models`)

Done: four new API providers in «Сервисы AI» → «Другие», beside DeepSeek: Alibaba Qwen, Moonshot Kimi, Z.ai GLM, MiniMax (international endpoints, key pages, OpenAI-compatible chat). `APIProvider.knownModels` lists each one's current models from its docs; «Проверить» picks the best of them from the list, and for Z.ai (no `/models`) a 404 after the key check returns that list. Doubao left out (docs unreadable, per-account endpoint ids). Why and how — DECISIONS.md. GUIDE / REFERENCE / README / SPEC-ai-services list the new providers.
Checked: `xcodebuild test` — 325 / 325 pass (new `chineseProvidersCheck`, `preferredModel` with a provider). Unauthenticated probes of each endpoint: `/models` and `/chat/completions` answer 401 (bad key), a made-up path 404 at Alibaba / Moonshot / MiniMax. Debug build `--services check` lists `api qwen`, `kimi`, `glm`, `minimax`.
Left: no real key, so no live reply from any of the four; Settings UI not looked at (rows come from the same `ProviderRow` as DeepSeek). Strings: provider names only, no new translations.

## 2026-11-02 — Antigravity conversations in «Сессии»; Gemini CLI sign-in is gone (branch `feat/antigravity-sessions`)

Done: Oleh signed in to Antigravity CLI (agy 1.4.12); one short `agy -p` task then ran. Its records: `~/.gemini/antigravity-cli/conversation_summaries.db` (title, `workspace_uris`, `last_modified_time`, run `status`); no limits or token counts readable on disk (`agy models` lists models only; usage is in protobuf blobs). New `AntigravityConversations` (recent top-level conversations of the last 3 hours, «работает» while `…_RUNNING`), `AgentThread.isWorking`, resume `agy --conversation <id>`; `AIHubBar --services limits` now also prints every agent's recent conversations. Gemini CLI 0.66: its Google sign-in fails — «This client is no longer supported for Gemini Code Assist for individuals … migrate to Antigravity» — so there is nothing more to read from it. SPEC-ai-services and REFERENCE updated. No new strings.
Checked: `xcodebuild test` — 324 / 324 pass (new `AntigravityConversationsTests`: time parsing with microseconds, text stamps, subagents and old conversations left out, running status, `--conversation` command). Live: `--services limits` → `thread agy agents-check …`, `thread copilot agents-check …, context 11 %`, `thread codex codex-check …, context 6 %`.
Left: the panel row for Antigravity not captured (same row as Codex / Copilot, checked earlier); Cursor CLI not installed.

## 2026-11-02 — Copilot CLI in full; common agent rows (branch `feat/copilot-in-full`)

Done: with Copilot CLI 1.0.105 installed by Oleh and one short task (it signed in through `gh`), its own records were read: `~/.copilot/session-store.db` (`sessions`, `assistant_usage_events` with tokens and `total_nano_aiu`) and `session-state/<id>/events.jsonl` (`session.usage_record` with `inputTokens` / `maxPromptTokens`). New `Services/AgentThreads.swift`: `AgentThread` (a recent conversation of any non-Claude agent, with its `resume` command), `SQLiteReader` (read-only queries; a WAL database whose agent has quit has no `-shm`, which a read-only open can't create — then it is read as immutable, nothing written next to it; Codex's reader broke exactly that way once Codex quit), `CopilotSessions` (recent sessions, context fill, tokens and AI credits per project this week). The Copilot card shows «AI-кредиты за неделю», tokens per project and the latest session's context; «Сессии» lists Codex and Copilot conversations with each agent's icon (click → `codex resume` / `copilot --resume=<id>`). Install commands: Antigravity is `brew install --cask antigravity-cli` (Homebrew's replacement for the deprecated `gemini-cli`, links `agy`); the Gemini CLI note says Homebrew disables `gemini-cli` on 2026-12-18. Strings: 4 new, the Gemini note re-keyed, 3 unused removed — 13 languages.
Checked: `xcodebuild test` — 322 / 322 pass (new `CopilotSessionsTests` on the real schema: recent sessions, context 25 %, tokens and credits per project; `SQLiteReader` on a closed WAL database in a folder with a space; Codex resume / Copilot `--resume` commands). Live: `--services limits` → `copilot: … note AI-кредиты за неделю: 0,12, note Контекст … «agents-check»: 11 %, project agents-check: 14269 tokens` and Codex's notes back after the immutable fallback; the panel's «Сессии» (expanded for the capture, then restored) shows `agents-check` (Copilot) and `codex-check` (Codex) rows. An ISO formatter without the time zone made the first test crash — fixed with `ISO8601DateFormatter`.
Left: Gemini CLI and Antigravity are installed but not signed in (their folders hold only what the failed runs left); Cursor CLI isn't installed.

## 2026-11-02 — AI services stages 5–6: Codex threads in «Сессии», Gemini / Copilot / Cursor (branch `feat/codex-sessions`)

Done: stage 5 — `CodexThreads.recent` reads threads updated in the last 3 hours (id, title, folder, context from the rollout) and the panel's «Сессии» lists them under Claude's sessions with the same row frame: project, title, «N мин назад», context from 70 %; a click runs `codex resume <id>` in Terminal in the thread's folder. The Codex `notify` hook was not installed: Codex allows one `notify` command and on this Mac it already belongs to ChatGPT's computer use — replacing it would break that (SPEC-ai-services §5). Stage 6 — Copilot, Gemini and Cursor got their history, forecast and week by day with stage 2's `LimitHistory`; Gemini tokens per project wait for a Mac with Gemini CLI; Copilot and Cursor have no per-project or context data. Two new strings in 13 languages; SPEC-ai-services and REFERENCE updated.
Checked: `xcodebuild test` — 319 / 319 pass (new: recent threads within 3 hours with id / folder / context, `codex resume` command quoting). Live, with Oleh's OK: one `codex exec "Reply with the single word OK"` in a scratch folder created a real thread — `--services limits` printed `note Контекст последней беседы в «codex-check»: 6 %` and `project codex-check: 16132 tokens` (the rollout's `token_count` has `last_token_usage` and `model_context_window: 258400`, as the parser expects), so stage 3 is checked live too; the panel's «Сессии» (expanded for the capture through `collapsedBlocks`, then restored) shows «codex-check · Reply with the single word OK… · 1 мин назад» in the same style as Claude's rows.
Left: clicking the Codex row (Terminal `codex resume`) not tried live; Gemini tokens per project.

## 2026-11-02 — AI services stage 4: per-service alerts, notch, weekly summary (branch `feat/per-service-alerts`)

Done: thresholds per service — `AppSettings.serviceThresholds` (by `ServiceTab`; missing = the common `limitThresholds`, empty = no notifications) and `thresholds(for:)`, used by Claude's alerts and by every other service's; each service page in Settings has «Уведомления о лимитах» (как у всех / на своих порогах / не уведомлять). The notch island has a new ear «Другие AI»: the other service closest to its limit as a ring, its name and percent in the hint (`NotchText.fullestOther`). The weekly Telegram summary ends with «Другие AI», a line per service (limits, growth over the week from `LimitHistory`, top Codex projects; a service with nothing to say is left out). The menu bar («Другие AI» element with a chosen service) and the widget (three other services) already had the choice, nothing to add. The «Лимиты и расход» footnote no longer says the thresholds are Claude's. 9 new strings in 13 languages, one footnote re-keyed with its translations; REFERENCE and SPEC-ai-services updated.
Checked: `xcodebuild test` — 318 / 318 pass (new `PerServiceTests`: common / own / off thresholds and stored values cleaned up, the other-AI ear and its hint, the summary line and section). Live: Settings → Сервисы AI → Codex shows «Уведомления о лимитах» with «как у всех: 50, 80, 95 %» (window captured, dark theme).
Left: the notch ear and the summary line not seen live (the island isn't installed here, the summary goes out on its day).

## 2026-11-02 — AI services stage 3: Codex in full (branch `feat/codex-in-full`)

Done: new `Services/CodexThreads.swift` — plan and credits from the same `account/rateLimits/read` answer as the limits (`rateLimits.planType`, `credits {unlimited, balance}`); tokens per project this week from Codex's own `~/.codex/state_<N>.sqlite` (`threads`: `cwd`, `tokens_used`, `updated_at`, not archived; the newest numbered file; opened read-only through SQLite3); how full the context of today's latest thread is, from the last `token_count` in its rollout (last request's tokens without reasoning over `model_context_window`). `HubLimit` and `ServiceUsage` carry `notes` (`ServiceNote`: text + symbol) and `projects` (`ProjectTokens`); the card shows the notes and a folded «Проекты за неделю». New CLI `AIHubBar --services limits` prints what the panel would show for each tool-based service. Fixed on the way: the first version of that command deadlocked — it read `AppSettings` (main thread) inside the task the main thread was waiting for. 6 new strings in 13 languages; REFERENCE and SPEC-ai-services updated.
Checked: `xcodebuild test` — 315 / 315 pass (new `CodexThreadsTests`: free-plan answer → plan only, balance and unlimited credits, context from a `token_count` line, threads / projects / context from a temporary `.codex` with the real `threads` schema). Live: `--services limits` → `codex: window 30 дн 0 %, note План: Free`, `copilot: чат and дополнения 0 %`; the panel (Codex enabled for the check) shows «План: Free» under Codex's ring; Oleh's settings (all other services off) restored.
Left: tokens per project and context not seen live — no Codex threads on this Mac (Needs Oleh).

## 2026-11-02 — AI services stage 2: one model and one limits card for every service (branch `feat/service-usage`)

Done: new `Models/ServiceUsage.swift` — `ServiceUsage` (rings: the first two windows with a percentage; bars: the rest and spend; forecast; week by day; notes; error; stale) and `LimitWindow`, built by `ServiceUsage.claude(snapshot…)` and `ServiceUsage.hub(limit, history:)`. `LimitHistory` keeps the other services' readings for 8 days in `limit-history.json` (replaces the in-memory first reading, so the forecast survives restarts) and gives them a forecast and a week by day (daily growth of the window that resets last). The panel's «Лимиты» draws Claude and every enabled service with the same `ServiceCard` — rings, forecast, week strip, bars, notes, error (the compact `HubRow`s are gone); service names show once there is more than Claude. Fixed on the way: Codex's 30-day free-plan window was titled «неделя» (now «30 дн»), and a reset more than a week away showed only the weekday (now with the date). No new strings. SPEC-ai-services updated (stage 1 and 2 done, §4 describes the sidebar).
Checked: `xcodebuild test` — 311 / 311 pass (new `ServiceUsageTests`: Claude from a stored answer, Codex and spend as the same card, error-only service, history forecast and week, periods / dedupe / 8-day trim / save-load, short reset with a date beyond a week). Live (dark theme, glass): opened the panel with full-screen control and `screencapture` — Claude card unchanged; with Codex temporarily enabled it shows as a card with a ring «0 % · 30 дн · сброс Ср, 2 дек.»; Oleh's settings (all other services off) restored afterwards.
Left: week strip and forecast for other services appear only after 12 h / 15 min of readings, not seen live; stage 3 next (Codex credits, plan, tokens per project, context).

## 2026-11-02 — Settings like System Settings (branch `feat/settings-sidebar`)

Done: design variant A, chosen by Oleh from three renders. The Settings window is one `NavigationSplitView`: a sidebar with search, the app's pages (Основные, Профили, Модули, Внешний вид, Строка меню) and a «Сервисы AI» group with a page per AI and its status dot; every page has a header — coloured icon tile, title, one-line summary — and the window has one size (900 × 660) instead of 560 / 760 by tab. New `SettingsPane` (`Views/SettingsPane.swift`: titles, summaries, icons, search keywords taken from setting names already shown on the page), `PaneIcon`, `PaneRow`, `PaneHeader`; «Сервисы AI» pages are `ServicePage` (the nested list from #162 is gone). `settingsTab` / `servicesTab` are kept, so links into Settings and the old-tab migration still work. The window's title strip is removed (`toolbar(removing: .title)`, hidden toolbar background) — hiding the whole toolbar also took the close / minimise buttons, tried and reverted. Profiles: fixed height dropped, its list narrowed to 190 pt. 10 new strings in 13 languages.
Checked: `xcodebuild test` — 304 / 304 pass (new `SettingsPaneTests`: page ↔ stored tab round trip, search by title and setting names). Live: every page opened and captured with `screencapture -l` — Основные, Профили (rows fit after widening), Строка меню, Claude Code, Другие; window buttons present, no title strip, one colour per column.
Left: dark theme not looked at; search tried only in tests.

## 2026-11-02 — «Сервисы AI» list without the grey sidebar (branch `fix/services-list-background`)

Done: the new services list (#162) used the sidebar style, whose grey material ran up under the Settings tabs and split the window — the same bug as in «Профили» on 2026-10-30. The list background is hidden the same way (`scrollContentBackground(.hidden)`), so the tab has one window colour and the divider starts below the tabs.
Checked: built and installed; the Settings window captured with `screencapture -l` — one colour, no grey strip. Tests not affected (view modifier only).
Left: nothing.

## 2026-11-02 — «Сервисы AI»: services as a list on the left (branch `feat/services-sidebar`)

Done: the segmented row of six services didn't fit the 560 pt Settings window with Oleh's large text. «Сервисы AI» now has a list on the left, like System Settings: an icon, the name and a dot per service (green — an agent found, an API key saved or its limits available; grey — nothing; status also in the hover hint and for VoiceOver), the chosen service's options on the right. Settings widens to 760 pt on this tab only. New `ServiceTab.icon`, `ServiceTab.isSetUp(agents:keys:limits:)`; two new strings in 13 languages.
Checked: `xcodebuild test` — 302 / 302 pass (new: status from each kind of part, another service's parts don't count, icons distinct). Live: opened Settings → «Сервисы AI» with `--app-command settings` and captured it — list, dots (Claude Code, Codex, Copilot green here) and the Codex options render; the rest of the window unchanged.
Left: dark theme not looked at.

## 2026-11-02 — Glass panel background really applies on macOS 27 (branch `fix/glass-panel`)

Done: «Стекло» from #158 changed nothing — on macOS 27 the `MenuBarExtra` window has no `NSVisualEffectView`; its background is a full-size `CABackdropLayer` SwiftUI draws inside the hosting view (window dumped to the log with the panel open). `containerBackground(.clear, for: .window)` doesn't reach it (tried). Hiding the backdrop's holder layer blanked the panel, because the holder also carries the portal SwiftUI draws the content through. Now `PanelGlass` hides only the full-size `CABackdropLayer` and puts a clear `NSGlassEffectView` (corner radius taken from the backdrop, 16 pt) behind the hosting view; cards stay glass tiles; «Обычный» puts it back. Variants compared live: no glass view (too transparent, text behind is readable through the panel), clear glass (chosen — close to Control Center, which has no panel background, only blur and glass tiles).
Checked: `xcodebuild test` — 301 / 301 pass (new `PanelGlassTests` on a stand-in of the real window: only the full-size backdrop hidden, holder and a card's backdrop untouched, one glass view on reopen, restore; unknown window untouched). Live on Oleh's Mac (light theme): opened the panel through the menu bar with full-screen control and captured it with `screencapture` — «Стекло» shows the blurred desktop and windows through the panel with glass cards, «Обычный» shows the system background and flat cards; log says `Glass panel: hid 1 system backdrop(s), clear glass with corner radius 16.0`.
Left: dark theme and «Уменьшить прозрачность» not looked at live (Needs Oleh).

## 2026-11-02 — AI services: spec and stage 1, Claude Code inside «Сервисы AI» (branch `feat/ai-services-tabs`)

Done: docs/SPEC-ai-services.md — what Claude Code has, a table of what every other service has and can give (checked on this Mac: `claude` 2.1.314, `codex` 0.166.0-alpha.5.1 only inside ChatGPT.app, `~/.codex/state_5.sqlite` `threads` with `cwd` / `tokens_used` / `model`, no Gemini / agy / Copilot / Cursor), the common `ServiceUsage` model, the new Settings and panel, stages 1–6. Stage 1: the «Claude Code» tab is gone from Settings; «Сервисы AI» has a segmented nested tab per AI (`ServiceTab`: Claude Code · Codex · Gemini · Copilot · Cursor · Другие, kept in `servicesTab`). Claude Code's tab holds all of `ClaudeSettings` unchanged plus the Anthropic API key and Anthropic admin costs; Codex — agent, Codex limits, OpenAI API key and costs; Gemini — Gemini CLI, Antigravity, Gemini quota options, Google API; Copilot and Cursor — agent and limits; Другие — xAI, DeepSeek, Mistral, compatible API, OpenRouter, API spend and budget. Each «Другие AI» row (switch, key, consent) moved from Modules → Лимиты to its service's tab; Modules → Лимиты → «Другие AI» now shows a status summary, «Проверить сейчас» and «Открыть «Сервисы AI»». `SettingsRoute.migrate` turns a stored `settingsTab == "claude"` into «Сервисы AI» → Claude Code (called when Settings opens); Readiness' «Открыть «Сервисы AI»» opens the Claude Code tab; the Sessions module text and GUIDE / REFERENCE / README point to Settings → AI Services → Claude Code. Strings in 13 languages (French, Italian, Arabic reuse the existing names of the tab).
Checked: `xcodebuild test` — 298 / 298 pass, incl. new `ServiceTabTests` (each agent / API provider / limit source in exactly one tab, old `claude` value migrated, other values untouched); Release build without warnings. No new icon-only controls (the segmented picker has the label «Сервис»), so the accessibility walk found nothing to add by reading the code; the live `axdump` walk and a look at the window were not possible — the screen was locked during this automated run.
Left: stage 2 not started (left for its own PR, see Next); the window not seen with eyes (Needs Oleh). Branch is from origin/main without #158, so STATUS.md will conflict with it on merge (header lines only).

## 2026-11-02 — Glass panel background (branch `feat/glass-panel`)

Done: Settings → Внешний вид → Панель → «Фон панели: Обычный / Стекло» (`PanelBackground` next to `PanelTheme`, `AppSettings.panelBackground`, key `panelBackground`, reset by «Сбросить внешний вид»; not part of profile looks yet). With «Стекло» on macOS 26+ `PanelGlass` (new `Views/PanelGlass.swift`) finds the window's full-size system material (`NSVisualEffectView` or `NSGlassEffectView`): one behind the content is hidden, one around the content gets only its own layers hidden; the window turns clear (`isOpaque = false`, `.clear`, shadow re-computed) and the panel draws `.glassEffect(.regular)` in the window's corner radius (read from the material's layer, 16 pt otherwise). Cards (`panelCard()`) become glass tiles inside one `GlassEffectContainer`. «Обычный» puts everything back. When nothing recognisable is found, the panel keeps the standard background and the log says `Glass panel: no system background found…`; every change is logged once (`Glass panel: hid …`). «Уменьшить прозрачность» → always standard (with a note under the picker). macOS 14–15: the option is disabled with «Стекло — в macOS 26 и новее» — chose this over a lighter material because the lighter material can't be checked here and would look different from the 26+ glass. New strings in 13 languages.
Checked: `xcodebuild test` — 299 / 299 pass, incl. new `PanelGlassTests` (material behind content hidden and restored, material around content keeps its subviews, unknown window untouched, reduce transparency) and persistence of the setting; Release build has no warnings. The real window hierarchy was NOT seen: the screen was locked during this automated run, so the panel couldn't be opened (synthetic clicks and AXPress on the status item don't open `MenuBarExtra`, see `QuickSearch`); the temporary hierarchy dump was written, built and removed unused.
Left: visual check by Oleh (Needs Oleh) — whether the glass shows, corners and shadow, readability; if the log says no system background was found, the hierarchy needs a look with the window open.

---

Older entries, by month: [docs/status/](status/).
