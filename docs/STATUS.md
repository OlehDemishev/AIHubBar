# Status

<!-- summary:start -->
**Stage:** Mac: 0.4.0 published (Settings around modules, menu bar dividers, beta builds with «Раскладка» in beta). Windows/Linux (`desktop/`, Tauri 2): postponed by Oleh 2026-11-02 after stages 1–3 main parts
**Updated:** 2026-11-03

**Now:**
- nothing in progress; refactoring stage 5 merged (#219, app composition); next — stage 6, services (docs/SPEC-refactor.md §9)

**Next:**
- Oleh tries «Раскладка» in his own apps; next beta with fixes: `scripts/release.sh 0.5.0-beta.1 --publish`
- Mac island: a live VoiceOver walk; why one test drag onto the island didn't land
- Windows/Linux postponed: no work until Oleh brings it back (where it stopped: docs/SPEC-windows.md §9, stage 2–3 leftovers)

**Needs Oleh:**
- say when to start stage 6 (services)
- look at the new help: panel → «?» and https://olehdemishev.github.io/AIHubBar/help.html
- look at the new Settings and say what to change next
- MacBook Air: update to 0.4.0 through Sparkle (Settings → General → Updates) and check the island at the real notch
- «Раскладка» is on and has Accessibility on this Mac: try it in Telegram, Chrome, Safari, Notes; ⌥⇧ on a selection is not tried yet
- the beta channel exists now (release `beta`, points to 0.4.0): say when the next beta goes out
- older, still open: Mac mini Claude CLI sign-in, crash report alert from 16:46, Chinese model keys, ja/ko/ar translations, docs/CHECKLIST.md «Oleh» rows, social preview image, old repo `OlehDemishev/ClaudeBar`
<!-- summary:end -->

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

## 2026-10-31 — Release 0.2.2 (branch `chore/status-release-022`)

Done: merged #154 (clickable widgets) and #155 (Codex from ChatGPT.app). For #155, main went into its branch with the STATUS.md / DECISIONS.md conflicts resolved, keeping both sides. Then `scripts/release.sh 0.2.2 --publish` from main `1f2ea28` (build 345), published as v0.2.2 «Latest» with the `.dmg`, the appcast and the overview PDFs. The release notes list #154, #155 and #153.
Checked: `xcodebuild test` on merged main — 295 / 295 pass; deep strict verify passed, authority «ClaudePult Release», no get-task-allow; Info.plist has the `aihubbar` URL scheme; the release binary's `--services` finds `codex` in `/Applications/ChatGPT.app/…/codex-cli/bin/codex` (codex-cli 0.166.0-alpha.5.1); `releases/latest/download/appcast.xml` serves 0.2.2 / 345; the `.dmg` URL answers 200.
Left: widgets not clicked on the desktop and the update not installed through Sparkle yet (Needs Oleh).

## 2026-10-31 — Codex from the ChatGPT desktop app (branch `fix/codex-in-chatgpt-app`)

Done: `AgentLocator.detect("codex")` falls back, last, to the `codex` the ChatGPT desktop app ships (`ChatGPT.app/Contents/Resources/codex-cli/bin/codex`): every copy Launch Services knows by bundle id (`com.openai.codex` — the real id of ChatGPT 26.1027 —, `com.openai.chat`), then `/Applications` and `~/Applications`. So with only ChatGPT.app installed, Codex shows under «Другие AI» with its limits, in Settings → Сервисы, «Открыть в…», commands and «Сравнить». Decision and the per-caller review in DECISIONS.md. No new strings.
Checked: xcodegen + `xcodebuild test` — 294 tests pass (new: the app's copy only for `codex`, found wherever Launch Services has it with each place once, after the shell and version managers; the real free-plan `rateLimits` answer). Live: the bundled `codex app-server` (codex-cli 0.166.0-alpha.5.1) answers `account/rateLimits/read` with Oleh's ChatGPT sign-in; installed with `scripts/build-and-install.sh`, `AIHubBar --services` with a bare PATH prints `agent codex: /Applications/ChatGPT.app/…/codex — codex-cli 0.166.0-alpha.5.1`, and the running app wrote `other-ai.json` with `Codex 0%`. The Settings window itself was not looked at (computer use can't reach the menu bar app). CI not set up; checks run locally.
Left: docs/REFERENCE.md names the test scheme «AI Hub Bar», the real one is `ClaudePult`.

## 2026-10-31 — Clickable desktop widgets (branch `feat/interactive-widgets`)

Done: URL scheme `aihubbar://` (project.yml), handled in `AppDelegate` (`WidgetLink`): `limits` opens a new «Лимиты — AI Hub Bar» window with the panel's limits block (the panel can't be opened from code), `session/<id>` shows that session like a notification click (an ended one → search), `search` opens the search. Limits widget: a click anywhere opens limits (`widgetURL`), ↻ (`RefreshLimitsIntent`) asks the app to fetch now without opening it. Sessions widget: small → the one waiting session or the search; medium → a link per row (waiting → first waiting session, each project name → its session, working / red projects → search); ☕ (`SetKeepAwakeIntent`, now macOS 14+, only with «Не спать» installed) switches the manual hold without opening the app. `widget-status.json` gains `waitingSessions` (id + project). Every window scene now has `.handlesExternalEvents(matching: [])` — SwiftUI opened the search window along with each link. 4 new strings in 12 languages, hover hints and accessibility labels on ↻ and ☕. DECISIONS and REFERENCE updated.
Checked: `xcodebuild test` — 291 tests (new: link parsing, `waitingSessions` file shape, the refresh request over Darwin notifications). Installed with `build-and-install.sh` on the Mac mini: `open aihubbar://limits` opened only the «Лимиты» window (420 pt, real 38 % / 98 % and Copilot rows, screenshot), `aihubbar://search` the search, an unknown session id the search, this session's id opened it in Claude (log «Show session: Claude app link …»); the Darwin requests the buttons send refreshed `usage.json` (updated 18:41:07Z → 18:41:47Z) and switched the manual keep-awake hold on and off (restored). Widget bundle carries both intents in `Metadata.appintents`. CI not set up.
Left: the widgets themselves not clicked on the desktop (WidgetKit UI can't be driven from here) — Needs Oleh; whether macOS shows `.help` tooltips inside desktop widgets is unknown (VoiceOver labels are set either way); with the app not running ↻ and ☕ do nothing.

## 2026-10-31 — Plan: Claude as one of the AI services (branch `chore/status-unified-ai`)

Done: recorded in Next that Claude moves into the AI section with the same view for every service. Codex can match Claude's metrics: `codex` returns 5 h and week windows, credits, the plan type, per-limit buckets and token counts, and its session logs add the project folder and context size. Chats on chatgpt.com expose no limits. The full Codex metrics wait for this change.
Checked: Codex fields against the openai/codex source (`protocol.rs`, `app-server-protocol/v2/account.rs`, `backend-client`); no code changed, so no build.
Left: the work itself, when Oleh says.

## 2026-10-31 — Notch island, stage 2: events and permission requests (branch `feat/notch-events`)

Done: banners in the island (SPEC-notch §3.2): every notification that gets through its frequency check also goes to the island (`Notifier.island`), one banner at a time by importance (request, waiting, done, background, limits, context, PR/CI, then calendar, resources, commands), 6 s for a wait and 4 s for the rest, counted from when it is shown and paused while the pointer is on it; a click leads where the notification would. New island-only banner «Готово: <project> · <time>» when a session goes from working to done. Permission requests follow the open request files: project · tool, the command in mono, «Разрешить» / «Отклонить» (alive only 0.6 s after appearing and after the pointer moved — `NotchClickGuard`), «Открыть»; they stay until answered anywhere and also show at the top of the open card. Settings → Модули → «Остров у чёлки»: which events, and «Запросы и ожидание — только в острове» (off by default; only while the island is on screen). The window takes clicks only over its black part. Clicks on a banner share the notification handler. 8 new strings in 12 languages.
Checked: `xcodebuild test` — 289 tests (new: queue order, time starts when shown, pointer pause, requests stay until answered, same id replaces, dropping, kinds, the click guard, settings decode). Live on the Mac mini with `notchSimulate` and a test session + request file (marked TEST): the request banner appeared with the buttons off until the pointer moved; Oleh clicked «Разрешить» (decision file written, log «Permission allowed from the notch island») and «Открыть» (session shown); the request went when the session stopped waiting; «Готово: TEST-notch · 13 мин» appeared on done and stayed while the pointer was on it. Fixed from that: grey prominent buttons in a non-key window (own style), a grey «done» icon, answered requests flashing back. Test files, `notchSimulate` and the module removed afterwards; one test system notification «Claude просит разрешение — TEST-notch» was posted. CI not set up.
Left: not seen on a real notch (the Air); «только в острове» not tried live; stage 3 — pill, full screen, hot keys, first-setup window.

## 2026-10-31 — Release 0.2.1 (branch `chore/status-release-021`)

Done: `scripts/release.sh 0.2.1` from main `c0f8f47` (build 331), published as v0.2.1 «Latest» with the `.dmg`, appcast and the overview PDFs; notes list the wider CLI search (#150, #151), the optional notch island (#149) and #140.
Checked: deep strict verify passed, authority «ClaudePult Release», no get-task-allow; the release binary's `--claude next … --print` names `/opt/homebrew/bin/claude`; `releases/latest/download/appcast.xml` serves 0.2.1 / 331 (after a minute of caching); the `.dmg` URL answers 200.
Left: not opened on another Mac yet (Needs Oleh).

## 2026-10-31 — Wide search for every agent CLI (branch `feat/agent-autodetect`)

Done: the search from #150 moved into `AgentLocator` (`Services/AgentLocator.swift`) and now serves every `AgentKind`: Homebrew, `~/.local/bin`, npm-global, pnpm (`~/Library/pnpm`), yarn, bun, volta, cargo, asdf and mise shims, then one `command -v claude codex gemini agy copilot cursor-agent` in the interactive login shell at app start (the exit code is ignored: it is 1 when any name is missing), then nvm and fnm, then for `claude` only the desktop app's copy. `ClaudeLocator` keeps `resolve(configured:)` and asks `AgentLocator`. No app-bundle paths for Codex or Antigravity: none could be confirmed, so none are guessed.
Checked: `xcodebuild test` — 282 tests pass (locator tests moved to `AgentLocatorTests`, new: other agents in nvm/fnm/volta/pnpm, the desktop copy only for `claude`, several paths from one shell answer). By hand: the combined `command -v` in zsh prints `/opt/homebrew/bin/claude` and exits 1 here (no other agents installed on this Mac). CI not set up; checks run locally.
Left: not seen with a real nvm/volta install of another agent; only the fake-home tests cover it.

## 2026-10-31 — Wider `claude` auto-detection (branch `fix/claude-autodetect`)

Done: `ClaudeLocator` looked in four fixed folders only, so a Mac with `claude` under nvm/fnm/volta, or with only the Claude desktop app, showed «авто: не найден». Now it checks Homebrew, `~/.local/bin`, npm-global, bun, volta, asdf and mise shims, then `command -v claude` from the user's interactive login shell (asked once at app start, before the AI scan), then nvm and fnm (newest Node first), then the desktop app's own copy (`~/Library/Application Support/Claude/claude-code/<version>/<hash>/claude.app`, newest version, found again each time). REFERENCE.md lists the places.
Checked: `xcodebuild test` — 281 tests pass after merging main with the notch island (new: nothing installed, newest nvm version, desktop app copy, the order of places, shell output with a greeting or an alias, the real shell lookup). On this Mac the login shell answers `/opt/homebrew/bin/claude` in 0.04 s; the desktop app copy runs (`2.1.309 (Claude Code)`). Not checked on the other Mac. CI not set up; checks run locally.
Left: the desktop app copy may ask for `/login` on its first run in Terminal; the command-line mode (`--claude`) does not ask the shell (Terminal's own PATH covers it).

## 2026-10-31 — Notch island, stage 1 (branch `feat/notch-island`)

Done: optional module «Остров у чёлки» (`ModuleKind.notch`): finds the notch from `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (`NotchGeometry`, re-read on screen changes), a borderless non-activating panel over it on every desktop; at rest two ears (left: session-limit ring, right: sessions dot with count — both selectable: session/week limit, sessions, background runs, nothing) and clicks pass through to the menu bar; hover 0.3 s or a click opens a black card: session and week rings, forecast, up to four sessions with what each is doing (click opens the session), «Ещё N — в панели ✦», «Поиск и запуск…»; leaving for 0.4 s, a click outside or Esc closes it. Reduce Motion and Increase Contrast respected, hints and VoiceOver labels on the ears. Settings → Модули: install/remove, ears, hover on/off; the assistant offers it on a Mac with a notch and the developer template ticks it. Not a panel block (DECISIONS). 16 new strings in all 12 languages. Hidden `notchSimulate` default for testing on a Mac without a notch. Release target 0.3.0 written into the spec.
Checked: `xcodebuild test` — 275 tests (new: notch rectangle from screen areas, no notch, window centred and kept on screen, assistant only with a notch, install leaves the panel alone, settings decode). Installed with `build-and-install.sh` and checked live on the Mac mini with `notchSimulate`: ears shown at rest, hover opened the card with real limits (28 % / 96 %) and sessions, moving away closed it. Found and fixed a launch crash (`NSApp` read in `App.init`). Afterwards `notchSimulate` removed and the module uninstalled again (state file restored). CI not set up.
Left: not seen on a real notch (needs the Air); clicks through the island at rest to the menu bar not tried by hand; the `axdump` accessibility walk not run; events, requests, pill, full screen, hot keys and the first-setup window are stages 2–3.

## 2026-10-31 — Landing page live (branch `chore/pages-after-merge`)

Done: Oleh turned on Pages (Source: GitHub Actions); #147 merged and the first deploy published https://olehdemishev.github.io/AIHubBar/. Pages actions moved to their current majors (checkout v7, configure-pages v6, upload-pages-artifact v5, deploy-pages v5) to drop the Node 20 warning. README links the website.
Checked: first deploy run green, the site answers 200 and looks like the local preview in the browser pane; workflow YAML parses. The new action versions run on the deploy after this merge.
Left: About → Website is Oleh's click (optional).

## 2026-10-31 — Landing page on GitHub Pages (branch `feat/landing-site`)

Done: `.github/workflows/pages.yml` publishes `site/` with the official Pages actions on a push to main that touches `site/` (or by hand). `og:image` is an absolute URL so link previews work.
Checked: workflow YAML parses; page re-checked in the browser pane. Pages is not turned on for the repo yet (API 404), so the first deploy waits for Oleh's switch.
Left: Oleh turns on Pages (Source: GitHub Actions) and runs the workflow once; then the site address can go into the repo's About and the README.

## 2026-10-31 — Landing page: Mono colours (branch `feat/landing-site`)

Done: Oleh picked Mono. The other palettes and the temporary switcher are gone; the accent is near-black on white and light grey on dark, links Apple blue, so the orange app icon is the only colour.
Checked: browser pane, light and dark: no switcher left, buttons and steps follow the mono accent, `#install` link scrolls.
Left: the GitHub Pages workflow and a PR, on Oleh's go.

## 2026-10-31 — Landing page: neutral colours and palette choice (branch `feat/landing-site`)

Done: the draft no longer uses the overview's terracotta (too close to Claude's own colours). Neutral Apple-like base (white / near-black, system greys and status colours) and four accent palettes as tokens: Mono, Blue, Indigo, Teal, light and dark each. A temporary switcher (bottom right, `?palette=`) to choose; it goes once Oleh picks.
Checked: in the browser pane, every palette in light mode, Mono and Blue in dark: buttons, links, glow, icons and step numbers follow the palette, text on buttons readable; `#section` links still scroll.
Left: pick a palette, remove the switcher, then the Pages workflow.

## 2026-10-31 — Landing page draft for GitHub Pages (branch `feat/landing-site`)

Done: `site/index.html` + `style.css`: one page with the hero and a live HTML mock-up of the panel (same colours as `docs/overview`), features, templates, more, install steps, privacy, download buttons to `releases/latest`; icon, favicon and social preview copied in. Light and dark, works from 375 px up. `.claude/launch.json` serves it locally on port 8765.
Checked: in the browser pane at desktop width and 375 px, dark and light: no horizontal scroll, sections and links render. Text taken from README only.
Left: not published. To go live: a Pages workflow (`actions/deploy-pages` from `site/`) and Settings → Pages → Source: GitHub Actions; free for a public repo.

## 2026-10-31 — Notch island: Oleh's answers (branch `docs/notch-spec-answers`)

Done: `docs/SPEC-notch.md` updated with Oleh's answers: the name stays «Остров у чёлки»; live notch checks on his MacBook Air M2; island instead of notifications, the pill on screens without a notch and hot keys are asked of the user when the module is installed — new §6.1 «Первая настройка» (one window, three questions, preselected answers; a hidden island never swallows a notification). Hot keys ⌃⌥Y / ⌃⌥N act only on a request visible in the island (§4). Stage 3 includes them.
Checked: this Mac (Mac16,10, LG UltraWide) has no notch — `NSScreen.safeAreaInsets.top = 0` from a small Swift script, so the pill can be checked here, the notch only on the Air. Docs only, no build needed. CI not set up.
Left: no code; the «proposed» points in §10 are still open.

## 2026-10-31 — Notch island spec (branch `docs/notch-island-spec`)

Done: `docs/SPEC-notch.md` — an optional module «Остров у чёлки»: a black island around the MacBook notch with two small side indicators at rest (session limit, sessions state), short event banners (permission requests with Allow / Deny, waiting, done, limits, context, PR/CI) and a hover card (limits, sessions with the current action, open requests). How it works without private APIs (`NSScreen.safeAreaInsets`, `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, a non-activating `NSPanel` above the menu bar), guard against accidental clicks on Allow, screens without a notch and full-screen apps, settings, accessibility, what not to do (no code from boring.notch, GPL-3.0), three stages and open questions.
Checked: facts against the code (`ApprovalFiles`, `NotificationKind`, `Session.actionText`, `MenuBarIcon.wideWidth`, `ModuleKind`); boring.notch licence via the GitHub API. Docs only, no build needed. CI not set up.
Left: no code; the answers in §10 come first, and live checks need a MacBook with a notch.

## 2026-10-31 — RELEASE.md: real `.dmg` name (branch `fix/release-doc-dmg-name`)

Done: docs/RELEASE.md «First launch» named `ClaudePult-<version>.dmg` and said “Applications” (Applications); now `AIHubBar-<version>.dmg` and Applications, as `scripts/release.sh`, README and GUIDE. The `--publish` line lists what is uploaded: `.dmg`, `appcast.xml` and the overview PDFs. The STATUS header had its end marker twice; one is left.
Checked: `grep` over README and docs — no other `ClaudePult-*.dmg`; names match `scripts/release.sh` (`DMG`, the PDF loop) and the v0.2.0 assets. Docs only, no build needed.
Left: nothing.

## 2026-10-31 — English interface names in the public docs (branch `docs/english-ui-names`)

Done: Russian interface names in `docs/REFERENCE.md` and `docs/RELEASE.md` («Настройки…», «Основные», «Модули», «Не спать», notification texts …) replaced by the app's own English strings, looked up in `Localizable.xcstrings` (most automatically, the rest by hand from the code: card `project.md` and its fields, `content-plan.md` columns, `{project}`/`<time>` placeholders); « » quotes became “ ”. README links to the Russian PDF in English. The v0.2.0 release notes on GitHub are now English. Left on purpose: language names, the Cyrillic keyboard-layout example and the per-language file names. GUIDE and the English PDF had no Russian already.
Checked: no Cyrillic left in README / GUIDE / RELEASE / REFERENCE apart from those examples; every lookup reviewed in the diff.
Left: internal docs (SPEC*, DECISIONS, CHECKLIST, STATUS history, TEMPLATES) stay as they are — Russian specs and records of checks in the Russian interface.

## 2026-10-31 — Overview PDF and GitHub presentation (branch `docs/overview-pdf-and-repo`)

Done: 8-page overview for everyone, `docs/AI-Hub-Bar-Overview-en.pdf` and `-ru.pdf`, made from `docs/overview/overview.<lang>.html` + `style.css` by `scripts/make-overview-pdf.sh` (headless Chrome); the interface is drawn as HTML mockups with made-up projects, not screenshots of Oleh's Mac. The same script renders `docs/images/hero.png` (README header) and `social-preview.png` (1280×640). New user-facing README (features, install, privacy, build, docs); the old developer README moved to `docs/REFERENCE.md` with links fixed. GUIDE: `.dmg` name (`AIHubBar-<version>.dmg`) and the uninstall step fixed. `release.sh --publish` attaches the PDFs and has English release notes. `.github/ISSUE_TEMPLATE` (bug, feature). On GitHub: description, 17 topics, Projects tab off. All links use `OlehDemishev/AIHubBar` (merged with the release work on main).
Checked: both PDFs rendered and every page looked at as an image (nothing cut off, 8 pages each); facts checked against README/GUIDE and code (universal binary, Notes as .md, Finish prompt); `bash -n` on both scripts; xcodegen + build with the new SUFeedURL. CI not set up.
Left: social preview has to be uploaded by hand; the PDFs are not on the 0.2.0 release yet (the next `release.sh --publish` attaches them); PDFs need a new render when features change (`scripts/make-overview-pdf.sh`).

## 2026-10-31 — No personal paths or names; Telegram set up in the app (branch `feat/user-paths`)

Done: the workspace prompts (formerly «Oleh's» style) no longer say «Задача от Олега» or `~/Projects/CLAUDE.md`: the rules file is `<projects folder of the profile>/CLAUDE.md`, a question goes to «the Needs field of the STATUS.md header». Panel and help say «Нужно от вас». The background rules deny `**/_daily-report/config.json` instead of Oleh's path. Settings → Основные → «Telegram»: bot token (Keychain), chat ID with «Определить» (from the bot's latest message) and «Проверить»; every Telegram message (run results, limits, weekly summary, calendar, run guard) uses this bot first and `_daily-report/config.json` only as a fallback; hints point there instead of `_daily-report`. Folders were already chosen per profile and in the first-run assistant.
Checked: `xcodebuild test` — 268 tests (new: no name or `~/Projects` in prompts, chat from updates, own bot before the file); installed: the Telegram section and «Нужно от вас» are in place.
Left: Oleh's setup keeps working through `_daily-report/config.json` (nothing to do); the approvals bot still needs its own token.

## 2026-10-31 — Release 0.2.0, public repo `OlehDemishev/AIHubBar` (branch `chore/go-public`)

Done: STATUS header trimmed of Mac-specific personal notes; SUFeedURL, release script and docs point at `OlehDemishev/AIHubBar`; repo renamed (GitHub redirects the old URL) and made public on Oleh's go; `scripts/release.sh 0.2.0 --publish` from a clean main published v0.2.0 with `AIHubBar-0.2.0.dmg` and `appcast.xml`.
Checked: secret scan of all 285 commits (keys, tokens, private keys, sensitive file names) found nothing; anonymous download of the appcast (200) and the DMG (200, 9.8 MB); the app inside is version 0.2.0, signed «ClaudePult Release», feed URL on AIHubBar.
Left: git history still has the older notes and both author emails (rewriting history was not done); first launch on another Mac needs «Open Anyway» (no Developer ID).

## 2026-10-31 — Live checks; week-forecast notification repeating 164 times (branch `fix/week-forecast-repeat`)

Done: «Недельный лимит кончится раньше сброса» came every ~2 minutes (164 today): the API sends the same week reset with a different fraction of a second each fetch, and the «once per week» check compared exact times. Reset times are now compared rounded to 10 minutes everywhere (week forecast, threshold alerts, «limit restored», the panel). «Контекст почти заполнен» no longer repeats after a restart. In the ⌃⌥C search the project step of a saved prompt lost keyboard focus (typing and Esc went nowhere): fixed.
Checked: `xcodebuild test` — 266 tests (new: jittery reset is the same window). Live: MCP switch off/on on `obsidian` — removed from settings.json, backup written, 0600 stash, back on: content identical to the original; «Позже → После сброса лимита» queued MeisterHub for 19:42 UTC, then cancelled (nothing ran); weekly summary «Отправить сейчас» sent (`Weekly summary sent: true`); saved prompt → project picker → typing filters, Esc steps back; session changes popover lists files. After the fix the week forecast updated with no notification.
Left: the run guard's SIGSTOP pause was not triggered live (needs 95 %).

## 2026-10-31 — Notifications: once per wait, and a choice per kind (branch `fix/notification-settings`)

Done: «Claude ждёт ответа / просит разрешение» repeated for one wait: every rewrite of the waiting session's file (PermissionRequest, then Claude's own «needs your permission» Notification, then idle reminders) made a new key from `updatedAt`. Now one notification per wait, per session. Settings → Основные → «Какие уведомления и как часто»: eight kinds (waiting, context, background, limits, PR/CI, calendar, resources, commands), each «каждый раз / не чаще раза в 15 мин / в час / в день / не присылать»; the limit counts per event (same id), kept across restarts. Mac resources default to once an hour (memory pressure flapping critical ↔ normal repeated it). Other-AI threshold alerts no longer repeat after a relaunch. Every notification shown or skipped is now logged.
Checked: `xcodebuild test` — 265 tests pass (kinds from ids, throttle, persisted choices); installed, the new section is in Settings → Основные.
Left: which notification was repeating on Oleh's Mac couldn't be read back (macOS keeps the history out of reach and the app didn't log posts before); the log now says, so a repeat can be pinned down if one still comes.

## 2026-10-30 — Eight features: queue after reset, run guard, other-AI extras, session changes, weekly summary, MCP, CLAUDE.md, prompts (branches `feat/limit-queue`, `feat/hub-extras`, `feat/session-changes`, `feat/claude-code-tools`)

Done: (1) «Позже» → «После сброса лимита» queues the next step or a custom task for the session reset, waiting again if the limit is still full. (2) Run guard: at a set session or week usage (95 % by default) running background runs get SIGSTOP and resume after the reset (paused time doesn't count toward the time limit), queued ones wait; notification and Telegram both ways; «Продолжить сейчас» on a paused run. (8) Other AI: menu bar element (fullest or chosen service), a line in the medium limits widget (`other-ai.json`), «кончится … при таком темпе» forecast, threshold alerts also to Telegram. (3) Session rows show files and +/− lines changed since the session started (git, committed included), with a popover list of files. (4) Weekly summary to Telegram (Sunday 19:00 by default): week %, spend by project, three heaviest sessions, limit hits (now recorded), background runs; «Отправить сейчас». (5, 6) «Claude Code» window (panel footer icon, Settings → Claude Code): all CLAUDE.md / AGENTS.md / CLAUDE.local.md with search and editing; MCP servers from ~/.claude.json, ~/.claude/settings.json, project configs and .mcp.json, with an on/off switch (user/local via `claude mcp remove` / `add-json`, settings.json via a 0600 stash file plus backup, .mcp.json via `disabledMcpjsonServers` in the project's settings.local.json); env and headers are never shown. (7) Saved prompts (Settings → Claude Code) offered in the ⌃⌥C search; a project is picked next; {проект}/{project}, {ветка}/{branch}, {файл}/{file} (Finder selection) are filled in. 77 new strings in 12 languages; guide updated.
Checked: `xcodebuild test` — 262 tests pass (new: guard and pause math, forecast, menu bar element, numstat parsing and a real git repo, weekly send time and text, MCP config parsing and project switch, instruction search, prompt placeholders). Installed and checked live: the Claude Code window lists this Mac's CLAUDE.md files and the `obsidian` MCP server; session rows show changes; «Позже» menu is in the project actions.
Left: MCP switching, the run guard's SIGSTOP pause, after-reset launch, the weekly Telegram send and {файл} from Finder were not exercised live (they change your config, need a full limit or send a message); translations are in the last branch only, so merge the four together; long-lived sessions show everything changed since they started, which can be large.

## 2026-10-30 — Limits of other AI services (branch `feat/hub-limits`)

Done: `HubLimits.swift` — model, tolerant parsers and readers for Codex (`codex app-server` `account/rateLimits/read`, fallback to the newest `~/.codex/sessions` log), OpenRouter (`/api/v1/key`), Copilot (`gh api /copilot_internal/user`), Gemini CLI (Code Assist quota with consent, otherwise today's requests from `~/.gemini/tmp` against the plan's daily limit), OpenAI and Anthropic API spend this month (admin keys), Cursor (`GetCurrentPeriodUsage`, consent only). `HubLimitsStore` refreshes every 5 minutes while the limits module is installed, reads sources in parallel, alerts on the Claude thresholds once per window. A source turns on by itself when its tool is found or its key is saved; each can be switched off. Panel: a compact row per service under Claude's rings. Settings → Модули → Лимиты → «Другие AI»: status, requirement, key field (Keychain accounts `hub-openrouter`, `hub-openai-admin`, `hub-anthropic-admin`), Gemini consent and plan, Cursor consent, «Проверить сейчас». 48 new strings in 12 languages. Guide updated.
Checked: `xcodebuild test` — 247 tests pass (10 new on sample answers, including Copilot's real free-plan shape); installed and checked live: the panel shows «GitHub Copilot — чат, дополнения, осталось 200 из 200, сброс послезавтра» from this Mac's `gh`.
Left: Codex, Gemini, Cursor, OpenRouter, OpenAI and Anthropic costs not checked live (no tools or keys here); Anthropic cost amounts are assumed to be cents; no menu bar items, widget line, forecast or Telegram for these services yet.

## 2026-10-30 — Spec for other AI services' limits, postponed (branch `docs/spec-hub`)

Done: researched what Codex, OpenRouter, Copilot, Gemini CLI, the OpenAI / Anthropic admin APIs and Cursor expose about limits and spend (local files, the tools themselves, endpoints, reliability) and wrote `docs/SPEC-hub.md`: one shared «Лимиты AI» module, two waves. Oleh uses only Claude, so nothing is built now.
Checked: none of those tools or API keys are on this Mac, so formats are from third-party docs (listed in the spec) and must be rechecked before building.
Left: building it, when the app is shared.

## 2026-10-30 — Module options per profile (branch `feat/profile-module-options`)

Done: `ProfileModule` carries optional per-profile choices — metrics for «Ресурсы Mac» (`ResourceMetric`), command ids for «Быстрые команды», toggles for «Быстрые переключатели», `showTimers` for «Не спать» — nil meaning everything, so older profiles and files are unchanged. The panel blocks follow the current profile; Settings → «Профили» → «Панель» has a checkmark menu next to each module («Показатели: все» / «2 из 7»). 13 languages.
Checked: 237 tests green; live: CPU and memory only in the panel, «Показатели: 2 из 7» in Settings; profile restored.
Left: —

## 2026-10-30 — Answers from Telegram checked end to end

Done: Oleh updated the hooks (PermissionRequest timeout 300 s) and made a second bot for answers; its token is in the Keychain, the switch is on, the chat is the `_daily-report` one.
Checked: a test Claude (haiku, default mode, isolated settings) asked to `touch` a file; the bot sent the request with buttons, Oleh pressed «Разрешить» on the phone, the log says «Permission allowed from Telegram» and the file appeared.
Left: —

## 2026-10-30 — Opening sessions from their rows (branch `fix/session-open`)

Done: Oleh said clicking a session's name still didn't open it. Checked live: a click on the Survikon row's name does open that session in the Claude app (the app's own record shows the focus at the click). What didn't: a `claude` started in the Claude app's own terminal (entrypoint `cli`, terminal `claude-desktop`) opened its folder in Finder, which looks like nothing happened — it now brings Claude forward. The log now says which way a session was opened («Show session …»), so a row that still doesn't open can be traced.
Checked: tests green; live click on Survikon.
Left: if a row still doesn't open, the log line names the reason.

## 2026-10-30 — Widgets in 13 languages (branch `feat/widget-languages`)

Done: the widget extension was Russian-only. It now has its own `Localizable.xcstrings` (23 strings; 7 reuse the app's translations) and `CFBundleLocalizations`; the reset texts and row titles became localizable. Widgets follow the system language — the app's «Язык интерфейса» override doesn't reach extensions.
Checked: 234 + 12 tests green (a per-language check of the built widget tables).
Left: —

## 2026-10-30 — Session rows open on a click anywhere (branch `fix/session-row-click`)

Done: Oleh asked for the whole session row to open the session, not only the icon that appears on hover. The row now has a full-width hit area: a session comes to the front (its Terminal tab, the Claude app session or the folder), a background run opens its log; the hover icons and the approval buttons keep working. The hint says «Клик — открыть». 13 languages.
Checked: 234 tests green; live: clicking a fake session's task text opened its folder.
Left: —

## 2026-10-30 — Renamed to AI Hub Bar (branch `feat/rename-ai-hub-bar`, on top of `feat/context-warning`)

Done: the app is «AI Hub Bar»: `AI Hub Bar.app` (executable `AIHubBar`), every visible string in code and the 13 translations (34 catalog keys moved with their translations), widget and Shortcuts names, the install and release scripts (`AIHubBar-<version>.dmg`), README / GUIDE / RELEASE. Internal names stay (DECISIONS): bundle id, module, data and log folders, Keychain service, signing certificate, notes folder, repository.
Checked: 234 tests green; installed as `~/Applications/AI Hub Bar.app`, the old `ClaudePult.app` moved to the Trash, profile and installed modules carried over, login item still enabled, menu bar tooltip and panel header say «AI Hub Bar», no «ClaudePult» left in the panel's text.
Left: repository rename (Oleh); hooks still «нужно обновить» from the approvals change.

## 2026-10-30 — Context fullness in session rows (branch `feat/context-warning`, on top of `feat/night-queue`)

Done: `ContextUsage` reads the tail of a session's journal for the last main-thread assistant usage (input + cache writes + cache reads) and divides by the window (200k; 1M for «[1m]» or once past 200k). Session rows show «контекст N %» from 70 % (red from 90 %); one notification per session at 90 %. Hooks give no context size, so no hook update is needed. 13 languages; a hint was rephrased so «100 %» isn't followed by a letter (it read as a format specifier).
Checked: 234 tests green; live: 85 % and 79 % on two real sessions.
Left: the 90 % notification by eye.

## 2026-10-30 — Night queue (branch `feat/night-queue`, on top of `feat/widget-controls`)

Done: «На ночь» queues a background run (next step or a custom task) for the night start hour (`nightStartHour`, Settings → Claude Code, 01:00) through the existing queue (`queue.json`, now with a `night` flag that old files decode without). When night items start, the batch start is remembered; once no background run is left, one summary: notification «Ночью: N задач — ✅, ❌» with a line per run, Telegram if «Итог в Telegram». The «пока работает Claude» keep-awake rule already covers the runs. 13 languages.
Checked: 232 tests green; the buttons seen live (not pressed).
Left: a real night by Oleh.

## 2026-10-30 — Widget «Сессии и проекты» and a Control Center toggle (branch `feat/widget-controls`)

Done: `WidgetStatusWriter` keeps `widget-status.json` (waiting projects, running count, red projects, keep-awake state) and reloads the widget and the control when it changes. New widget «Сессии и проекты» (small/medium). A macOS 26 `ControlWidgetToggle` «Не спать (ClaudePult)»: its `SetValueIntent` runs in the sandboxed extension and posts a Darwin notification that the app turns into the manual hold on/off.
Checked: 230 tests green (incl. the Darwin round trip); live: the file, the registered extension, a request reaching the app.
Left: widget gallery and Control Center by hand; widget texts stay Russian like the existing usage widget (the extension has no string catalog yet).

## 2026-10-30 — Search, hot key and Shortcuts actions (branch `feat/hotkey-search-shortcuts`)

Done: a search field in the panel (sessions, projects, quick commands, report commands; ↵ the first match, a project expands); the global hot key ⌃⌥C (Carbon, configurable in Основные) opens the same search as a small window — `MenuBarExtra` can't be opened from code (DECISIONS); queries typed on the wrong keyboard layout match; App Intents «Лимиты Claude», «Быстрая команда ClaudePult», «Поиск ClaudePult» with App Shortcuts phrases. 13 languages.
Checked: 228 tests green; live: ⌃⌥C → window, «завис» / «ыгкм» → Survikon, Esc Esc closes; intents in the bundle metadata.
Left: Shortcuts/Siri runs and the in-panel field by hand.

## 2026-10-30 — PR and CI alerts (branch `feat/pr-ci-alerts`)

Done: `PullRequestAlerts` compares the open PRs of two project reports: CI turned red, turned green again, PR no longer open (null PR data is not «closed»; the first report after launch is only a baseline). Each change is a notification whose click opens the PR (new https-only `NotificationTarget.link`), optionally also a Telegram message through the `_daily-report` bot (send-only). Settings → «Модули» → «Проекты»: on by default, Telegram off. 13 languages.
Checked: 223 tests green; the settings section seen live.
Left: a real red CI to see the banner.

## 2026-10-30 — Answer permission requests from Telegram (branch `feat/telegram-approvals`)

Done: open permission requests (`ApprovalFiles`) are sent by a bot of ClaudePult's own as a message with «✅ Разрешить» / «❌ Отклонить»; ClaudePult long-polls that bot's `getUpdates` only while a message waits, accepts presses only from the configured chat (default: the `_daily-report` chat), writes the decision, answers the press and removes the buttons (also when the request was answered elsewhere). Settings → Claude Code → «Ответы из Telegram»: switch (off by default), token (Keychain, via the generalised `APIKeyStore`), chat id, «Проверить» (getMe + test message). A separate bot because the `_daily-report` bot already reads its updates — two readers would steal each other's, and bot.py is not ClaudePult's to change. 13 languages.
Checked: 220 tests green; the Settings section seen live.
Left: a real bot from Oleh to try it end to end.

## 2026-10-30 — Week forecast and daily bars (branch `feat/week-forecast`)

Done: `WeekUsage` splits the plan's week percentage over the calendar days of the week window by the journals' weights and forecasts from the last 24 hours. The limits card shows «неделя кончится … при таком темпе» / «неделе до сброса хватит» and a strip of day bars (today highlighted, hover for the share); recomputed when the limits or the journals update; one notification per week window when it runs out before the reset. 13 languages.
Checked: 217 tests green; live: «неделя кончится Сб 04:56 при таком темпе» at 84 % on Friday evening, with the bars.
Left: an estimate (claude.ai chats aren't in the journals); the notification banner by eye.

## 2026-10-30 — What Claude is doing now (branch `feat/current-action`)

Done: the hook records the last tool call on PostToolUse (`last_tool`, `last_target` — a file's base name, a command's first 80 characters, a search pattern…, `last_tool_at`), writing when it changes and otherwise once a minute, clearing it on Stop. A working session's row shows it in words («правит …», «запускает …», «ищет …», «смотрит в сети», «работает с агентом», «обновляет план»); the task moves to the hover hint. No tool call for 10 minutes → an orange «тихо N мин» instead of the duration. 13 languages.
Checked: 215 tests green (real hook runs); live: this session's row read «запускает scripts/build-…» during the build.
Left: «тихо» seen only in tests.

## 2026-10-30 — Answer permission requests from notifications and the panel (branch `feat/approve-from-notification`)

Done: when a Claude Code session asks for a permission, the macOS notification gets «Разрешить» / «Отклонить» (and «Показать»), and the waiting session row in the panel shows the command with the same two buttons. Hook format 2 writes a request file and waits up to 290 s for ClaudePult's answer, printing the PermissionRequest decision; Claude's own dialog stays on screen (checked live: it appears within ~2 s regardless of the hook), whichever answer comes first wins. Waits only while ClaudePult runs with the option on (Settings → Claude Code, default on). PermissionRequest timeout 5 → 300 s (status «нужно обновить» until «Обновить hooks»); the script itself updates without it. 13 languages.
Checked: 212 tests green (incl. the real python hook: allow, deny, no ClaudePult, answered in Claude); live end to end with Claude Code 2.1.314 in an isolated settings file: panel button → «Allowed by PermissionRequest hook», file created.
Left: banner buttons by hand; Oleh's own hooks need «Обновить hooks». Also during the check the Terminal `claude` auto-updated to 2.1.314 and broke (npm left the old version in a temp folder); reinstalled with Oleh's OK, the old 2.1.312 copy moved to the session scratchpad.

## 2026-10-30 — Panel as cards, design variant A (branch `feat/panel-cards`)

Done: Oleh found the panel incoherent; a review found no hierarchy (one long column, everything the same weight), five text sizes with the least important rows the largest, repeated «Показать» and state words, two-line rows that mostly repeat `main`, two differently laid out limit bars, unlabelled grey toggles and no surfaces. Three mock-ups shown; Oleh chose A. Now: every block is a card; header with the profile (menu when several), refresh, Settings, Help, Quit (shortcuts kept); limits as two rings with short resets («сброс Пн 10:00»); one-line sessions (actions on hover, always when waiting) and projects (branch only when not main/master); labelled toggle tiles that light up when on. Also fixed: the «Тёмная» panel theme never applied (`MenuBarExtra` ignores `preferredColorScheme`), now set on the window. 13 languages.
Checked: 205 tests green; live window captures expanded, folded, light and dark; accessibility walk — no icon-only control without a hint; Oleh's theme and folded blocks restored.
Left: hovering a session row, clicking a project, the profile menu with two profiles — for Oleh.

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
Checked: 201 tests green; rule text `visudo -cf` OK; live on a desktop Mac: the section says there is no lid and that sleep is already off by another app; no `pmset`/`sudo` run by ClaudePult (log, `pmset -g`); profile restored.
Left: the real path (password, closed lid, battery floor, removing) needs a laptop — not run here (a desktop Mac, and the password is Oleh's). Found: another app keeps sleep disabled on this Mac.

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
