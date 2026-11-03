# «Telegram» — one bot with its own menu

Decided by Oleh 2026-11-03: the Telegram bot becomes one bot inside AI Hub Bar, an optional AI module «Telegram», driven
from a menu in the bot itself — settings, answers, control, reports. It replaces three pieces that work apart today:

| Today | What it does | Where |
|---|---|---|
| send-only bot | results of background runs, limit thresholds, weekly summary, calendar, PR alerts | `Services/Telegram.swift`; token `telegram-bot` in the Keychain + `telegramChatID`, else `_daily-report/config.json` |
| approvals bot | ✋ permission requests with ✅/❌ buttons, read with `getUpdates` | `Services/TelegramApprovals.swift`; token `telegram-approvals` |
| `_daily-report/bot.py` | `/report`, `/status`, `/clean`, `/help` by running `report.py` / `cleanup.py` | outside this repository; no launchd agent, not running |

Two readers of one token take each other's updates (`getUpdates` answers HTTP 409 to the second one), and Oleh has two
Macs (Mac mini, MacBook Air). So: **one bot, one reader, one Mac answers.**

Code: `AIHubBar/Models/TelegramBot.swift` (updates, callback data, screens — pure, with tests),
`AIHubBar/Services/TelegramBotController.swift` (`TelegramBotController`: the poll loop, the chat, actions),
`AIHubBar/Modules/TelegramModule.swift` (the module and its Settings page).

## 1. Connection

- **The bot is the person's own**, made at @BotFather. The token lives only in the Keychain (`ClaudePult API key` /
  `telegram-bot`, the account the send-only bot already uses). It is typed on the module's page; nobody else types it.
- **The chat is bound by a first message.** «Привязать чат» on the module's page makes a one-time code and opens
  `https://t.me/<bot>?start=<code>`; Telegram sends `/start <code>` and that private chat becomes the bot's chat
  (`telegramChatID`). The code lives 10 minutes and only while the page waits for it. A chat id already set (Settings
  or `_daily-report`) is taken as bound — nothing to do for an existing setup.
- **Only that chat is answered.** Updates from any other chat, groups and channels are dropped without a reply (a
  stranger who finds the bot learns nothing); `from.id` must equal the chat for a private chat.
- **«Этот Мак отвечает боту»** (`telegramBot.answersHere`): by default on for a desktop Mac and off for a laptop (one
  with an internal battery) — the Mac mini answers, the MacBook Air doesn't (Oleh, §8). Only a Mac with it on reads
  updates; the other one still *sends* notifications (sending does not conflict). If Telegram answers
  409 («another getUpdates»), the page says «Этого бота уже читает другой Мак или программа» and the loop waits 60 s
  between tries; nothing breaks. The setting is per Mac: it is not part of the settings export.
- **Migration**, never automatic (an old reader might still be running):
  - Oleh chose a **new bot** (§8): its token is typed on the page. `report.py` (the morning report, «Отчёт сейчас»,
    the bot's `/report`) still sends through the `config.json` bot until that file points at the new bot
    (`python3 report.py --setup-telegram`, done by Oleh while the module is off — it reads the bot's updates too).
    When the two tokens differ, the report screen says the text comes from the `_daily-report` bot.
  - for others: no token yet and `_daily-report/config.json` has one → «Взять бота из _daily-report» copies its token
    and chat into the Keychain and the settings.
  - an approvals token in `telegram-approvals` → «Взять бота для ответов» moves it to `telegram-bot` (stage 2; until
    then requests keep going through it as before).
  - until migrated, the old ones keep working exactly as today: `Telegram.credentials` falls back to
    `config.json`, and `TelegramApprovals` keeps its own bot. If both tokens are the same bot, `TelegramApprovals`
    stops its own `getUpdates` and the module's loop hands it the ✅/❌ presses.
- `bot.py` is retired (§8): its commands live here; Oleh deletes `bot.py` and `install-bot.sh` himself.

## 2. Menu

- `setMyCommands` on connect: `/menu`, `/report`, `/status`, `/clean`, `/help` (the old `bot.py` commands keep their
  meaning, so the habit carries over). The Menu button shows this list (Telegram's default «commands» button).
- `/menu` (and `/start`) sends the 🏠 screen as a new message. **Each section is one message edited in place**
  (`editMessageText`): a button changes the message it sits on, it never adds a new one. Results that are not a screen
  (a report, the cleanup output) come as new messages.
- Screens (✓ = stage 1):

| Screen | Shows | Buttons |
|---|---|---|
| 🏠 Главная ✓ | Mac name; Claude session and week %, reset; sessions working / waiting; background runs | the sections, 🔄 |
| 📊 Отчёты ✓ | what each report does, a running one | ✨ Отчёт с AI (since the morning report), ⚡ Быстрая сводка, AI for 1 / 3 / 24 h |
| 🧹 Мак ✓ | free disk; stage 4: «Не спать» | 🔍 Что удалит очистка, 🧹 Очистить (asks first) |
| 🤖 Сессии (2) | waiting first, then working; each with project and what it does | ✅ / ❌ / «Подробнее» on a request |
| 🚀 Задача (3) | project → agent → text (the next message) → background | ⏹ stop a run, 📜 log tail, the PR link (a link only: PRs are not merged from the bot) |
| ⏳ Лимиты (4) | every AI service from «Лимиты AI», forecast | alerts 80 / 90 % on/off |
| ⚙️ Настройки (4) | which events come, quiet hours, mute 1 h, morning report time | toggles; written to the app's settings, the same switches as in Settings |

- `/report [N]` — AI report since the morning report (10:00, `hours_since_morning` as in `bot.py`) or for N hours
  (0.25…168); `/status [N]` — the quick one without AI; `/clean check` — what cleanup would delete; `/clean` — asks
  first, then cleans. They run `report.py` / `cleanup.py` in the profile's `_daily-report` folder, the way the panel's
  commands do; one at a time («⏳ Уже идёт другая задача»). `report.py` sends the report itself through the
  `config.json` bot; the screen says «⏳ Готовлю…», then «✅ Отчёт отправлен» or the error's last lines.
- `/help` — the bot's commands; «📖 Все команды Мака» sends `_daily-report/help.txt` when it exists.

## 3. Callback data

At most 64 bytes, ASCII, `<verb>[:<arg>…]`. Unknown or malformed data re-renders 🏠 with «Кнопка устарела».

| Data | Meaning |
|---|---|
| `nav:home`, `nav:reports`, `nav:mac`, `nav:help` (later `nav:sessions`, `nav:task`, `nav:limits`, `nav:settings`) | show a screen in this message |
| `rep:ai`, `rep:quick`, `rep:ai:<hours>` | run a report (hours an integer 1…168) |
| `cln:check`, `cln:ask`, `cln:run` | cleanup: dry run; the confirmation screen; the confirmed run |
| `help:all` | send `help.txt` |
| `allow:<id>`, `deny:<id>` | answer a permission request (the approvals bot's format, kept) |

Dangerous actions are two steps: the button opens a confirmation (`cln:ask` → «Удалить сборки и сбросить
симуляторы?» ✅ Да / Отмена), and only the confirmation's own data (`cln:run`) acts.

## 4. Safety

- **Old commands are skipped.** A message older than 30 minutes (`date`; the Mac was asleep) is dropped with no action.
  Button presses carry no time, so after a gap of more than 30 minutes since the last successful read, the first batch's
  presses only navigate: actions answer «Устарело — откройте меню заново» (`answerCallbackQuery`).
- Dangerous actions confirm first (§3). Stage 3: stopping a run confirms too; starting a task shows the task back first.
- No secrets in logs: the token is only in the request URL, and errors log the method and HTTP code only. Script output
  goes through `CommonCommand.redactingTokens`. Message texts and task texts are not logged.
- All user text in messages is HTML-escaped (`RunMessage.escape`).

## 5. State

- In memory (`TelegramBotController`): the update offset, the last successful read, the pending binding code, the job in
  progress, the bot's name, the status line for the page. Nothing is written to disk besides the settings below.
- After a restart the offset starts empty: Telegram re-sends unconfirmed updates, and §4 drops the old ones.

## 6. Settings

- Module page: token (save / delete), bot name, «Привязать чат» / the bound chat with «Отвязать», «Этот Мак отвечает
  боту», «Проверить» (a test message), the status line, migration buttons (§1). Settings → General → Telegram becomes a
  pointer to this page (the token was there).
- `AppSettings.telegramBot` (`TelegramBotSettings`, Codable): `answersHere`. Stage 2+: `events` (which notifications
  come — today's `TelegramToggle`s, the same switches as the modules' «Telegram» chips), `quietFrom`/`quietTo`,
  `mutedUntil`. Stage 4: the morning report time (needs `_daily-report`'s launchd agent; until then shown, not changed).
- Notifications keep going out while the module is off (the modules' «Telegram» chips decide); the module adds the
  menu and the answers.

## 7. Stages (one PR each)

1. **Connection, 🏠, reports, cleanup.** Token, chat binding, «Этот Мак отвечает боту», migration from `_daily-report`,
   the poll loop with 409 and stale handling, `setMyCommands`, 🏠 / 📊 / 🧹 / help, `/report`, `/status`, `/clean`.
2. **Sessions and requests + notification settings.** 🤖 screen, requests through this bot with «Подробнее», moving the
   approvals bot here, which events come.
3. **Tasks and run control.** 🚀: project → agent → text → background (`LaunchController`), stop, log tail, PR link.
4. **Settings in the bot, limits, Mac.** ⚙️ (events, quiet hours, mute 1 h, morning report time), ⏳ every service
   with forecast and 80/90 % alerts, 🧹 «Не спать».

## 8. Oleh's calls

Asked and answered 2026-11-03:

- **Merging PRs from the phone — no.** The bot shows a PR and its CI with a link; merging stays in GitHub.
- **Which Mac answers — the Mac mini.** In the app: desktops answer by default, laptops don't (§1); either can be
  switched on the module's page.
- **`bot.py` — retired.** Oleh removes it (and `install-bot.sh`) himself; `report.py`, `cleanup.py` and the morning
  report stay.
- **The one bot — a new one** from @BotFather. The approvals bot and the `_daily-report` bot keep working until moved
  (§1); pointing `config.json` at the new bot puts the reports into the same chat.
