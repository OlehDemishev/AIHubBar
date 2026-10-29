# Status

<!-- summary:start -->
**Stage:** Stage 1 of 7 done — skeleton (menu bar icon, empty panel, Settings with login item)
**Updated:** 2026-10-29

**Now:**
- nothing in progress

**Next:**
- Stage 2 — Projects: run `report.py --json`, models, project list with health/branch/STATUS, expand, open in Terminal/Finder/GitHub, periodic refresh, file logs in ~/Library/Logs/ClaudeBar
- Stage 3 — Terminal launch: three Claude commands, prompts, AppleScript, Automation permission, worktree when the folder is busy
- Stage 4 — Sessions: hook script, install/remove hooks in ~/.claude/settings.json with backup, sessions panel, states, "waiting" notification, icon badge
- Stage 5 — Background mode: `claude -p` with permissions from spec 2.4, logs, stop, time limit, notifications and Telegram
- Stage 6 — Common commands and disk: report, summary, latest report, cleanup (check/run), disk indicator
- Stage 7 — Polish: Help window + help.txt, manual run of all scenarios, README update, app icon

**Needs Oleh:**
- open the panel and Settings once and confirm they look right (automation cannot see the app's windows); turn on «Запускать при входе в систему» if wanted — it is left off
<!-- summary:end -->

## 2026-10-29 — Stage 1: skeleton (branch `main`)

Done: git repo and private GitHub repo `OlehDemishev/ClaudeBar`; `project.yml` (XcodeGen, macOS 14+, Swift 6, LSUIElement, no sandbox, ad-hoc signing); menu bar icon (SF Symbol `sparkle`) with a `.window` panel containing «Настройки…» and «Выход»; Settings window with the «Запускать при входе в систему» toggle via `SMAppService.mainApp`; headless `--login-item status|on|off`; `scripts/build-and-install.sh`; README, DECISIONS, this STATUS. First commit pushed straight to `main` (exception allowed by the spec).
Checked: `scripts/build-and-install.sh --test` — 3 Swift Testing tests green, Release build, installed to ~/Applications, app running. Menu bar icon seen on a screenshot, disappears when the app quits, icon highlights on click (the panel window itself is hidden from computer-use screenshots). Login item: `--login-item on` → `enabled`, `off` → `disabled`. CI not set up; all checks run locally.
Left: panel contents and Settings window not inspected visually (the app's windows are hidden from computer-use screenshots); actual start at login not tested (needs a re-login). Environment differs from the spec (macOS 27.2, Xcode 27.1) — see DECISIONS.md.
