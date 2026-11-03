// The relay's logic without Cloudflare: `node --test test/` (docs/specs/SPEC-telegram.md §7). No real tokens here.

import { test } from "node:test";
import assert from "node:assert/strict";
import { HubCore, CALLS_PER_MINUTE, CODE_TTL_MS } from "../src/hub.js";

function makeHub() {
  const data = new Map();
  const storage = {
    async get(key) { return structuredClone(data.get(key)); },
    async put(key, value) { data.set(key, structuredClone(value)); },
    async delete(key) { return data.delete(key); },
    async list({ prefix }) { return new Map([...data].filter(([k]) => k.startsWith(prefix)).sort()); },
  };
  const calls = [];
  const online = new Set();
  const sent = [];
  let clock = 1_700_000_000_000;
  let counter = 0;
  const hub = new HubCore({
    storage,
    telegram: async (method, params) => {
      calls.push({ method, params });
      if (method === "getMe") return { status: 200, body: { ok: true, result: { username: "AIHubBarTestBot" } } };
      return { status: 200, body: { ok: true, result: { message_id: 1 } } };
    },
    sockets: { send: (id, message) => { if (!online.has(id)) return false; sent.push({ id, message }); return true; } },
    now: () => clock,
    random: (n) => Uint8Array.from({ length: n }, () => (counter++ * 37 + 11) % 256),
    siteURL: "https://example.com",
  });
  return { hub, data, calls, online, sent, tick: (ms) => { clock += ms; } };
}

let updateID = 100;
const message = (chat, text, extra = {}) => ({
  update_id: updateID++,
  message: { message_id: 5, text, chat: { id: chat, type: "private" }, from: { id: chat, language_code: "ru" }, ...extra },
});

async function paired(t, name = "Mac mini", chat = 42) {
  const device = await t.hub.register(name);
  const code = (await t.hub.pair(device.device_id, 1)).code;
  await t.hub.onUpdate(message(chat, `/start ${code}`));
  return device;
}

test("register keeps only the key's hash and authenticates by it", async () => {
  const t = makeHub();
  const { device_id, device_key } = await t.hub.register("Mac\u0000 mini");
  assert.equal((await t.hub.authenticate(`Bearer ${device_key}`)), device_id);
  assert.equal(await t.hub.authenticate("Bearer wrong-key-wrong-key-wrong"), null);
  assert.equal(await t.hub.authenticate(device_key), null);
  const stored = JSON.stringify([...t.data]);
  assert.ok(!stored.includes(device_key));
  assert.equal(t.data.get(`dev:${device_id}`).name, "Mac mini");
});

test("pairing binds the chat; the link carries the code", async () => {
  const t = makeHub();
  await t.hub.setup("https://relay.example/telegram", "secret");
  const device = await t.hub.register("Mac mini");
  const pair = await t.hub.pair(device.device_id, 7);
  assert.equal(pair.id, 7);
  assert.match(pair.link, /^https:\/\/t\.me\/AIHubBarTestBot\?start=[a-z2-9]{12}$/);
  t.online.add(device.device_id);
  await t.hub.onUpdate(message(42, `/start ${pair.code}`));
  const hello = await t.hub.hello(device.device_id);
  assert.deepEqual([hello.chat, hello.answering, hello.macs], ["42", true, 1]);
  assert.equal(t.sent.at(-1).message.type, "hello");
  // The code is used up.
  await t.hub.onUpdate(message(43, `/start ${pair.code}`));
  assert.match(t.calls.at(-1).params.text, /устарела/);
  assert.equal(t.data.get("chat:43"), undefined);
});

test("an expired code doesn't bind", async () => {
  const t = makeHub();
  const device = await t.hub.register("Mac");
  const { code } = await t.hub.pair(device.device_id, 1);
  t.tick(CODE_TTL_MS + 1);
  await t.hub.onUpdate(message(42, `/start ${code}`));
  assert.equal((await t.hub.hello(device.device_id)).chat, null);
});

test("strangers get the welcome, groups and other senders nothing", async () => {
  const t = makeHub();
  await t.hub.onUpdate(message(99, "/start"));
  assert.match(t.calls.at(-1).params.text, /example\.com/);
  const before = t.calls.length;
  await t.hub.onUpdate(message(99, "/clean"));
  await t.hub.onUpdate({ update_id: 1, message: { text: "/start abcdefghijkm", chat: { id: -100, type: "group" }, from: { id: 42 } } });
  await t.hub.onUpdate({ update_id: 2, message: { text: "/menu", chat: { id: 42, type: "private" }, from: { id: 43 } } });
  assert.equal(t.calls.length, before);
});

test("updates go to the answering Mac, or wait while it sleeps", async () => {
  const t = makeHub();
  const device = await paired(t);
  t.online.add(device.device_id);
  const update = message(42, "/menu");
  await t.hub.onUpdate(update);
  assert.deepEqual(t.sent.at(-1), { id: device.device_id, message: { type: "update", update } });

  t.online.delete(device.device_id);
  const late = message(42, "/report");
  await t.hub.onUpdate(late);
  assert.match(t.calls.at(-1).params.text, /Mac mini не на связи/);
  // One sleep notice per 10 minutes.
  const count = t.calls.length;
  await t.hub.onUpdate(message(42, "/status"));
  assert.equal(t.calls.length, count);
  const connect = await t.hub.onConnect(device.device_id);
  assert.deepEqual(connect.map((m) => m.type), ["hello", "update", "update"]);
  assert.equal(connect[1].update.message.text, "/report");
  assert.deepEqual((await t.hub.onConnect(device.device_id)).map((m) => m.type), ["hello"]);
});

test("a Mac's calls are limited to its chat and a few methods", async () => {
  const t = makeHub();
  const device = await paired(t);
  const call = (method, params) => t.hub.onMessage(device.device_id, { type: "call", id: 3, method, params });
  const [reply] = await call("sendMessage", { chat_id: 999, text: "hi" });
  assert.deepEqual([reply.type, reply.id, reply.status], ["reply", 3, 200]);
  assert.equal(t.calls.at(-1).params.chat_id, "42");
  assert.equal((await call("setWebhook", { url: "https://evil" }))[0].status, 403);
  assert.equal((await call("getUpdates", {}))[0].status, 403);
  await call("answerCallbackQuery", { callback_query_id: "c", chat_id: 999, url: "https://evil" });
  assert.deepEqual(t.calls.at(-1).params, { callback_query_id: "c" });
  for (let i = 0; i < CALLS_PER_MINUTE; i++) await call("deleteMessage", { message_id: i });
  assert.equal((await call("sendMessage", { text: "x" }))[0].status, 429);
  t.tick(61_000);
  assert.equal((await call("sendMessage", { text: "x" }))[0].status, 200);
});

test("an unpaired Mac can't send", async () => {
  const t = makeHub();
  const device = await t.hub.register("Mac");
  const [reply] = await t.hub.onMessage(device.device_id, { type: "call", id: 1, method: "sendMessage", params: { text: "x" } });
  assert.equal(reply.status, 409);
  assert.deepEqual(await t.hub.onMessage("nobody", { type: "call", id: 1, method: "sendMessage" }), []);
});

test("several Macs: the last paired answers, another can take over, /macs switches", async () => {
  const t = makeHub();
  const mini = await paired(t, "Mac mini");
  const air = await paired(t, "MacBook Air");
  t.online.add(mini.device_id).add(air.device_id);
  assert.equal((await t.hub.hello(air.device_id)).answering, true);
  assert.equal((await t.hub.hello(mini.device_id)).macs, 2);

  const [state] = await t.hub.onMessage(mini.device_id, { type: "answer", on: true });
  assert.equal(state.answering, true);
  assert.equal((await t.hub.hello(air.device_id)).answering, false);

  await t.hub.onUpdate(message(42, "/macs"));
  const list = t.calls.at(-1);
  assert.deepEqual(list.params.reply_markup.inline_keyboard.map((row) => row[0].text), ["✅ Mac mini", "MacBook Air"]);
  await t.hub.onUpdate({
    update_id: 9,
    callback_query: { id: "cb", data: `relay:use:${air.device_id}`, from: { id: 42 }, message: { message_id: 8, chat: { id: 42, type: "private" } } },
  });
  assert.equal((await t.hub.hello(air.device_id)).answering, true);
  assert.equal(t.calls.at(-1).method, "editMessageText");
  // A Mac of another chat can't be picked.
  await t.hub.onUpdate({ update_id: 10, callback_query: { id: "cb2", data: "relay:use:feedfeed", from: { id: 42 } } });
  assert.equal((await t.hub.hello(air.device_id)).answering, true);
});

test("switching off hands the answers to another Mac; unpair forgets the chat", async () => {
  const t = makeHub();
  const mini = await paired(t, "Mac mini");
  const air = await paired(t, "MacBook Air");
  await t.hub.onMessage(air.device_id, { type: "answer", on: false });
  assert.equal((await t.hub.hello(mini.device_id)).answering, true);
  await t.hub.onMessage(mini.device_id, { type: "unpair" });
  assert.equal((await t.hub.hello(mini.device_id)).chat, null);
  assert.equal((await t.hub.hello(air.device_id)).answering, true);
  await t.hub.onMessage(air.device_id, { type: "unpair" });
  assert.equal(t.data.get("chat:42"), undefined);
  const count = t.calls.length;
  await t.hub.onUpdate(message(42, "/menu"));
  assert.equal(t.calls.length, count);
});

test("setup sets the webhook with its secret and the commands in two languages", async () => {
  const t = makeHub();
  const result = await t.hub.setup("https://relay.example/telegram", "s3cret");
  assert.equal(result.bot, "AIHubBarTestBot");
  const webhook = t.calls.find((c) => c.method === "setWebhook").params;
  assert.equal(webhook.secret_token, "s3cret");
  assert.deepEqual(webhook.allowed_updates, ["message", "callback_query"]);
  const commands = t.calls.filter((c) => c.method === "setMyCommands");
  assert.deepEqual(commands.map((c) => c.params.language_code), [undefined, "ru"]);
  assert.ok(commands[1].params.commands.some((c) => c.command === "macs"));
});

test("a press goes back to the Mac that sent its message", async () => {
  const t = makeHub();
  const mini = await paired(t, "Mac mini");
  const air = await paired(t, "MacBook Air");
  await t.hub.onMessage(mini.device_id, { type: "answer", on: true });
  t.online.add(mini.device_id).add(air.device_id);
  // The MacBook sends a permission request; the fake Telegram gives it message id 1.
  await t.hub.onMessage(air.device_id, { type: "call", id: 1, method: "sendMessage", params: { text: "✋ Bash" } });
  const press = { update_id: 50, callback_query: { id: "cb", data: "allow:abc", from: { id: 42 }, message: { message_id: 1, chat: { id: 42, type: "private" } } } };
  await t.hub.onUpdate(press);
  assert.equal(t.sent.at(-1).id, air.device_id);
  // Text and presses on other messages still go to the answering Mac.
  await t.hub.onUpdate(message(42, "/menu"));
  assert.equal(t.sent.at(-1).id, mini.device_id);
  await t.hub.onUpdate({ ...press, update_id: 51, callback_query: { ...press.callback_query, message: { message_id: 77, chat: { id: 42, type: "private" } } } });
  assert.equal(t.sent.at(-1).id, mini.device_id);
  // After unpairing, its old messages fall back to the answering Mac.
  await t.hub.onMessage(air.device_id, { type: "unpair" });
  await t.hub.onUpdate({ ...press, update_id: 52 });
  assert.equal(t.sent.at(-1).id, mini.device_id);
});

// MARK: Mini App (§10)

import { createHmac } from "node:crypto";
import { verifyInitData } from "../src/hub.js";

const BOT_TOKEN = "123456:test-token-not-real";

function initData(user, authDate, token = BOT_TOKEN) {
  const fields = { auth_date: String(authDate), query_id: "AAE", user: JSON.stringify(user) };
  const check = Object.keys(fields).sort().map((k) => `${k}=${fields[k]}`).join("\n");
  const secret = createHmac("sha256", "WebAppData").update(token).digest();
  const hash = createHmac("sha256", secret).update(check).digest("hex");
  return new URLSearchParams({ ...fields, hash }).toString();
}

test("initData: Telegram's signature, fresh, with a user", async () => {
  const now = 1_700_000_000;
  assert.equal((await verifyInitData(initData({ id: 42, first_name: "O" }, now - 60), BOT_TOKEN, now)).id, 42);
  assert.equal(await verifyInitData(initData({ id: 42 }, now - 60, "999:other-bot"), BOT_TOKEN, now), null);
  assert.equal(await verifyInitData(initData({ id: 42 }, now - 2 * 86400), BOT_TOKEN, now), null);
  const tampered = initData({ id: 42 }, now).replace("%22id%22%3A42", "%22id%22%3A43");
  assert.equal(await verifyInitData(tampered, BOT_TOKEN, now), null);
  assert.equal(await verifyInitData("", BOT_TOKEN, now), null);
  assert.equal(await verifyInitData("hash=zz", BOT_TOKEN, now), null);
  assert.equal(await verifyInitData(initData({ id: 42 }, now), "", now), null);
});

function makeAppHub() {
  const t = makeHub();
  t.hub.botToken = BOT_TOKEN;
  return t;
}

test("a Mini App call goes to the answering Mac and its reply comes back", async () => {
  const t = makeAppHub();
  const mini = await paired(t, "Mac mini");
  t.online.add(mini.device_id);
  const now = Math.floor(1_700_000_000_000 / 1000);
  const pending = t.hub.app(initData({ id: 42 }, now), "state", { x: 1 });
  // The signature check is async: wait for the call to reach the Mac.
  for (let i = 0; i < 200 && t.sent.at(-1)?.message.type !== "app"; i++) await new Promise((r) => setTimeout(r, 5));
  const sent = t.sent.at(-1);
  assert.equal(sent.id, mini.device_id);
  assert.deepEqual([sent.message.type, sent.message.action, sent.message.params.x], ["app", "state", 1]);
  await t.hub.onMessage(mini.device_id, { type: "appReply", id: sent.message.id, body: { ok: true } });
  assert.deepEqual(await pending, { status: 200, body: { ok: true } });
});

test("a Mini App call: refused, unpaired, offline, bad action", async () => {
  const t = makeAppHub();
  const now = Math.floor(1_700_000_000_000 / 1000);
  assert.equal((await t.hub.app("hash=bad", "state", {})).status, 401);
  assert.equal((await t.hub.app(initData({ id: 42 }, now), "state", {})).status, 404);
  await paired(t, "Mac mini");
  const offline = await t.hub.app(initData({ id: 42 }, now), "state", {});
  assert.deepEqual([offline.status, offline.body.mac], [503, "Mac mini"]);
  assert.equal((await t.hub.app(initData({ id: 42 }, now), "rm -rf", {})).status, 400);
  // Another person's initData reaches only their own chat.
  assert.equal((await t.hub.app(initData({ id: 77 }, now), "state", {})).status, 404);
});

test("setup makes the Mini App the Menu button", async () => {
  const t = makeHub();
  await t.hub.setup("https://relay.example/telegram", "s", "https://relay.example/app");
  const button = t.calls.find((c) => c.method === "setChatMenuButton").params.menu_button;
  assert.deepEqual([button.type, button.web_app.url], ["web_app", "https://relay.example/app"]);
});
