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
  with an internal battery) — the Mac mini answers, the MacBook Air doesn't (Oleh, §9). Only a Mac with it on reads
  updates; the other one still *sends* notifications (sending does not conflict). If Telegram answers
  409 («another getUpdates»), the page says «Этого бота уже читает другой Мак или программа» and the loop waits 60 s
  between tries; nothing breaks. The setting is per Mac: it is not part of the settings export.
- **Migration**, never automatic (an old reader might still be running):
  - Oleh took the **`_daily-report` bot** (§9) with «Взять бота из _daily-report», so `report.py` (the morning
    report, «Отчёт сейчас», the bot's `/report`) sends into the same chat. With another bot, `report.py` keeps
    sending through the `config.json` one until its `telegram.bot_token` is replaced by hand
    (`report.py --setup-telegram` keeps a token that is already there); the report screen then says so.
  - for others: no token yet and `_daily-report/config.json` has one → «Взять бота из _daily-report» copies its token
    and chat into the Keychain and the settings.
  - an approvals token in `telegram-approvals` → «Взять бота для ответов» moves it to `telegram-bot` (stage 2; until
    then requests keep going through it as before).
  - until migrated, the old ones keep working exactly as today: `Telegram.credentials` falls back to
    `config.json`, and `TelegramApprovals` keeps its own bot. If both tokens are the same bot, `TelegramApprovals`
    stops its own `getUpdates` and the module's loop hands it the ✅/❌ presses.
- `bot.py` is retired (§9): its commands live here; Oleh deletes `bot.py` and `install-bot.sh` himself.

## 2. Menu

- `setMyCommands` on connect: `/menu`, `/report`, `/status`, `/clean`, `/help` (the old `bot.py` commands keep their
  meaning, so the habit carries over). The Menu button shows this list (Telegram's default «commands» button).
- **The menu at the bottom** (a persistent reply keyboard, `BotMenu`): 🏠 Главная · 📊 Отчёты / 🧹 Мак · ❓ Команды
  always sit under the chat instead of the keyboard. A press sends its title, the bot shows that screen as a new message
  at the bottom and deletes the press and the screens opened before it, so the chat keeps one or two. A message carries
  either inline buttons or this menu, so 🏠 opened from the menu carries the menu (and sets it again) instead of its
  inline buttons; while a report or cleanup still edits a screen, nothing is deleted. Later stages add their sections
  to it (🤖 Сессии, 🚀 Задача, ⏳ Лимиты, ⚙️ Настройки).
- **The menu is the person's own** (Oleh, 2026-11-03): Settings → Modules → Telegram → «Меню в боте» — which buttons
  (the screens, and any quick command from the library as «▶️ <name>»), their order (↑ ↓), 2 or 3 in a row; a profile
  can have its own menu («Своё меню у этого профиля»), and when the profile changes to one with a different menu, the
  Mac sends 🏠 with it. The same switches are in the bot: ❓ → ⚙️ «Настроить меню» (order stays a Settings thing).
  🏠 is always there; a deleted command drops out; equal titles get « 2». Stored in `TelegramBotSettings.menu` /
  `profileMenus` (`BotMenuConfig`: item ids `screen:<name>` / `cmd:<id>`, columns). A quick command from the menu runs
  on the Mac (`QuickToolsController.runForBot`) and its result comes to the chat; «Спрашивать перед запуском» asks there
  first (`run:<id>`). Over the shared bot commands run only with «Быстрые команды через общий бот» on, and then always ask.
- `/menu` (and `/start`) sends 🏠 with the menu at the bottom. **Each section is one message edited in place**
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
| `nav:menu`, `mt:<item id>`, `mc:2`/`mc:3`, `md` | ⚙️ «Меню»: show, switch a button, buttons in a row, «Готово» (sends 🏠 with the menu) |
| `run:<command id>` | run a quick command after «Запустить?» |

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

## 7. The shared bot (Cloudflare Worker)

Decided by Oleh 2026-11-03: making a bot at @BotFather scares a newcomer away, so AI Hub Bar gets **one shared bot** run
by a small relay on Cloudflare Workers; «Свой бот» (§1) stays for those who want nothing in between. Code:
`relay/telegram/` (the Worker, plain JavaScript, no build step), `AIHubBar/Services/TelegramRelay.swift` (the Mac side).

**Why a relay.** All of a bot's updates go to whoever holds its token. The token can't ship inside the app (anyone could
pull it out and read every user's chat or press «✅» on their Macs), so it lives only in the Worker's secrets, and each
Mac talks to the Worker instead of Telegram.

**How it works.**
- Telegram → Worker: a webhook (`setWebhook` with a secret header). The Worker hands the update to one Durable Object
  (`Hub`, SQLite-backed, free plan), which knows chat ↔ Macs.
- Mac ↔ Worker: one WebSocket per Mac (`GET /v1/connect`, `Authorization: Bearer <device key>`), kept by the Durable
  Object with the Hibernation API — idle sockets cost nothing, an update arrives at once. Over it: updates to the Mac,
  and the Mac's calls (`sendMessage`, `editMessageText`, `deleteMessage`, `answerCallbackQuery`) with their replies.
  Updates for a Mac that is offline (asleep) wait in the Durable Object for 24 hours; the Mac's 30-minute rule (§4)
  still drops old ones.
- **Register:** the Mac posts `POST /v1/devices` once and keeps the device key in the Keychain (`telegram-relay`); the
  Worker stores only its SHA-256.
- **Pairing in one tap:** «Подключить Telegram» asks the Worker (over the socket) for a code; the app opens
  `https://t.me/<bot>?start=<code>`; «Start» binds that chat to this Mac. The code lives 10 minutes.
- **Several Macs:** a chat can have several Macs; one **answers** (gets the updates), all can **send** (notifications).
  The last paired one answers; «Этот Мак отвечает боту» on another one takes over, and `/macs` in the bot (answered by
  the Worker itself) lists them with buttons to switch. This replaces the 409 dance of §1.
- **What the Mac may do:** only the four methods above, always into its own chat (the Worker sets `chat_id`), at most
  30 calls a minute. Commands, the bot's name and description are set once by the Worker (`POST /admin/setup`).
- **Strangers:** `/start` without a code gets a short «install AI Hub Bar» answer with the site link; anything else
  from an unpaired chat is ignored.

**Privacy and safety.**
- The Worker sees messages in transit (Telegram bots are never end-to-end) but stores none: only chat id ↔ device ids,
  pairing codes, and the queue of undelivered updates (deleted on delivery or after 24 h). It logs counts and errors,
  never text. The site gets a privacy note.
- A compromised Worker could drive every paired Mac. So over the shared bot the Mac allows reports, screens and
  cleanup (asks first); permission answers (stage 2) and tasks (stage 3) need a switch on the Mac, off by default.
- «Отключить» on the Mac unpairs it (the Worker forgets the device).

**On the Mac.** The module page gets «Как подключаться»: **«Общий бот (быстро)»** — the default when no own token is
set — with «Подключить Telegram», the bot's name, the paired chat and «Отключить»; or **«Свой бот (приватно)»** — §1 as
it is. The rest of the module (screens, menu, reports) works the same over either. Notifications (`Telegram.notify`,
the weekly summary) go through the shared bot when it is paired.

**Cost.** Workers Free: 100 000 requests a day; a webhook update and each WebSocket message batch count, idle sockets
don't. Enough for hundreds of users; beyond that Workers Paid is $5 a month.

**Oleh does once** (`relay/telegram/README.md`): make the bot at @BotFather (its name is his call), `npx wrangler
login`, `npx wrangler secret put BOT_TOKEN` / `WEBHOOK_SECRET` / `ADMIN_SECRET`, `npx wrangler deploy`, then
`POST /admin/setup`. The Worker's address goes into the app (`TelegramRelay.defaultURL`) in a one-line follow-up.

## 8. Stages (one PR each)

1. **Connection, 🏠, reports, cleanup.** Token, chat binding, «Этот Мак отвечает боту», migration from `_daily-report`,
   the poll loop with 409 and stale handling, `setMyCommands`, 🏠 / 📊 / 🧹 / help, `/report`, `/status`, `/clean`.
1b. **The shared bot** (§7): the Worker, pairing, «Общий бот / Свой бот», notifications through it.
2. **Sessions and requests + notification settings.** 🤖 screen, requests through this bot with «Подробнее», moving the
   approvals bot here, which events come.
3. **Tasks and run control.** 🚀: project → agent → text → background (`LaunchController`), stop, log tail, PR link.
4. **Settings in the bot, limits, Mac.** ⚙️ (events, quiet hours, mute 1 h, morning report time), ⏳ every service
   with forecast and 80/90 % alerts, 🧹 «Не спать».

## 9. Oleh's calls

Asked and answered 2026-11-03:

- **Merging PRs from the phone — no.** The bot shows a PR and its CI with a link; merging stays in GitHub.
- **Which Mac answers — the Mac mini.** In the app: desktops answer by default, laptops don't (§1); either can be
  switched on the module's page.
- **`bot.py` — retired.** Oleh removes it (and `install-bot.sh`) himself; `report.py`, `cleanup.py` and the morning
  report stay.
- **The one bot — first a new one, then (the same day) the `_daily-report` bot**: Oleh connected it with «Взять бота из
  _daily-report», so reports, the menu and notifications share one chat. The approvals bot keeps working apart until
  stage 2 moves requests here.
- **A menu always at the bottom** instead of typing `/` (asked 2026-11-03): §2, «The menu at the bottom».
- **A shared bot for everyone, through Cloudflare Workers** (2026-11-03): §7; «Свой бот» stays as the private option.
