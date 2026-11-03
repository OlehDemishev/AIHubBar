# Shared Telegram bot — Cloudflare Worker relay

The relay behind AI Hub Bar's shared bot (docs/specs/SPEC-telegram.md §7). Telegram sends the bot's updates here; one
Durable Object knows which Mac belongs to which chat and passes each update to the Mac that answers, over that Mac's
WebSocket. The bot's token is only in this Worker's secrets — never in the app.

- `src/hub.js` — the logic (pairing, routing, what a Mac may call), plain JavaScript without Cloudflare.
- `src/index.js` — the Worker and the `Hub` Durable Object (WebSocket Hibernation API).
- `src/texts.js` — what the bot says itself (Russian / English).
- `test/` — `npm test` (Node 22, no packages needed).

## Deploy (once)

1. Make the bot: in Telegram, @BotFather → `/newbot` → name and username (e.g. `AIHubBarBot`). Copy the token.
2. Sign in to Cloudflare (a free account is enough):
   ```bash
   cd relay/telegram && npx wrangler@4.151.0 login
   ```
3. Secrets — the token, and two long random strings of your own (e.g. `openssl rand -hex 32`):
   ```bash
   npx wrangler@4.151.0 secret put BOT_TOKEN
   npx wrangler@4.151.0 secret put WEBHOOK_SECRET
   npx wrangler@4.151.0 secret put ADMIN_SECRET
   ```
4. Deploy: `npm run deploy`. Wrangler prints the address, `https://aihubbar-telegram.<account>.workers.dev`.
5. Set the webhook, commands and description (also after changing `src/texts.js`):
   ```bash
   curl -X POST -H "Authorization: Bearer <ADMIN_SECRET>" https://aihubbar-telegram.<account>.workers.dev/admin/setup
   ```
   The answer lists the bot's username and HTTP 200 for each step.
6. Put the address into the app: `TelegramRelay.defaultURL` (`AIHubBar/Services/TelegramRelay.swift`). Until then a
   Mac can use it with `defaults write com.demishev.claudepult telegramRelayURL https://…workers.dev`.

## What it keeps

Chat id ↔ device ids, each device's name and key hash, pairing codes (10 minutes), and updates for a Mac that is
offline (deleted on delivery or after 24 hours). No message text is logged. Limits: a Mac may call only
`sendMessage`, `editMessageText`, `editMessageReplyMarkup`, `deleteMessage`, `answerCallbackQuery`, into its own chat,
30 a minute.
