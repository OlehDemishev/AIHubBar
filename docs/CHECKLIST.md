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
| Waiting notification once | **Oleh** |

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
| Widgets | Not built — see DECISIONS |

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
