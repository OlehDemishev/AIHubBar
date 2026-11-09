# Status

<!-- summary:start -->
**Stage:** Mac: 0.7.8 published 2026-11-08, signed and notarized (Developer ID; Accessibility asked once; 0.7.7 hook messages in the app's language, clean session titles; 0.7.6 a map of the panel on the first screen, «Тексты» fixes; before that shorter first run, panel polish, usage history, finished sessions, ⌃⌥B, outages, several Claude accounts). Windows/Linux (`desktop/`, Tauri 2): postponed by Oleh 2026-11-02
**Updated:** 2026-11-09

**Now:**
- tech debt pass agreed with Oleh on 2026-11-09, ending in 0.8.0: Sparkle, lock screen, stale strings, slow expressions check, tests for three controllers, Telegram files split; each its own PR
- merged 2026-11-09: #325 the «Значки» toggle warns that it turns off the whole desktop, #327 Debug builds have their own bundle id, so tests no longer move the login item record
- merged 2026-11-06: #262 donations («Поддержать проект» in Settings → General, site/support.html with Ko-fi, GitHub Sponsors and Buy Me a Coffee; the app button reaches people with the next release)
- merged 2026-11-03: #251 menu bar ☕ follows the «Не спать» switch, #248 «Не спать» on/off in the menu bar, #241 Codex states, #240 quick command shortcuts, #238 «Быстрый запрос», #236 content spec, #242 «Telegram» stage 1, #244 menu at the bottom, #246 shared bot (Worker not deployed yet), #247 desktop CI off for Mac string changes, #249 the bot's menu set up by each person, #252 stage 2 (sessions, requests, limits), #254 stage 3 (tasks and runs), #255 stage 4 (settings in the bot), #256 Mini App

**Next:**
- next release: the language picker's relaunch button, «Раскладка» directions and exceptions, and the «Значки» note reach people with it (all after 0.7.8)
- check on the Air: the island at the real notch
- promotion (docs/LAUNCH.md): r/ClaudeAI, the lists, r/macapps, Show HN, Product Hunt, Homebrew
- content (docs/specs/SPEC-content.md, agreed): stage 2 «Версии», then batch tasks; better after the first feedback from people
- Windows/Linux postponed: no work until Oleh brings it back (where it stopped: docs/specs/SPEC-windows.md §9, stage 2–3 leftovers)

**Needs Oleh:**
- in 0.8.0-beta.1: open a screen in the bot and answer one permission request from Telegram
- in 0.8.0-beta.1: press the «Замок» tile once (Быстрые переключатели); the screen must lock with no error under the tile when you come back
- «Значки» after the next install: press the toggle once, read the note under the tiles, press it again to bring the desktop back (the agent does not change this setting on your Mac)
- optional, one minute: with the desktop on, does `StandardHideDesktopIcons` keep the context menu and drag selection? If yes, the toggle can move to it
- «Раскладка» after the next install: in the language's menu turn off EN → RU, type «ghbdtn» and a space (it must stay); add «vs» to «Словарь исключений» and check it stays too
- free disk space: on 2026-11-08 it swung between 1.5 and 10 GB free with swap near 12 GB, too little to build safely; `~/.colima` holds 37 GB and its Docker disk needs a repair (`colima stop && colima start`)
- press ⌃⌥B, Esc in the open panel, scroll it with the trackpad and run a command in Terminal once (Accessibility works since 2026-11-08)
- 0.7.0 live checks: press ⌃⌥B, right-click a session row; with a second account: Settings → Claude Code → «Другие аккаунты Claude»
- social accounts (docs/SOCIAL.md): sign up under your name, make the avatar, post the first posts; Reddit needs karma over 100 from real answers before the post in docs/LAUNCH.md, the megathread comment can come sooner
- say which of the lists and the Homebrew tap to prepare (docs/LAUNCH.md): the agent is ready to
- Telegram: delete `_daily-report/bot.py` and `install-bot.sh`
- «Быстрый запрос»: Settings → Modules → «Быстрый запрос» on, then ⌃⌥P from Terminal or Xcode — send one task to the background and one to Codex
- Settings → Codex → «Установить hook», then once in `codex` type `/hooks` and trust AI Hub Bar's hooks (Codex skips untrusted hooks); then check a Codex row in «Сессии» goes «ждёт» on an approval prompt
- quick command shortcuts: Settings → Modules → «Быстрые команды» → a command → «Сочетание клавиш», record one and press it
- GitHub → repository Settings → Social preview: upload docs/images/social-preview.png (only by hand)
- Settings → Copilot → «Установить hook»: then start `copilot` and check its row in «Сессии» (the agent wasn't allowed to install it into ~/.copilot itself)
- look at the new Settings and say what to change next
- MacBook Air: update to 0.7.8 through Sparkle and check the island at the real notch
- older, still open: Mac mini Claude CLI sign-in, crash report alert from 16:46, Chinese model keys, ja/ko/ar translations, docs/CHECKLIST.md «Oleh» rows, social preview image, old repo `OlehDemishev/ClaudeBar`
<!-- summary:end -->

## 2026-11-09 — Telegram files split (branch `refactor/split-telegram`)

Done: `TelegramBotController.swift` (1107 lines) is now the class with its state and settings-page actions (216) plus six extensions by its old sections: `+Loop`, `+Requests`, `+Tasks`, `+MiniApp`, `+Menu`, `+API`. `TelegramBot.swift` (961) keeps the settings and menu types (143); `TelegramBotRoutes`, `TelegramBotMessages` and `TelegramBotScreens` hold the rest. The largest file is now 373 lines. No code changed, only where it lives. Swift's `private` is per file, so 55 members used across the new files became internal and five setters lost `private(set)`.
Checked: `scripts/check.sh` green, including the 36 controller tests written before the split for this. A comparison of every code line before and after (access modifiers aside) finds nothing added or lost.
Left: nothing.
## 2026-11-09 — Tests for the notch island and the command engine (branch `test/notch-command-engine`)

Done: `NotchIsland` and `CommandEngine` had no tests of their own. 26 for the island: a fresh card takes no clicks, the pointer has to move, an answer goes out once and the next request waits again, ⌃⌥Y / ⌃⌥N only when on and after the delay, what comes in (switched-off kinds, full-screen apps, requests only from their files), the finished-session banner, file drops. 15 for the engine: an API result written and counted, spend kept across a restart, a failure that leaves no file and costs nothing, an earlier result never overwritten, «Сравнить» names, budget warnings once per level, Terminal, a background run's state, clearing. No user-visible change. Seams: the engine's API call, Terminal and notifications, its spend file and defaults; settable `places`, `queue`, `clickGuard` on the island and `runs` on `RunStore`. A drop on an island with no window no longer crashes (`panels` was indexed unchecked; in the app a place always has its window).
Checked: `scripts/check.sh` green. Mutations: removing the armed check, the re-arm after an answer, the keys' delay, the request kept on «Открыть», the result-file check, the once-per-month warning or the unique file name each fails a test.
Left: the island's pointer tracking, windows and timers need a screen and aren't covered.

## 2026-11-09 — Tests for the Telegram bot's controller (branch `test/telegram-controller`)

Done: `TelegramBotController` had no tests of its own. 36 now, on a fake Telegram, with answers to permission requests written to a temporary folder: strangers get nothing, only the code binds a chat, presses after a gap only navigate, a request is sent once and retried after a wait, an answer reaches the hook's file once, the shared bot's three switches, the task draft, the Mini App's refusals, reading the bot (409, 401, no network, offset). No user-visible change. Seams added: `transport` and `reloadOwnBot` on the controller, `approvalsDirectory` on `SessionStore`; some `private` members became internal for the tests.
Checked: `scripts/check.sh` green. Mutations: with the stranger check, the gap check, `canAnswer`, the shared command switch, the stale check on binding or the retry wait removed one at a time, tests fail each time. That pass also showed shared-bot refusals passing for the wrong reason (no paired chat in the test), fixed by pairing one.
Left: real Telegram isn't touched; a press in the bot and one permission request are in the beta's live check.

## 2026-11-09 — CI on the Xcode releases are built with (branch `chore/ci-xcode-27`)

Done: the Mac job moved from `macos-26` (Xcode 26.6) to GitHub's `xcode-27` image with Xcode 27.2, and runs `scripts/check.sh`, so warnings fail there too and CI runs the same checks as a push. The agreed plan was a slow-expression check in `check.sh`; measured and dropped, because it did not catch the old code that failed CI (DECISIONS).
Checked: `scripts/check.sh` locally on this branch; the Mac job on this PR is the real check of the new image.
Left: the image is a GitHub preview, so it can queue longer. PR #332 (catalog cleanup) was merged before its Mac job had finished, by my mistake: the wait ended at once with «no checks reported». Its run on main then passed (18b2e97), and so did `check.sh` before the push. From here on a merge waits for the checks' result.

## 2026-11-09 — String catalog cleaned and compared with the code (branch `chore/catalog-cleanup`)

Done: the catalog hadn't been synced for a while, so it showed 58 stale keys where a real sync gives 112. Removed 104 unused keys (101 marked stale, 3 untranslated ones the sync dropped itself); the 11 stale keys `desktop/` still uses stay. The file now keeps `xcstringstool`'s order, so the next sync gives a small diff. `scripts/check.sh` syncs a copy with what was just compiled, so an untranslated new text or a key nobody uses fails it, and `strings-check.py` fails on a stale key `desktop/` doesn't use either. Note that the copy must be named `Localizable.xcstrings`: sync matches by table name, any other name marks everything stale.
Checked: `scripts/check.sh` green. A semantic comparison of the sync's output with main: no text changed. None of the 101 keys occurs as an exact literal in the Mac's Swift code, and the code has no dynamic `LocalizationValue` or `localizedString` lookup of app texts. The guard: a copy with a made-up key and a missing translation fails. A second sync gives a byte-identical file.
Left: the comparison runs in `scripts/check.sh` (also before every release), not in CI.

## 2026-11-09 — The lock screen tile checks that it locked (branch `fix/lock-screen-verified`)

Done: the tile relied on a private call and fell back only if the call was gone; a call still there but doing nothing would have passed for success. `ScreenLock` now tries the private call, then ⌃⌘Q by key code (independent of the keyboard layout), then the display's sleep, reading after each step whether the screen did lock (`CGSessionCopyCurrentDictionary`), and logs which step worked. If none did, the tile says «Не удалось заблокировать экран» (13 languages). A test fails on the first macOS that drops the private call; it only looks the call up.
Checked: `scripts/check.sh` green, 3 new tests. `scripts/strings-sync.sh` was not used for the string: it reordered the whole catalog and marked 112 keys stale, so the key was added by hand next to its neighbour.
Left: the real lock isn't run, it would take over Oleh's screen. `CGSSessionScreenIsLocked` is an undocumented key: if macOS doesn't report it, the tile runs all three steps and shows the error although the screen locked. Oleh's press in the beta settles that (Needs Oleh).

## 2026-11-09 — Sparkle 2.10.1 (branch `chore/sparkle-2.10.1`)

Done: Sparkle goes from 2.6.4 to 2.10.1, which brings the security fixes of 2.7.2, 2.9.2, 2.9.5 and 2.9.6 (its changelog). No code change was needed. `docs/RELEASE.md` now says a new Sparkle goes out as a beta first.
Checked: `scripts/check.sh` green with warnings as errors (after removing `build/DerivedData`: the old module cache breaks a build across this version change). A Release build signed by `sign-app.sh`: `codesign --verify --deep --strict` passes, Installer.xpc, Downloader.xpc, Autoupdate and Updater.app carry Developer ID and the hardened runtime, and the framework reports 2.10.1. Our appcast has no deltas and signs the DMG with our own script, so Sparkle's delta and tool changes don't touch us.
Left: not notarized yet and the update itself isn't tried: the changelog says nothing about going from 2.6.4 to 2.10.1, so 0.8.0-beta.1 tests that on a real 0.7.8 before 0.8.0 reaches everyone.

## 2026-11-09 — Conflict with main resolved (branch `fix/desktop-icons-keep-selection`)

Done: `origin/main` (#327, #328) merged into this branch. The only conflict was in this journal, where both sides added entries in the same place; all entries are kept, and a missing blank line before the «Значки» entry is added. The branch now has the Debug bundle id fix, so its test runs no longer move the login item record.
Checked: no conflict markers left in the tree; no code was edited by hand. `scripts/check.sh` was not run locally for this merge, Mac tests and the string catalog are left to CI on the merge commit.
Left: the same as the entries below: the note is unseen in the real panel (Needs Oleh).

## 2026-11-09 — The toggle's tile compiles on CI's Xcode (branch `fix/desktop-icons-keep-selection`)

Done: CI's Mac tests failed on Xcode 26.6 with `QuickToolsView.swift:106: unable to type-check this expression in reasonable time`, on the toggle's `Button` that this branch's hover hint had grown; Xcode 27.2 here compiled it. The tile moved to `QuickToggleTile` and the hint to `hint(for:)`; what they show is the same. `origin/main` merged (#326): the STATUS header keeps both sides' items.
Checked: `scripts/check.sh` green on the merged tree (strings, desktop texts, relay tests, Mac tests with warnings as errors) on Xcode 27.2; the CI result is on the PR.
Left: the panel wasn't opened, the view split is checked by compiling and tests only. The note itself is still unseen in the real panel (Needs Oleh). The local `xcodebuild test` moved the login item record to this worktree's `build/DerivedData` again (`sfltool dumpbtm`); a launch of the installed app puts it back.

## 2026-11-09 — The «Значки» toggle says what it takes away (branch `fix/desktop-icons-keep-selection`)

Done: Oleh's desktop showed no files, no right-click menu and no drag selection. Cause: `CreateDesktop = 0`, which stops Finder drawing the desktop at all; the only writer found is this toggle (QuickTools.swift), though nothing proves it was pressed. While the toggle is off, the panel now keeps a note under the tiles saying so and that the files stay in the Desktop folder; the same text is in the tile's hover hint and the module's Settings footer. The toggle still uses `CreateDesktop`.
Checked: `scripts/check.sh` green, 531 tests, 1 new; 12 translations in the catalog. Live on the Mac mini: `CreateDesktop` was 0; after Oleh ran the restore command it is 1, Finder restarted at 13:59:05 and its full-screen desktop window is back on screen.
Left: the note has not been seen in the real panel, that needs the icons off on a real Mac. `StandardHideDesktopIcons` is not tested: the one answer («рамки нет») came with the desktop still off, so it says nothing about that key, and web sources did not settle it. `scripts/strings-sync.sh` rewrote the whole catalog (46k changed lines) and dropped 3 keys (`%lld%%`, `CI: %@`, `Hooks`), so the catalog was restored and only the new key added; the script itself is unchanged.

## 2026-11-09 — Debug builds no longer move the login item record (branch `fix/debug-bundle-id`)

Done: Debug builds have their own ids, `com.demishev.claudepult.debug` and `.debug.widget`; Release keeps the real ones. The Debug build also gives up `aihubbar://` (it has `aihubbar-debug://`) and doesn't open `*.claudepult` files (`LSHandlerRank` None), because with only a new id macOS sent the widget link to the Debug build. Explained in `docs/RELEASE.md`. Cause found: reading `SMAppService.mainApp.status` in a same-id build moves the record, which `LoginItemController.init` does in every launch and in the test host. Building and `--help-export` don't move it (the earlier note blamed `export-help.sh`; it doesn't).
Checked: on unmodified main, the record moved to the Debug build after `--login-item status` and back after the same command from the installed app; a test run in another worktree moved it there. With the fix: `scripts/check.sh` and `scripts/export-help.sh` green with no change in `site/help`; the Debug build reports `login-item: disabled`; `aihubbar://` and `.claudepult` resolve to `~/Applications/AI Hub Bar.app` after check and after a Release build; a Release build's plist still has the real ids, `aihubbar` and `Owner`. One `sfltool dumpbtm` after all of that (two `check.sh` runs, the export, the Release build): the record is on `~/Applications/AI Hub Bar.app`, generation 483, the same as before the first run, and there is no `.debug` record. The installed app stayed on one pid through all of it. Keychain code uses no access groups or the bundle id, and hooks don't use the id either. Debug settings now go to their own domain, so tests stopped writing to the real one; `defaults write com.demishev.claudepult …` still drives installed builds, a Debug build needs `.debug`.
Left: `pluginkit` lists the Debug widget as a separate extension while a Debug build exists, so the widget gallery may show a second AI Hub Bar; the gallery itself wasn't looked at. Branches without this fix still move the record when their tests run, including #325. `sfltool dumpbtm` asks for an admin password on every call, so it isn't in any script.

## 2026-11-09 — «Раскладка»: directions and a dictionary of exceptions (branch `feat/layout-directions-exceptions`)

Done: the language's menu in the menu bar and the module's settings now choose which directions fix by themselves (`EN → RU`, `RU → EN`, every pair of languages among the enabled layouts, all on by default; a turned-off direction neither fixes nor switches, double Shift and ⌥⇧ still work). The «Не исправлять» list became «Словарь исключений»: words can be added by hand (spaces or commas between them), a word counts on either side of a fix (typed «vs» or its result «мы», any case, punctuation at the ends ignored), and ⌥⇧ leaves such words as they are. The menu has «Словарь исключений…». Saved in the same `layout` settings (`learned`, new `offDirections`), so nothing is lost on update. Help, SPEC-layout, REFERENCE, all 12 translations and `site/help` are updated.
Checked: `scripts/check.sh` green (strings, relay, Mac tests with 8 new ones in `LayoutSwitchTests`). In an isolated copy with its own bundle id, no mouse: the settings page shows all 6 directions for en, uk, ru; a switch turned off, «VS, «github»» added as `vs` and `github`, a row pressed in the real menu bar menu, all read back from the saved settings.
Left: the fix itself with real typing wasn't run: the copy has no Accessibility, so turning a direction off is proven by unit tests only; the row is in Needs Oleh. `xcodebuild test` and `scripts/export-help.sh` run a Debug app with the real bundle id, which moved the login item record to `build/DerivedData` (`sfltool dumpbtm`) again; a launch of the installed app puts it back. The menu lists directions flat: 6 rows for three languages, more for someone with many layouts.

## 2026-11-08 — The language picker keeps its relaunch button (branch `fix/language-picker-relaunch`)

Done: Oleh changed the language and nothing happened. The choice was saved, but it applies at launch and the app kept running; «Перезапустить» lived in the view's state, so leaving the page lost it, and picking the same language again brought nothing back. The picker then showed a language the app wasn't in. Now the button stays while the language after a relaunch differs from the running one (`InterfaceLanguage`), «Как в системе» included. No automatic relaunch: DECISIONS corrected.
Checked: `scripts/check.sh` green, 530 tests, 3 new. Live, in a Debug copy with its own bundle id: running Russian, English → button; another page and back → button still there; Русский and «Как в системе» → no button; Deutsch → button; pressed → the old process exited and a new launch happened (a marker script stood in for the binary). Not seen: the copy actually starting in German with no button, my script failed there; `--help-export` shows the running language equals the choice for en, ru, de, uk.
Left: reaches people with the next release. The real 0.7.8 restarted at 22:36:09 during this check, cause not found (no crash report, no system log). In earlier test passes the copy shared the real settings: `settingsPage` was switched and put back, the language stayed `en`, other keys could not be compared. That same-id copy also moved the login item record to its own path (`sfltool dumpbtm`), so after the reboot at 22:42 the app did not start; opening the real app put the record back on `~/Applications/AI Hub Bar.app`, enabled. The start at login itself is not yet seen after that: it shows at the next reboot.

## 2026-11-08 — Social accounts kit (branch `docs/social-kit`)

Done: Oleh has almost no social accounts and wants new ones only for our products, with clean karma. He chose his own name with an avatar for now; a product can get its own account later. docs/SOCIAL.md has the sign-up order, profile texts, an avatar prompt, first posts, the GitHub profile text and a template for release news.
Checked: post and bio lengths by script; facts from git and the README. Limits as the agent knows them, not checked on the sites. Names not checked for being free.
Left: Oleh signs up and posts; the agent can't sign up or sign in. Which networks are final is his to confirm. Nothing has been posted.

## 2026-11-08 — The r/ClaudeAI post rewritten to the subreddit's rules (branch `docs/reddit-post-rules`)

Done: Oleh pasted the rules: a standalone project post is allowed if it says in detail how Claude helped, says it's free, and keeps promotion minimal; the feed needs karma over 100. The post in docs/LAUNCH.md now has «How Claude helped» and «A few things I learned», and a matching megathread comment.
Checked: numbers from git today (first commit 2026-10-29, 376 commits, all co-authored by Claude, 320 merged PRs, 36k lines of Swift, 527 tests); the lessons come from this week's fixes.
Left: Oleh confirms the first-person claims and his karma, then posts. Nothing has been posted.

## 2026-11-08 — The r/ClaudeAI text brought up to date (branch `docs/reddit-post-claudeai`)

Done: docs/LAUNCH.md has the post for 0.7.8 and a shorter version for the «Built with Claude» project showcase megathread, and says it was made with Claude Code, that it is signed, and that the video's sessions are samples.
Checked: the claims against the README. Reddit was closed to the agent's browser and search didn't find the rules' text, so whether a standalone post is allowed is not confirmed.
Left: Oleh checks the rules, gives the reason he built it in his own words, and posts from his account. Nothing has been posted.

## 2026-11-08 — Demo in the README and on the site (branch `docs/demo-video`)

Done: Oleh chose the second take over the first, which looked jerky with dialogs cut off. In this one the item keeps its width, so the panel stays put; the pointer is slower and leaves the item before a tooltip; the frame has room around the panel; a plain background hides the banner with its Russian button. `site/demo.mp4` with a poster in a new «See it work» section of the site, which respects Reduce Motion; `docs/images/demo.gif` in the README, linked to it, because GitHub doesn't play a local video.
Checked: the site locally in the browser pane, wide and at 375 pt: the video loads and plays, no console errors, no sideways scroll. Oleh looked at the take. Reduce Motion and the README on GitHub were not looked at before merging.
Left: the banner isn't shown in the demo; that takes a Mac in English. The menu bar's ✋ isn't in the take either, by choice.

## 2026-11-08 — Accessibility confirmed, website set, demo draft (branch `chore/status-demo-draft`)

Done: the repository's About box has the website. A 23 s English demo draft was recorded: limits, sessions, a permission request, Allow in the panel, the session finishing. It ran in a separate home folder (`open --env CFFIXED_USER_HOME=… --args -AppleLanguages '(en)' -dailyReportDirectory /nonexistent`) with fake sessions from the real hook script, so none of Oleh's projects or settings are in it. The strip of the menu bar around the app's item is masked: macOS's recording mark, the Russian date.
Checked: after `tccutil reset` and a new grant the log says `Layout: watching keys`, and the next launch kept access with no prompt, so an old record was the cause. Seen live for the first time: the first-launch window with the map, in English; «Permission needed: Bash»; the demo's Allow reached the hook as `allow`; Allow from the notification, per the log at 19:20:34. Oleh's copy runs again in Russian with its settings untouched.
Left: the map's entrance animation is still unseen. macOS draws the notification's «Параметры» button in the system's language, so the banner stays out of a Russian Mac's shot; showing it in English takes a Mac in English. In the draft a tooltip on the item is cut off at the edge for a moment, and the panel moves a little when the item widens, as it does for real.

## 2026-11-08 — Release 0.7.8 (branch `chore/status-release-0.7.8`)

Done: 0.7.8 (build 720) published on Oleh's word, with release notes: Accessibility asked once, a button that clears an old record (#314).
Checked: the release ran `scripts/check.sh`, both notarizations were accepted. The DMG downloaded from GitHub matches the built one, it and the app inside pass `spctl` as «Notarized Developer ID», their tickets validate, both appcasts read back at 720.
Left: not seen running: the line in the panel and the button. Whether an old record was the cause is still open: the app hadn't been restarted since Oleh's reset when this was written.

## 2026-11-08 — Accessibility asked once (branch `fix/accessibility-ask-once`)

Done: Oleh asked why macOS keeps asking. «Раскладка» showed the system prompt at every launch while it had no access (8 times on 2026-11-08, 6 of them from the agent's own restarts), and the log said `Accessibility false` although the switch in System Settings was recorded as on. The designated requirement is the same in 0.7.5 and 0.7.7, so updates don't lose the permission; a record from an earlier signature is the likely cause, not proven, because TCC.db can't be read. Now the prompt comes up by itself once in the app's life. After that a quiet line in the panel, the module's settings and its menu offer «Дать доступ к клавиатуре…», which clears the app's records with `tccutil reset`, asks again and opens System Settings. No new strings.
Checked: `scripts/check.sh`, new tests for when it asks and for the setting being kept. Oleh ran `tccutil reset` for Accessibility and ListenEvent by hand.
Left: not seen running: the line in the panel, the button, and whether access works after Oleh's reset. The next release brings it. Current users who were asked before see the prompt one more time, because the old flag wasn't stored.

## 2026-11-08 — Release 0.7.7 (branch `chore/status-release-0.7.7`)

Done: 0.7.7 (build 714) published on Oleh's word, with release notes: hook messages in the app's language (#311), session titles without the Claude app's system text (#309).
Checked: the release ran `scripts/check.sh`, both notarizations were accepted. The DMG downloaded from GitHub matches the built one, it and the app inside pass `spctl` as «Notarized Developer ID», their tickets validate, both appcasts read back at 714.
Left: not installed on the Mac mini, which stays on 0.7.6 until Sparkle offers the update; that is also the first real check of the hook updating itself. A real notification and the panel in English are still to see, with the demo.

## 2026-11-08 — Hook messages in the app's language (branch `fix/hook-messages-language`)

Done: the hook wrote «Нужно разрешение: Bash» and «Ответ прерван ошибкой API» in Russian, and every language showed them so: the session row, the notification, the island and Telegram. The app now translates them when it reads a session file, so files from older hooks are covered too (2 new strings in 13 languages). The answer to the agent after «Отклонить» is English now: «Denied in AI Hub Bar». `--sessions` prints the message as a last column. Hook format 7.
Checked: `scripts/check.sh`; the Debug build's `--sessions` with a separate home folder and sessions written by the real hook script, in en, de, ja, ar, ru: both messages and the fallback for no tool name.
Left: the next release brings it. Not seen in a real notification or in the panel in English. Reminder for the demo: macOS itself stays in its own language, so the recording is cropped to the panel and its menu bar item.

## 2026-11-08 — Session titles without the Claude app's system text (branch `fix/session-title-wrapper`)

Done: the Claude app puts a `<system-reminder>` block before the person's words, and the hook kept the first 200 characters, so the title was that text and the words were lost (all 27 stored values on this Mac). The hook, format 6, removes the block before clipping and replaces a title saved by the old format with the next prompt; the app updates the script by itself. The app hides the text in files already there: such a session has no title until its next prompt.
Checked: `scripts/check.sh`, new tests run the real hook script with the block, with the block alone, and on an old-format file.
Left: not seen in the running app, so the next release brings it. Sessions already open keep no title until their next prompt, because the words were never saved. The session that looked stale was alive, started 4 days ago: not a bug.

## 2026-11-08 — Release 0.7.6 (branch `chore/status-release-0.7.6`)

Done: 0.7.6 (build 704) published on Oleh's word, with release notes: a map of the panel on the first screen, the «Тексты» fixes from #302 and #306.
Checked: the release ran `scripts/check.sh`, both notarizations were accepted. The DMG downloaded from GitHub matches the built one, it and the app inside pass `spctl` as «Notarized Developer ID», their tickets validate, both appcasts read back at 704. On the release binary, on the sample folder: only «просрочено 2 дн» red in a row, a deadline leaving and coming back in «Ближайшее» at once with the stage, a run called «Корректура» in sessions and in its notification, hints with «…». Oleh's profiles, settings and «Не спать» restored and compared with a backup.
Left: the real first-launch window and its animation, and the rows in CHECKLIST, need a person. The Mac mini now runs the release from ~/Applications. The app still has no Accessibility permission here (Needs Oleh).

## 2026-11-08 — Content stage 1: the panel walked live, five fixes (branch `fix/content-panel-findings`)

Done: walked the «Тексты» profile in the running app, a build of main (0.7.5, build 700, installed on the Mac mini), on a sample folder. Fixed: the whole metrics line went red with no word about why (now only «просрочено 2 дн»); sessions, notifications and the bot called a run «Ты работаешь в папке проекта…» (now «Корректура», «Другой тон: дружелюбнее»); a new stage reached «Ближайшее» up to 5 minutes later; hover hints showed raw `{текст}`; the agent tried to open a `.docx` whose text it already had (a new line in 13 languages). Findings in SPEC-content §7.
Checked: live, by Accessibility and window captures with only clicks on the menu bar item: rows, stage chips and stage changes in the card, the job's row and result link, `.docx` proofread for real from the panel's button, `вопросы.rtf` still the main file after a result, finished work not red, «Ближайшее», the «Календарь» month view. `scripts/check.sh` green with new tests. Oleh's profiles, settings and «Не спать» restored and compared with a backup.
Left: these five fixes were made after the live pass, so they have tests where they can but were not seen running; the row and the instant «Ближайшее» have no test at all. Not walked: a command that asks for text past its field, a real «Сравнить», the week view, dragging a date, the island drop (CHECKLIST). `--app-command open-panel` opens search instead of the panel here because the app has no Accessibility permission, the item already in Needs Oleh.

## 2026-11-08 — First screen: a map of the panel (branch `feat/welcome-panel-map`)

Done: on the assistant's first screen the right side no longer repeats the plain preview: it shows the panel on sample data, with five notes and arrows (menu bar, limits and forecast, agent sessions, answering a permission request, modules). Drawn from the app's own pieces (the menu bar renderer, the limit ring, session colours), so it follows the interface. The arrows use the pieces' real positions and hold in long languages and right to left. A short entrance, none with Reduce Motion. `--assistant-preview <file> welcome [--dark]` renders it, also usable for the README and Product Hunt. 5 new strings in 13 languages, added by hand: `scripts/strings-sync.sh` also marked 56 keys stale and removed 3, so that part was not kept.
Checked: `scripts/check.sh` green. Rendered and looked at in all 13 languages, light, and in Russian and Arabic dark.
Left: not seen in the real first-launch window, which needs a Mac with no settings, and the entrance animation not seen at all (CHECKLIST). The sync's 56 stale keys and 3 removals on main are a separate question.

## 2026-11-08 — Content stage 1: headless walkthrough and three fixes (branch `feat/content-walkthrough`)

Done: walked the «Тексты» logic on a sample folder without touching the panel. Fixed: background commands on `.docx` failed (the agent has no shell to open one; now `.docx` and `.rtf` text goes in the prompt, up to 400,000 bytes); a command's result became the main file when the card names none; projects at the profile's last stage stayed overdue in «Проекты» and «Ближайшее», got reminders and could be the menu bar's nearest date. `--calendar` and `--folder-projects` take an optional template, so they follow the same rules. Findings in SPEC-content §7.
Checked: installed 0.7.5 from the command line and «Корректура» with the app's exact arguments on `.md`, `.rtf`, `.docx`, which reproduced the bugs. The same run with the `.docx` text in the prompt, built by a script, gave a real proofreading. New tests added. Mac tests and String catalog passed in the PR's CI. Locally only `swiftc -parse` and `scripts/strings-check.py`: `scripts/check.sh` not run, the disk was at 1.5–2.6 GB free.
Left: no local build, so the fixes have not been seen in the running app. With the text in the prompt the agent still tries to open the `.docx` first and may mention the failure in its result; the fix is a wording change in all 13 languages. Nothing in the panel was looked at yet (Oleh was in a game and the screen stays his): rows, chips, command buttons, «Сравнить», «Ближайшее», «Календарь», island drop. A result of a command on the whole project still counts as a main file candidate, on purpose. A person's own file named like a result, such as `сценарий-финал.md` next to the pattern `сценарий-{язык}.md`, needs «Главный файл» in the card.

## 2026-11-08 — Air update and Telegram confirmed (branch `chore/status-air-telegram-checked`)

Done: recorded Oleh's live checks: the Air updated through Sparkle across the certificate change and asked for permissions again, as docs/RELEASE.md expects; the Telegram bot and the Mini App work. The Developer ID decision is gone from Needs Oleh, since it is done. docs/LAUNCH.md: starting numbers and blockers brought up to date.
Checked: Oleh's word for the live checks; numbers from `gh` (0 stars, 41 DMG downloads over all releases, 6 unique visitors in two weeks, no website in the About box). Docs only, no code changed, so scripts/check.sh not run.
Left: the island at the real notch on the Air was not mentioned, so it stays in Next.

## 2026-11-07 — Release 0.7.5 (branch `chore/status-release-0.7.5`)

Done: 0.7.5 (build 686) published: the panel header blends into the cards, the first card has its 8 pt gap.
Checked: the release ran scripts/check.sh and both notarizations were accepted; the DMG downloaded from GitHub, its ticket and the app inside were checked, both appcasts read back.
Left: the update through Sparkle and the real notch on the Air.

## 2026-11-07 — Panel header blends in (branch `fix/panel-header-blend`)

Done: on glass the header and search no longer sit on a grey slab with a hard edge: their tint is the cards' colour and fades out at the bottom. The first card is 8 pt below the search, as cards are from each other, and scrolled cards fade out in that gap.
Checked: scripts/check.sh passed; live panel in light at rest after the last change, in light and dark scrolled with the earlier 16 pt gap.
Left: the scroll fade was not looked at again after the gap went to 8 pt (Oleh was in a game); not in a release yet.

## 2026-11-07 — overnight readiness check (branch `chore/status-overnight-check`)

Done: no code changes; 0.7.4 was already out with the UI audit fixes. Removed old local release folders 0.7.0–0.7.3 (all on GitHub Releases), `build/DerivedData`, `build/release/DerivedData` and the merged worktree `feat-quick-prompt-de3c78` with its branch; `build/` went from 2.3 GB to 64 MB, `build/release/0.7.4` kept.
Checked: `scripts/check.sh` green on `main` 90e1a51: strings check, desktop strings, relay `node --test` 15/15, `xcodebuild test` with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
Left: the Sparkle update across the certificate change and the notch island are still to be checked on the Air; the rest of «Needs Oleh» unchanged.

## 2026-11-07 — Release 0.7.4 (branch `chore/status-release-0.7.4`)

Done: 0.7.4 (build 680) published with the UI audit's fixes: permission requests, the panel, Settings, the island, windows and widgets.
Checked: the release ran scripts/check.sh and both notarizations were accepted; the DMG downloaded from GitHub, its ticket and the app inside were checked, both appcasts read back.
Left: the update through Sparkle and the real notch on the Air; keys, the calendar and CLAUDE.md windows, widgets.

## 2026-11-07 — GitHub description covers every AI service (branch `docs/ai-services-wording`)

Done: the repository description, README, guide, site and overview PDFs speak of AI services and agents instead of Claude alone. Claude stays named where a feature is really its own: several accounts, Anthropic's status, the sign-in. The old claim that limits and sessions need Claude Code is corrected.
Checked: both PDFs rebuilt; the description read back from GitHub.
Left: the social preview image and the drafts in docs/LAUNCH.md were not touched.

## 2026-11-07 — Final pass fixes (branch `fix/final-pass`)

Done: F1–F9. Scrolled cards no longer cover the search and header on glass. «Ближайшее» belongs to folder profiles by one rule, so a git profile no longer lists a block it never draws. VoiceOver reads session rows as text again, with the state by name. «Панель» fits the minimum window: the sketch hides there, titles don't truncate. German disk is «Festplatte». Tracking reads «включено / выключено», and the first lines of its footnotes no longer say hook. The clipboard apps row lines up and shows names. The AI section is translated, the OpenAI-compatible buttons look like buttons, island setup options start with a capital, Help illustrations use neutral names, limit names follow the language at once. 4 new strings in 12 languages.
Checked: scripts/check.sh passed, with new tests for the rule and the titles; on the installed app: the scrolled panel on glass, «Панель» at 940 and 820, the clipboard list, the «Ближайшее» page.
Left: dark theme after the glass change was not looked at again; keys, the calendar and CLAUDE.md windows, widgets, a real notch.

## 2026-11-07 — Final UI pass (branch `docs/ui-final-pass`)

Done: a full look at build 674, recorded as F1–F9 in docs/specs/AUDIT-ui.md. The main one: on glass, the default background, scrolled cards cover the search and the header. No code changed.
Checked: 28 Settings pages in Russian light and German dark, the minimum window, the panel in four modes, the ⋯ menu, search, the delete dialog, six windows, the pill's banner.
Left: F1–F9 are open. Keys posted by a script don't reach the app, so ↑ ↓, Esc and typing in Settings search are unchecked; the calendar and CLAUDE.md windows, widgets, a real notch and VoiceOver by ear too.

## 2026-11-07 — Settings and windows details (branch `fix/settings-details`)

Done: the last small things of the audit. Place chips wrap on a narrow window, the «Уведомления» chip on «Ближайшее» follows «не напоминать», the language picker shows «Как в системе» truthfully, previews in Settings and the assistant draw limits as rings like the panel. Windows have one kind of title, without «— AI Hub Bar». The ⌃⌥C window floats like «Быстрый запрос» and goes away on a click elsewhere. Russian texts say Mac everywhere; the bot's menu button keeps «Мак», people have it saved in Telegram.
Checked: scripts/check.sh passed; site/help exported.
Left: menu bar order chips of switched-off modules stay listed: dropping them would lose their place in the order.

## 2026-11-07 — Panel details (branch `fix/panel-details`)

Done: audit items 13, 14, 16, 17 and the rest of 18. Block titles match Settings («Лимиты AI», «Сессии агентов», «Отчёты»), the module lost `_daily-report` from its name, the folded summary says «Процессор · память». The count over the sessions means working and waiting. Grey on glass is darker, the search field has the cards' tint, grey captions moved a step up. The header has four icons: help, CLAUDE.md and quit moved into a menu, ⌘Q still works. A project found in search is scrolled to, and only offered when the profile shows projects. Queued launches moved to the sessions block. ⌘R also refreshes folder projects and the calendar. An empty panel says so with a way to Settings, command results can be hidden, a failed clipboard search says so, hover no longer cuts the task short. Old limits lose their colour in the menu bar. 1 new string in 12 languages.
Dark theme on glass was unreadable over a bright window (white header on white): the header and search now have the cards' tint.
Checked: scripts/check.sh passed, with a new test for stale limits; looked at the live panel in dark and light, on glass and on the standard background.
Left: the ⋯ menu was not opened by hand.

## 2026-11-07 — Windows and widgets leftovers (branch `fix/windows-leftovers`)

Done: audit items 15, 34–38. An expired sign-in shows «Войти в Claude Code» also while old limits are on screen, and past the reset there is no countdown. ↑ ↓ work in the ⌃⌥C window, a background run opens its log there, and the tooltip says «Открыть в Терминале». The empty «Очистка сборок» window offers the check. CSV exports the chosen period, the calendar's «ещё» counts right and its sheet answers Esc and ↵. Widgets: no «сброс через 0 мин», the small one falls back to the week, percent written one way, «с проблемами» fits the small size. 2 new strings.
Checked: scripts/check.sh passed, with a new test for the reset.
Left: not looked at live. Open from the audit: 13 (names), 14, 16 (contrast), 17, the rest of 18, the menu bar's stale percent. Settings and the assistant still draw limits as bars, the panel as rings.

## 2026-11-07 — Settings leftovers (branch `fix/settings-leftovers`)

Done: audit items 6, 25, 30. Deleting a quick command, a prompt, a service key and clearing the clipboard history ask first, and a ready-made menu bar set asks before replacing a custom one. A switch to Telegram or the language in the menu bar lives once, in the chips under «Где показывать»; the rows repeating them are gone. The «Уведомления» chip on «Проекты» follows the PR alerts. Module tiles and menu bar chips work from the keyboard. A failed export or «Войти» shows an alert. Excluded clipboard apps are listed by name and can be removed one by one. «Указать цену…» leads to the Anthropic price, which no longer needs a key. In the panel «Очистить» asks, «скопировано» goes away, the Notes trash waits for the block to unfold. 2 new strings in 12 languages.
Checked: scripts/check.sh passed.
Left: not looked at live yet; the «Уведомления» chip on «Ближайшее» still ignores «не напоминать».

## 2026-11-07 — The island's state (branch `fix/island-state`)

Done: audit items 22, 31–33. The buttons in the open card could stay dim for good: the panel got no mouse moves, so the click guard never let go; now it does. Only what is drawn reacts to the pointer, so the free space beside the notch no longer opens the card, and hover does nothing over a full-screen app. An ear with nothing to show takes no room, each side on its own. With both ears empty the numbers stay in the menu bar. Requests in the card scroll past 230 pt, the window is 520 pt tall, and a click on the notch opens the card behind a banner. The «Остров» chip is off with a reason unless ears can show, the ear pickers wait for «только в острове», the menu bar preview follows the island with a note. Help and the module text no longer promise ears by default; site/help exported. 6 strings in 12 languages.
Checked: scripts/check.sh passed, with a new test for the ears' room; on the simulated notch: one ear shown and the other side free, no card from the empty side, the card from the notch, three fake requests scrolling, buttons lit after a move, the menu bar with only its icon.
Left: a real notch and a full-screen app on the Air; the pill still has no way to open its card (its rest frame stays empty on purpose); `Сессий Claude Code сейчас нет` stays in the catalog for desktop/.

## 2026-11-07 — Settings texts (branch `fix/settings-texts`)

Done: audit items 23, 24 and part of 26. Footnotes point to pages that exist («Панель», «Лимиты AI») instead of tabs and old routes. Codex and Copilot use the same words as Claude Code: «Отслеживание сессий», «Включить отслеживание», «Выключить отслеживание». Long module subtitles are cut to what fits two lines, and the owner's project names are gone from the sample and the widget gallery. 18 strings changed in 12 languages.
Checked: scripts/check.sh passed.
Left: `.claudepult` and «ClaudePult Notes» stay: they are a real file type and folder. Technical footnotes keep the word hook. Audit items 22, 25 and 30 are still open.

## 2026-11-07 — Settings rows and sidebar (branch `fix/settings-rows`)

Done: audit items 19–21, 27–29. Every row's icon stands in one column, so titles line up on all pages, and rows that had no icon got one. Prompts and quick commands use fields on their own line, aligned left. The sidebar scrolls to the chosen page, also after a link, «Сервисы AI» always shows its arrow and a service's page opens the section. Search reads subtitles and more setting names and says «Ничего не найдено». Presets wrap, module options sit under the title in «Панель», the page header keeps its height for one or two lines, sections no longer repeat the page's title.
Checked: scripts/check.sh passed, with a new test for the search; installed and looked at eight pages.
Left: three-line subtitles still move the page; the texts come in the next branch.

## 2026-11-07 — The panel's frame (branch `fix/panel-frame`)

Done: audit items 7–12. The blocks scroll under a fixed header and search and stop at the bottom of the panel's own screen; the project list no longer scrolls on its own. Week days read «Пн Вт Ср…». «Команды» and the menu bar show the same live free space as «Ресурсы Mac». Folded cards are one height, block titles are one step larger. Esc closes the panel through the same real click as ⌃⌥B.
Checked: scripts/check.sh passed; installed and looked at the live panel: 1041 pt on a 1080 pt screen with everything open, «Не спать» reached through the scroll bar, equal folded cards, two fake requests with whole commands and buttons under them.
Left: posted wheel events did not move the scroll view, so a real trackpad scroll is unchecked. Esc needs the Accessibility permission (no call closes a `MenuBarExtra`: window close breaks the next click, resigning key or active does nothing) and was not pressed by hand. The island's button order and guard were not seen live.

## 2026-11-07 — Permission buttons you can trust (branch `fix/permission-safety`)

Done: audit items 1–5. The panel and the island show «Отклонить, Разрешить» in the same order, «Разрешить» last, in a darker green on the island. Rows inside a group keep their place: the oldest request first, a new one below it, running sessions by when they started. Whenever a request comes or goes, the buttons wait 0.6 s in the panel and re-arm the guard in the open island. The whole command is shown, with the buttons on their own line. Edits in the CLAUDE.md window stay as drafts when another file is chosen or the window closes, with a dot on the file; they live until the app quits. 1 new string in 12 languages.
Checked: scripts/check.sh passed, with new tests for the order of rows and for changes in the request list.
Left: not tried live yet.

## 2026-11-07 — UI audit of 0.7.3 (branch `docs/ui-audit`)

Done: docs/specs/AUDIT-ui.md with 38 findings by priority and an order of work. Main ones: permission buttons swap places between the panel and the island, the panel runs off the screen with no scroll, Esc does not close it, week days repeat letters, Settings row labels do not line up.
Checked: the live panel in light glass, all 28 Settings pages, six windows, the view code read in full. No code changed.
Left: dark theme, the system background, a real notch, other languages and VoiceOver were not seen live; nothing is fixed yet.

## 2026-11-07 — Release 0.7.3 (branch `chore/status-release-0.7.3`)

Done: 0.7.3 published with the choice between the menu bar and the island, the clearer ring and the English fallback.
Checked: the DMG downloaded from GitHub passes `spctl` as «Notarized Developer ID», its ticket validates, both appcasts point at 0.7.3.
Left: the Air check of the update and of the real notch.

## 2026-11-07 — Notch or menu bar (branch `feat/notch-or-menubar`)

Done: from Oleh's look at the real notch on the Air: the ears sat on the menus of the app in front and repeated the menu bar. «Сводка» is now one place: the menu bar (the default, the island shows only events) or the island (the menu bar keeps only ✦, which opens the panel). The former «both» becomes the menu bar. The left ear's ring has a visible track and always shows its number: at 40 % it looked like a broken half circle.
Checked: scripts/check.sh passed with a new test for the choice.
Left: not seen on the real notch; the Air needs this build. In «только в острове» the left ear can still cover long app menus: «Ничего» in its picker turns it off.

## 2026-11-07 — English for languages without a translation (branch `fix/english-fallback`)

Done: with a system language outside the 13 the app opened in Russian, its development language. At launch `LanguageFallback` now sets English for that launch. A change of `CFBundleDevelopmentRegion` was tried first and dropped: Russian has no `.lproj`, so it broke Russian, and a `ru.lproj` table can't sit next to the string catalog.
Checked: scripts/check.sh passed with new tests; `--help-export` with `-AppleLanguages`: Dutch and Turkish give English, Russian, German and Ukrainian stay.
Left: system permission texts from Info.plist stay Russian for such languages. Goes out with the next release.

## 2026-11-07 — Release 0.7.2 (branch `chore/status-release-0.7.2`)

Done: 0.7.2 published (build 646), the first release with a Developer ID and notarization. The release notes say that macOS asks for permissions once more after updating.
Checked: the DMG downloaded from GitHub passes `spctl` as «Notarized Developer ID», its ticket validates, both appcasts point at 0.7.2, the site no longer mentions Open Anyway, CI on main is green.
Left: the update from 0.7.1 through Sparkle hasn't been run.

## 2026-11-07 — Developer ID and notarization (branch `feat/developer-id`)

Done: Apple Developer Program active (team 365835Q3S6). Builds are signed with a Developer ID, hardened runtime on, Apple Events entitlement for Terminal. `scripts/release.sh` notarizes and staples the app and the disk image and stops if Apple refuses. `scripts/build-and-install.sh` uses the same certificate. README, GUIDE, site, RELEASE and LAUNCH no longer talk about Open Anyway.
Checked: scripts/check.sh passed; 0.7.2 built unpublished, both notarizations «Accepted», `spctl` says «Notarized Developer ID» for the app and the DMG, stapler validates both. Installed on this Mac: it starts, no crash report, projects and agents load.
Left: the new signature drops macOS permissions once: Accessibility for «Раскладка» and ⌃⌥B, Automation for Terminal. Sparkle allows a new certificate with the same Ed25519 key (its docs), but the update from 0.7.1 itself hasn't been run.

## 2026-11-06 — Release 0.7.1 (branch `chore/status-release-0.7.1`)

Done: 0.7.1 published (build 641) with the ⌃⌥B fix: the key no longer opens the «Раскладка» menu.
Checked: scripts/check.sh ran inside the release; the release, its appcast and the download answer. The log on this Mac shows the key aiming at the panel's item.
Left: a live press of ⌃⌥B.

## 2026-11-06 — Release 0.7.0 and the panel shortcut fix (branch `fix/panel-hotkey-item`)

Done: 0.7.0 published (build 639). A check after publishing found ⌃⌥B opening the «Раскладка» menu: the app has two menu bar items and `PanelOpener` took the first. It now leaves out the layout item, and the log says which item it would click.
Checked: scripts/check.sh passed with a new test; the release, its appcast and the download answer. On the running app: see the log line «Panel item».
Left: the fix needs a live press of ⌃⌥B and a release of its own (0.7.1).

## 2026-11-06 — Several Claude accounts (branch `feat/claude-accounts`)

Done: Settings → AI Services → Claude Code → «Другие аккаунты Claude»: a name and a config folder (`CLAUDE_CONFIG_DIR`), «Войти» runs `claude auth login` for it in Terminal, and its limits appear in the block, every 5 minutes, 30 minutes' pause after HTTP 429. The Keychain name follows Claude Code's own rule, read from its code in 2.1.316: `Claude Code-credentials-` plus the first 8 hex digits of the folder's SHA-256. 5 new strings in 12 languages.
Checked: scripts/check.sh passed with new tests for the Keychain name and the sign-in line.
Left: not tried with a real second account (none on this Mac). If Claude Code changes the naming, such an account shows the sign-in error.

## 2026-11-06 — Service status (branch `feat/service-status`)

Done: when the limits fail with a server or network error or an unknown answer, the app asks Anthropic's status page at most every 10 minutes and shows «Сбой у Anthropic: …» with a link in the limits block. It clears when the limits work again. Without internet nothing is claimed. README lists the page among what the app talks to.
Checked: scripts/check.sh passed with new tests for reading the page and for which errors ask it; the page answered live from this Mac («All Systems Operational»).
Left: only Anthropic for now; the banner itself hasn't been seen in a real outage.

## 2026-11-06 — Panel shortcut (branch `feat/panel-hotkey`)

Done: «Клавиши» → «Открывать панель» (⌃⌥B by default, also ⌃⌥M and ⌥⌘B). `MenuBarExtra` has no call to open it, so `PanelOpener` posts a real click on the app's item and puts the pointer back; that needs the Accessibility permission, and without it the search window opens. The key counts as the app's own in the shortcut conflict check. `--app-command open-panel` runs it. 3 new strings in 12 languages.
Checked: scripts/check.sh passed.
Left: not pressed live, Oleh was using the Mac. The earlier note said `MenuBarExtra` ignores synthetic clicks, while a click posted from outside the app opened it on 2026-11-06, so this one needs a live check: `AIHubBar --app-command open-panel`.

## 2026-11-06 — Continue finished sessions (branch `feat/resume-sessions`)

Done: «Сессии» has «Недавно завершённые»: the last five finished Claude Code sessions whose folder still exists. A click runs `claude --resume` in Terminal, in that folder. Ended rows have «Продолжить в Терминале» in their context menu. The block stays when only such sessions are left. 3 new strings in 12 languages.
Checked: scripts/check.sh passed, with a new test for which sessions can be continued and for the command line.
Left: not clicked live: Oleh was using the Mac.

## 2026-11-06 — Usage history (branch `feat/usage-history`)

Done: «История расхода…» under «Расход по проектам» opens a window with Claude Code tokens by day (7, 30, 90 days), totals, the busiest day, a CSV export and a cost estimate at the price the person entered. Days are kept in `usage-days.json` for about a year with the day's highest limit percentages; the first run reads the journals' last three months once. `--app-command usage-history` opens the window. 18 new strings in 12 languages.
Checked: scripts/check.sh passed with new tests for merging days, peaks, retention, cost and CSV; installed on this Mac.
Left: the window was seen only behind another app, not read closely.

## 2026-11-06 — Settings and texts (branch `feat/settings-polish`)

Done: the sidebar lists the modules in use; the rest stay in «Модули» and the search, «Отчёты» only on a Mac with `_daily-report`. New page «Клавиши» with every shortcut. Deleting a profile asks first. One name for each action: «Запустить» for runs, «Справка» for help. «Отслеживание сессий» replaces hooks in everyday text; the technical footnotes keep the word. Old pointers fixed («этап 4», «Основные → Telegram», «в низу панели»). 23 changed strings in 12 languages, most built from the existing translations.
Checked: scripts/check.sh passed.
Left: site/help is exported again after the last change of this plan.

## 2026-11-06 — Panel polish (branch `feat/panel-polish`)

Done: the forecast reads as one line when both limits last («хватит и на сессию, и на неделю»), «неделе до сброса хватит» is gone. The week's days are slim bars with their percentage and a caption. Cards on glass get a tint of the window colour and block titles are no longer grey there. «Сессии» shows how many are active, and stays in place with «нет активных» when none are; the hint no longer appears without Claude Code. Search takes focus when the panel opens, ↑ ↓ move the selection, ↵ works for folder projects and background runs. Session rows have a context menu and a VoiceOver action; icon-only buttons have labels; the session pulse follows Reduce Motion. «Сравнить» says why a service failed instead of «ещё выполняется». 6 new strings in 12 languages.
Checked: scripts/check.sh passed; installed and looked at the live panel: titles and cards readable over the wallpaper, session count shown.
Left: arrow keys in search were not pressed live.

## 2026-11-06 — First run (branch `feat/first-run`)

Done: the first launch takes a short path of five screens (welcome, template, modules, folder, finish) with «Настроить подробнее…» for the rest; importing moved onto the welcome screen, «Пропустить» is gone. Readiness knows a missing sign-in (from the limits request, no extra Keychain read) and offers «Войти в Claude Code» (`claude auth login` in Terminal, then the limits are asked again for two minutes) and «Установить Claude Code». The panel shows those buttons instead of an orange error, and a person without Claude Code gets a plain explanation. A first profile refreshes the limits at once. Commands start on an installed service when Claude Code is missing. A hook install failure shows on the welcome screen, a folder that can't be created stops with an alert. The assistant offers «Раскладка», «Быстрый запрос» and Telegram. 13 new strings in 12 languages.
Checked: scripts/check.sh passed, with new tests for the short path, sign-in rows and which errors need a sign-in.
Left: the short path and the sign-in flow were not walked through live (this Mac is set up and signed in).

## 2026-11-06 — Launch kit (branch `chore/launch-kit`)

Done: docs/LAUNCH.md with the starting numbers, blockers, order of posts, answers to likely questions, and drafts for r/ClaudeAI, r/macapps, Show HN, Product Hunt and a short post. README no longer calls «Раскладка» a beta feature.
Checked: claims in the drafts compared with README, DECISIONS and the 0.6.0 release; docs only, so no build was run.
Left: nothing is posted. The rules of r/ClaudeAI, r/macapps and the lists were not read. Homebrew's exact notability numbers were not confirmed in its own docs. No cask made: without a Developer ID it would not get past Gatekeeper any easier.

## 2026-11-06 — Buy Me a Coffee on the support page (branch `feat/buy-me-a-coffee`)

Done: the Buy Me a Coffee card in site/support.html is live (buymeacoffee.com/olehdemishev), added to `.github/FUNDING.yml`. The Ko-fi card now says one-off or monthly.
Checked: the Buy Me a Coffee page opened as a visitor and shows its payment form; scripts/strings-check.py not needed, only the site, FUNDING and STATUS changed.
Left: the Sponsor button in the repository needs Sponsorships turned on by Oleh.

## 2026-11-06 — Donations (branch `feat/donations`)

Done: Settings → General → «Поддержать проект» opens site/support.html (`Feedback.supportPage`); the app never asks by itself. New page site/support.html with live Ko-fi (ko-fi.com/olehdemishev) and GitHub Sponsors cards, a Buy Me a Coffee card kept in an HTML comment until that account exists, and free ways to help. Link in the site footer, README section, `.github/FUNDING.yml` with GitHub Sponsors, Ko-fi and the page, REFERENCE updated. 2 new strings in 12 languages. The platforms live on the page, so changing them needs no app release.
Checked: scripts/check.sh passed (strings, desktop texts, relay tests, Mac tests); support.html opened in the local preview, no console errors; both donation pages opened as a visitor, each shows its payment form.
Left: Buy Me a Coffee is optional and has no account; Stripe is still verifying the GitHub Sponsors account. The new row was not opened in the running app, only built and tested. The button reaches people with the next release.

## 2026-11-03 — site and overview for 0.6.0 (branch `feat/site-0.6.0`)

Done: site — a «Telegram» section (phone mock-up: 🏠 screen and a permission request with ✅ / ❌, the menu at the bottom; link to @AIHubBarBot) and a nav link; privacy rewritten («No account, no analytics» instead of «No server», a paragraph on the shared bot's relay: no message text logged, only chat ↔ Mac and messages for a sleeping Mac up to a day; requests and tasks over it off by default; own bot as the alternative); Codex in the sessions line, ⌃⌥P in the commands card; Mac tools tiles for «Быстрый запрос», quick commands with shortcuts, the Telegram bot and the command line. Overview PDFs (en, ru): no «beta» on Layout fix, cover chip «No account», ⌃⌥P with the search, quick commands' shortcuts, «Telegram bot» card, privacy line about the relay; rebuilt with scripts/make-overview-pdf.sh.
Checked: site in the browser at 1280 px and 375 px (no horizontal scroll, request buttons on one row); both PDFs still 9 pages, page 8 rendered and looked at in both languages.
Left: the v0.6.0 release's attached PDFs are replaced after merge.

## 2026-11-03 — release 0.6.0 (branch `chore/status-release-0.6.0`)

Done: `scripts/release.sh 0.6.0 --publish` from main 295c267 (build 600): GitHub release v0.6.0 is Latest with the .dmg, appcast and overview PDFs; the beta channel now lists 0.6.0 above 0.5.1-beta.1. «What's new» added to the release notes (Telegram, «Быстрый запрос», command shortcuts, Codex states, «Раскладка» out of beta). `_daily-report/config.json` now sends through @AIHubBarBot (checked with getMe).
Checked: release.sh ran the tests and the string catalog first; `releases/latest/download/appcast.xml` serves 0.6.0 / 600.
Left: the overview PDFs attached are the 1.0 ones without Telegram; the site's privacy section still says «No server»; Telegram pairing not yet tried live.

## 2026-11-03 — «Раскладка» out of beta for 0.6.0 (branch `feat/layout-out-of-beta`)

Done: Oleh's call — «Раскладка» works for everyone without «Бета-версии»: its `isBeta` dropped, the help step no longer mentions beta, and «Бета-версии» in General says only «new builds first» when no module is in testing (2 new strings in 13 languages, inserted without reordering the catalog). Docs (SPEC-layout, SPEC-settings, specs README, RELEASE, REFERENCE), the site's layout section and `site/help` updated.
Checked: scripts/check.sh green; `ModuleRegistryTests` expects no beta modules, `ModuleSwitchTests` checks «Раскладка» works without beta builds.
Left: the 0.6.0 release itself.

## 2026-11-03 — shared Telegram bot deployed (branch `chore/telegram-relay-url`)

Done: Oleh deleted the old bots (`@DailyReportCCbot`, the dead approvals bot), made a new one and signed in to Cloudflare; the relay `relay/telegram` is deployed as `aihubbar-telegram` on `oleh-demishev.workers.dev` (the account's workers.dev subdomain had to be created in the dashboard first, error 10063), secrets BOT_TOKEN / WEBHOOK_SECRET / ADMIN_SECRET set (the last two random, kept in the Keychain, `aihubbar-relay`). `TelegramRelay.defaultURL` now points at it.
Checked: `npm test` in relay/telegram (0 failed); `/app?demo=1` answers 200 and `/admin/setup` without the key 403 (the new subdomain needed ~80 s before TLS worked); scripts/check.sh green.
Left: pairing and the live check (bot screens, Mini App, a permission request); `_daily-report/config.json` still has the deleted bot's token.

## 2026-11-03 — Telegram Mini App (branch `feat/telegram-mini-app`)

Done: Oleh chose the Mini App over a list of commands, with the shared bot. Spec §10. `relay/telegram/src/app.html`: one page served at `/app` (CSP: own scripts, Telegram's script, own API only) — tabs 🏠 (rings, requests, sessions, runs, disk), 🤖 (requests with Разрешить / Отклонить, sessions), 🚀 (projects, the task field, runs with Журнал / Остановить, PR links), ⏳ (every service with bars, resets, forecast), ••• (reports, cleanup, «Не спать», quick commands, alerts, quiet hours, silence); Telegram's theme colours, Russian or English by the user's language, haptics, Telegram's own confirm and popups, refresh every 10 s, «💤 … не на связи» when the Mac sleeps, `?demo=1` (and any local file) shows sample data. Relay: `POST /v1/app` checks Telegram's `initData` signature (HMAC with the bot token, under a day old) and passes `{type: "app"}` to the chat's answering Mac, 15 s for `appReply`; `/admin/setup` makes `/app` the Menu button. Mac: `MiniAppCall` (every action checked like the bot's buttons), `MiniAppState` / `MiniAppReply` (Codable), `TelegramBotController.handleApp` with the same rules as the bot (answers, tasks, quick commands over the shared bot need their switches); `startTask` shared by the bot and the app. Settings → Modules → Telegram → «Где меню»: at the bottom and in the Menu button, or only in the Menu button (the keyboard goes away with a note). 12 new strings in 12 languages; the page has its own Russian and English texts.
Checked: scripts/check.sh green; 4 new relay tests (initData signature, age, tampering; a call reaches the answering Mac and back; refused / unpaired / offline / bad action; setup sets the Menu button), 6 new Swift tests (`TelegramMiniAppTests`); `wrangler deploy --dry-run` bundles the page (60 KB); end-to-end against `wrangler dev`: the page with its CSP, a signed call answered by a fake Mac, another bot's signature 401, another person 404, Mac offline 503; the page in the browser pane at phone size, all five tabs with sample data.
Left: live in Telegram only after the Worker is deployed and its address is in the app.

## 2026-11-03 — Telegram stage 4: settings in the bot, quiet hours, «Не спать» (branch `feat/telegram-settings`)

Done: ⚙️ Настройки in the bot — ✅/☐ for what comes to Telegram (background results, limit thresholds, calendar, PR and CI, permission requests, weekly summary: the existing settings), quiet hours (none / 22–08 / 23–08 / 00–09), «Тишина на 1 ч» / «Снять тишину», the morning report time read from `_daily-report`'s launchd agent (shown, not changed; `/report` counts from it), «Настроить меню». Quiet hours and silence hold back alerts in `Telegram.notify` only. Settings → Modules → Telegram → «Уведомления в Telegram» shows the same. 🧹 Мак: «Не спать» on for an hour or off when that module is installed. ⚙️ joins the default bottom menu (8 buttons). 22 new strings in 12 languages.
Checked: scripts/check.sh green; 4 new tests (`TelegramSettingsTests`: quiet hours across midnight, an hour of silence, the ⚙️ screen, «Не спать» on 🧹), updated menu and route tests.
Left: not tried live.

## 2026-11-03 — Telegram stage 3: tasks and run control (branch `feat/telegram-tasks`)

Done: 🚀 Задача — the profile's projects (most active first) → the task typed as the next message (10 minutes, `/cancel`) → shown back in a quote with «Запустить» → started like «Своя задача…» in the background (`LaunchController`); the 90 % question («Всё равно» / «После сброса») and «Claude уже работает здесь» («Да, в worktree») come as buttons; the outcome replaces the message. Below the projects: running background tasks with 📜 n (the last 12 log steps) and ⏹ n («Остановить?» first), the last three finished with their PR link (a link only). Over the shared bot starting and stopping need «Задачи через общий бот» (module page). Projects in buttons by an 8-hex FNV-1a of the path. 🚀 is in the default bottom menu (🏠 🤖 / 🚀 ⏳ / 📊 🧹 / ❓). Only Claude Code: other agents open in Terminal on the Mac with the task on the clipboard, useless from a phone (spec §8). 14 new strings in 12 languages.
Checked: scripts/check.sh green; 5 new tests (`TelegramTasksTests`: project keys, the screen with projects and runs, locked over the shared bot, the task shown back and the launcher's questions, log tail and stop), updated menu and route tests.
Left: not tried live — start a small task from the phone and stop it.

## 2026-11-03 — menu bar ☕ follows the «Не спать» switch (branch `fix/keep-awake-cup-follows-switch`)

Done: after #248 the cup stayed orange whatever the panel switch said — the switch is only the manual hold, and the rule «Пока работает Claude» kept the Mac awake (and the cup lit) all the time. Oleh chose: the cup shows only while the switch is on (orange, label colour when level colours are off) and is gone when it is off; rules no longer light it. New `MenuBarData.keepAwakeSwitchedOn` (= manual hold); the tooltip still says «Mac не засыпает» from the real reason. Settings description reworded in 12 languages.
Checked: `xcodebuild test` — 462 green (`KeepAwakeTests.menuBarCup`: off, rule alone, switch on, colours off). Installed build: menu bar screenshot with the switch off while the Claude rule held the Mac — no cup.
Left: the switch-on state not seen live (the panel switch wasn't clicked by the agent).

## 2026-11-03 — Telegram stage 2: sessions, permission requests, limits (branch `feat/telegram-sessions-limits`)

Done: 🤖 Сессии (waiting first, then working; project, agent, what it waits for or does) with the open permission requests numbered ✅ n / ❌ n / ℹ️ n; ⏳ Лимиты (every AI service of «Лимиты AI» with a ▓░ bar per window, the reset, «кончится к …», a switch for limit alerts to Telegram). Requests: with «Присылать запросы разрешений в Telegram» on (now also «Запросы разрешений в этот бот» on the module page) the Mac where Claude asks sends each request at once with «Разрешить / Отклонить / Подробнее»; answered anywhere, the message loses its buttons and says how; `TelegramApprovals` steps aside while the module does this (its section says so). Own bot: buttons only from the Mac that reads the bot; shared bot: the relay now sends a press back to the Mac that sent the message (`msg:<chat>:<id>`, the last 1000 per chat), and answering needs «Ответы на запросы через общий бот». The default bottom menu now has 🏠 🤖 / ⏳ 📊 / 🧹 ❓ (custom menus keep theirs; the new screens are in «Меню в боте»). Spec §2/§3/§8, REFERENCE. 17 new strings in 12 languages.
Checked: scripts/check.sh green; 4 new Swift tests (`TelegramSessionsLimitsTests`: order and requests, answers locked, request message and its end, details, limits screen and bars), updated menu and route tests; 1 new relay test (a press returns to the sending Mac, falls back after unpairing).
Left: not tried live (needs a real permission request in a Claude session). The relay change needs a redeploy once the Worker is deployed.

## 2026-11-03 — Telegram: the bot's menu set up by each person (branch `feat/telegram-custom-menu`)

Done: Oleh asked for a menu each user sets up. `BotMenuConfig` (item ids `screen:<name>` / `cmd:<quick command id>`, 2 or 3 per row) in `TelegramBotSettings.menu`, a profile's own in `profileMenus`; `BotMenu` builds the keyboard from it (🏠 always first if left out, deleted commands drop out, equal titles numbered). Settings → Modules → Telegram → «Меню в боте»: switches, ↑ ↓, columns, «Меню для» всех профилей / профиля with «Своё меню у этого профиля», «Быстрые команды через общий бот», «Обновить меню в Telegram». In the bot: ❓ → ⚙️ «Настроить меню» (toggles, columns, «Готово»). A quick command from the menu runs on the Mac (`QuickToolsController.runForBot`, the process part shared with `run`) and replies with its result; «Спрашивать перед запуском» asks in the chat; over the shared bot only with the switch on, always asking. A profile change with a different menu sends 🏠 with it. Spec §2/§3, REFERENCE. 25 new strings in 12 languages. #247 (merged): the desktop CI no longer runs on Mac string changes while Windows/Linux are postponed.
Checked: scripts/check.sh green; 6 new tests (menu from a config with commands, home can't be removed and order moves, per-profile menus, ⚙️ screen, command confirmation and result, new routes and tampered data).
Left: not tried live in Telegram yet — set a menu in Settings, then «Обновить меню в Telegram».

## 2026-11-03 — «Не спать» on/off in the menu bar (branch `feat/keep-awake-indicator`)

Done: the «Не спать» menu bar element no longer disappears when off. On: filled `cup.and.saucer.fill` in orange (label colour when «цвет по уровню» is off); off: outline `cup.and.saucer` in the secondary colour. New segment `.tintedSymbol(name, tint)` drawn by `MenuBarRenderer`; the element only shows when the module is on (unchanged). Settings description of the element reworded in 12 languages.
Checked: `xcodegen generate` + `xcodebuild test` — 462 green (`KeepAwakeTests.menuBarCup` covers on, off and colours off).
Left: not looked at live in the real menu bar.

## 2026-11-03 — Telegram: the shared bot through a Cloudflare Worker (branch `feat/telegram-shared-bot`)

Done: Oleh decided a newcomer shouldn't have to make a bot at @BotFather. Spec §7: one shared bot run by a relay on Cloudflare Workers, «Свой бот» stays as the private option; stage 1b. `relay/telegram/` (plain JavaScript, no build): `src/hub.js` (register, key hash only, pairing codes 10 min, chat ↔ Macs, the answering Mac, `/macs` switch, queue for an offline Mac 24 h with one «💤 asleep» notice per 10 min, a Mac's calls limited to five methods into its own chat and 30 a minute, strangers get a welcome), `src/index.js` (Worker + one SQLite Durable Object with WebSocket Hibernation, webhook secret, admin setup of webhook / commands / descriptions in en and ru), `README.md` with the deploy steps, `.github/workflows/relay.yml`. Mac: `TelegramRelay` (register once, key in the Keychain `telegram-relay`, one WebSocket with pings and reconnect, calls and pairing over it), `TelegramBotController` talks through one `api()` to either bot, «Как подключаться» on the module page, «Подключить Telegram» / «Отключить», greeting after pairing; `Telegram.notify` and the weekly summary go through the shared bot while paired. Also fixed: the bottom menu (#244) was never sent — a message with the menu has no inline buttons, and `send` skipped `reply_markup` then. 15 new strings in 12 languages.
Checked: scripts/check.sh green (now also runs the relay's tests); 10 relay tests under Node, 4 new Swift tests (`TelegramRelayTests`); `wrangler deploy --dry-run` builds; end-to-end against `wrangler dev` with fake secrets: register, unknown key refused, ping/pong, pairing by code, update routed, forbidden method 403, update queued while offline and delivered on reconnect.
Left: Oleh deploys the Worker and creates the shared bot; then its address goes into `TelegramRelay.defaultURL` (until then the module shows only «Свой бот»). Permission answers and tasks over the shared bot need a Mac-side switch (stages 2–3). A privacy note on the site.

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
