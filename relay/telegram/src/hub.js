// The shared bot's relay (docs/specs/SPEC-telegram.md §7): which Mac belongs to which chat, pairing, routing Telegram
// updates to the Mac that answers, and the Macs' calls back to Telegram. Pure of Cloudflare: storage, sockets, Telegram
// and the clock come in from `index.js`, so the tests can run it under plain Node.

import { text } from "./texts.js";

/** What a Mac may call, always into its own chat. */
export const ALLOWED_METHODS = ["sendMessage", "editMessageText", "editMessageReplyMarkup", "deleteMessage", "answerCallbackQuery"];
export const CODE_TTL_MS = 10 * 60 * 1000;
export const QUEUE_TTL_MS = 24 * 60 * 60 * 1000;
export const CALLS_PER_MINUTE = 30;
/** The Mini App's calls wait this long for the Mac (§10). */
export const APP_TIMEOUT_MS = 15_000;
/** Telegram's `initData` older than this is refused. */
export const INIT_DATA_MAX_AGE_S = 24 * 60 * 60;
const OFFLINE_NOTICE_MS = 10 * 60 * 1000;
const CODE_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789";

export class HubCore {
  /**
   * @param {object} deps
   * @param {{get(k:string):Promise<any>, put(k:string,v:any):Promise<void>, delete(k:string):Promise<any>, list(o:{prefix:string}):Promise<Map<string,any>>}} deps.storage
   * @param {(method:string, params:object) => Promise<{status:number, body:any}>} deps.telegram
   * @param {{send(deviceId:string, message:object):boolean}} deps.sockets  send returns false when the Mac is offline
   * @param {() => number} deps.now
   * @param {(n:number) => Uint8Array} deps.random
   * @param {string} deps.siteURL
   * @param {string} [deps.botToken] for checking the Mini App's `initData`
   */
  constructor({ storage, telegram, sockets, now = Date.now, random, siteURL, botToken = "" }) {
    this.botToken = botToken;
    /** Mini App calls waiting for their Mac: id → resolve. */
    this.appCalls = new Map();
    this.nextAppID = 1;
    this.storage = storage;
    this.telegram = telegram;
    this.sockets = sockets;
    this.now = now;
    this.random = random;
    this.siteURL = siteURL;
    /** deviceId → call times in the last minute; lost on hibernation, which is fine. */
    this.calls = new Map();
  }

  // MARK: Devices

  /** A new Mac: its id and the key it keeps in the Keychain; only the key's hash is stored. */
  async register(name) {
    const id = hex(this.random(8));
    const key = base64url(this.random(32));
    const hash = await sha256(key);
    await this.storage.put(`dev:${id}`, { hash, name: clean(name) || "Mac", chat: null, created: this.now() });
    await this.storage.put(`key:${hash}`, id);
    return { device_id: id, device_key: key };
  }

  async authenticate(authorization) {
    const match = /^Bearer ([A-Za-z0-9_-]{20,100})$/.exec(authorization || "");
    if (!match) return null;
    return (await this.storage.get(`key:${await sha256(match[1])}`)) || null;
  }

  /** What a Mac gets when its socket opens: its state, then the updates that waited for it. */
  async onConnect(deviceId) {
    const messages = [await this.hello(deviceId)];
    const queued = await this.storage.list({ prefix: `q:${deviceId}:` });
    for (const [key, item] of queued) {
      await this.storage.delete(key);
      if (this.now() - item.at <= QUEUE_TTL_MS) messages.push({ type: "update", update: item.update });
    }
    return messages;
  }

  async hello(deviceId) {
    const device = await this.storage.get(`dev:${deviceId}`);
    const chat = device?.chat ? await this.storage.get(`chat:${device.chat}`) : null;
    return {
      type: "hello",
      bot: (await this.storage.get("meta:bot")) || null,
      chat: device?.chat || null,
      answering: !!chat && chat.active === deviceId,
      macs: chat ? chat.devices.length : 0,
    };
  }

  /** A message from a Mac's socket; returns the replies for it. */
  async onMessage(deviceId, message) {
    const device = await this.storage.get(`dev:${deviceId}`);
    if (!device || typeof message !== "object" || message === null) return [];
    switch (message.type) {
      case "call":
        return [await this.call(deviceId, device, message)];
      case "pair":
        return [await this.pair(deviceId, message.id)];
      case "answer":
        return [await this.setAnswering(deviceId, device, !!message.on)];
      case "unpair":
        await this.unpair(deviceId, device);
        return [await this.hello(deviceId)];
      case "appReply": {
        const resolve = this.appCalls.get(message.id);
        if (resolve) resolve({ status: 200, body: message.body ?? null, deviceId });
        return [];
      }
      default:
        return [];
    }
  }

  async call(deviceId, device, { id, method, params }) {
    const reply = (status, body) => ({ type: "reply", id, status, body });
    if (!ALLOWED_METHODS.includes(method)) return reply(403, { ok: false, description: "method not allowed" });
    if (method !== "answerCallbackQuery" && !device.chat) return reply(409, { ok: false, description: "not paired" });
    if (!this.allowCall(deviceId)) return reply(429, { ok: false, description: "too many calls" });
    const safe = { ...(params && typeof params === "object" ? params : {}) };
    if (method === "answerCallbackQuery") {
      delete safe.chat_id;
      delete safe.url;
    } else {
      safe.chat_id = device.chat;
    }
    const result = await this.telegram(method, safe);
    // Remember which Mac sent the message: presses on its buttons go back to that Mac (a request from the MacBook
    // is answered on the MacBook even while the Mac mini answers the chat). Ids grow, so the 1000th older is dropped.
    const messageID = result.body?.result?.message_id;
    if (method === "sendMessage" && result.status === 200 && Number.isInteger(messageID)) {
      await this.storage.put(`msg:${device.chat}:${messageID}`, deviceId);
      await this.storage.delete(`msg:${device.chat}:${messageID - 1000}`);
    }
    return reply(result.status, result.body);
  }

  allowCall(deviceId) {
    const recent = (this.calls.get(deviceId) || []).filter((t) => this.now() - t < 60_000);
    if (recent.length >= CALLS_PER_MINUTE) {
      this.calls.set(deviceId, recent);
      return false;
    }
    recent.push(this.now());
    this.calls.set(deviceId, recent);
    return true;
  }

  async pair(deviceId, id) {
    let code = "";
    const bytes = this.random(12);
    for (const byte of bytes) code += CODE_ALPHABET[byte % CODE_ALPHABET.length];
    await this.storage.put(`code:${code}`, { device: deviceId, expires: this.now() + CODE_TTL_MS });
    const bot = await this.storage.get("meta:bot");
    return { type: "pairCode", id, code, link: bot ? `https://t.me/${bot}?start=${code}` : null };
  }

  async setAnswering(deviceId, device, on) {
    if (device.chat) {
      const chat = await this.storage.get(`chat:${device.chat}`);
      if (chat) {
        const previous = chat.active;
        if (on) chat.active = deviceId;
        else if (chat.active === deviceId) chat.active = chat.devices.find((d) => d !== deviceId) || null;
        await this.storage.put(`chat:${device.chat}`, chat);
        for (const other of [previous, chat.active]) {
          if (other && other !== deviceId) this.sockets.send(other, await this.hello(other));
        }
      }
    }
    return this.hello(deviceId);
  }

  async unpair(deviceId, device) {
    if (device.chat) {
      const chat = await this.storage.get(`chat:${device.chat}`);
      if (chat) {
        chat.devices = chat.devices.filter((d) => d !== deviceId);
        if (chat.active === deviceId) chat.active = chat.devices[0] || null;
        if (chat.devices.length) await this.storage.put(`chat:${device.chat}`, chat);
        else await this.storage.delete(`chat:${device.chat}`);
        if (chat.active) this.sockets.send(chat.active, await this.hello(chat.active));
      }
    }
    device.chat = null;
    await this.storage.put(`dev:${deviceId}`, device);
    for (const [key] of await this.storage.list({ prefix: `q:${deviceId}:` })) await this.storage.delete(key);
  }

  // MARK: Telegram → Macs

  /** One update from Telegram's webhook. */
  async onUpdate(update) {
    const message = update.message;
    const callback = update.callback_query;
    const chatInfo = message?.chat || callback?.message?.chat;
    const from = String((message || callback)?.from?.id ?? "");
    // Private chats only; for a press on an old message without it, the sender stands for the chat.
    if (chatInfo && chatInfo.type !== "private") return;
    const chatID = chatInfo ? String(chatInfo.id) : from;
    if (!chatID || chatID !== from) return;
    const language = (message || callback)?.from?.language_code;
    const words = message?.text?.trim().split(/\s+/) || [];
    const command = (words[0] || "").split("@")[0].toLowerCase();

    if (command === "/start" && words[1] && words[1].length >= 8) {
      return this.bind(chatID, words[1], language);
    }
    const chat = await this.storage.get(`chat:${chatID}`);
    if (!chat) {
      if (command === "/start") await this.say(chatID, text(language, "welcome", { site: this.siteURL }));
      else if (callback) await this.telegram("answerCallbackQuery", { callback_query_id: callback.id });
      return;
    }
    if (command === "/macs") return this.listMacs(chatID, chat, language);
    if (callback?.data?.startsWith("relay:use:")) return this.useMac(chatID, chat, callback, language);
    // A press goes to the Mac that sent the message it sits on; anything else to the Mac that answers.
    const sender = callback?.message?.message_id ? await this.storage.get(`msg:${chatID}:${callback.message.message_id}`) : null;
    const target = sender && chat.devices.includes(sender) ? sender : chat.active;
    if (!target) {
      if (callback) await this.telegram("answerCallbackQuery", { callback_query_id: callback.id, text: text(language, "noMac") });
      else await this.say(chatID, text(language, "noMac"));
      return;
    }
    if (this.sockets.send(target, { type: "update", update })) return;
    // Telegram's update ids grow, so the keys list in order.
    await this.storage.put(`q:${target}:${String(update.update_id).padStart(12, "0")}`, { at: this.now(), update });
    const device = await this.storage.get(`dev:${target}`);
    if (callback) {
      await this.telegram("answerCallbackQuery", { callback_query_id: callback.id, text: text(language, "asleep", { mac: device?.name || "Mac" }) });
    } else if (this.now() - (chat.offlineNoticeAt || 0) > OFFLINE_NOTICE_MS) {
      chat.offlineNoticeAt = this.now();
      await this.storage.put(`chat:${chatID}`, chat);
      await this.say(chatID, text(language, "asleep", { mac: device?.name || "Mac" }));
    }
  }

  async bind(chatID, code, language) {
    const entry = await this.storage.get(`code:${code}`);
    await this.storage.delete(`code:${code}`);
    const device = entry && entry.expires >= this.now() ? await this.storage.get(`dev:${entry.device}`) : null;
    if (!device) return this.say(chatID, text(language, "badCode"));
    // A Mac moves to the new chat and leaves its old one.
    if (device.chat && device.chat !== chatID) await this.unpair(entry.device, device);
    const chat = (await this.storage.get(`chat:${chatID}`)) || { devices: [], active: null };
    if (!chat.devices.includes(entry.device)) chat.devices.push(entry.device);
    chat.active = entry.device;
    device.chat = chatID;
    await this.storage.put(`dev:${entry.device}`, device);
    await this.storage.put(`chat:${chatID}`, chat);
    for (const other of chat.devices) this.sockets.send(other, await this.hello(other));
  }

  async listMacs(chatID, chat, language, messageID) {
    const rows = [];
    for (const id of chat.devices) {
      const device = await this.storage.get(`dev:${id}`);
      rows.push([{ text: (id === chat.active ? "✅ " : "") + (device?.name || "Mac"), callback_data: `relay:use:${id}` }]);
    }
    const params = { chat_id: chatID, text: text(language, "macs"), reply_markup: { inline_keyboard: rows } };
    if (messageID) await this.telegram("editMessageText", { ...params, message_id: messageID });
    else await this.telegram("sendMessage", params);
  }

  async useMac(chatID, chat, callback, language) {
    const id = callback.data.slice("relay:use:".length);
    if (chat.devices.includes(id) && chat.active !== id) {
      const previous = chat.active;
      chat.active = id;
      await this.storage.put(`chat:${chatID}`, chat);
      for (const other of [previous, id]) if (other) this.sockets.send(other, await this.hello(other));
    }
    await this.telegram("answerCallbackQuery", { callback_query_id: callback.id });
    await this.listMacs(chatID, chat, language, callback.message?.message_id);
  }

  async say(chatID, message) {
    await this.telegram("sendMessage", { chat_id: chatID, text: message, disable_web_page_preview: true });
  }

  // MARK: Mini App (§10)

  /**
   * One call from the Mini App: `initData` proves the Telegram user; the call goes to the Mac answering that private
   * chat and its reply comes back. 401 bad or old `initData`, 404 no Mac paired, 503 the Mac is offline, 504 no answer.
   */
  async app(initData, action, params) {
    const user = await verifyInitData(initData, this.botToken, this.now() / 1000);
    if (!user) return { status: 401, body: { error: "unauthorized" } };
    const chat = await this.storage.get(`chat:${user.id}`);
    if (!chat?.active) return { status: 404, body: { error: "no Mac" } };
    const device = await this.storage.get(`dev:${chat.active}`);
    if (typeof action !== "string" || !/^[a-zA-Z]{1,20}$/.test(action)) return { status: 400, body: { error: "bad action" } };
    const id = this.nextAppID++;
    let timer;
    const reply = new Promise((resolve) => {
      this.appCalls.set(id, resolve);
      timer = setTimeout(() => resolve({ status: 504, body: { error: "timeout", mac: device?.name || "Mac" } }), APP_TIMEOUT_MS);
    });
    if (!this.sockets.send(chat.active, { type: "app", id, action, params: params && typeof params === "object" ? params : {} })) {
      clearTimeout(timer);
      this.appCalls.delete(id);
      return { status: 503, body: { error: "offline", mac: device?.name || "Mac" } };
    }
    const result = await reply;
    clearTimeout(timer);
    this.appCalls.delete(id);
    // Only the answering Mac's reply counts.
    if (result.deviceId && result.deviceId !== chat.active) return { status: 504, body: { error: "timeout" } };
    return { status: result.status, body: result.body };
  }

  // MARK: Setup

  /** Once after a deploy: the webhook, the bot's commands and description; remembers its username. */
  async setup(webhookURL, webhookSecret, appURL) {
    const me = await this.telegram("getMe", {});
    const username = me.body?.result?.username;
    if (username) await this.storage.put("meta:bot", username);
    const results = {
      getMe: me.status,
      setWebhook: (await this.telegram("setWebhook", {
        url: webhookURL, secret_token: webhookSecret, allowed_updates: ["message", "callback_query"], drop_pending_updates: true,
      })).status,
    };
    if (appURL) {
      results.menuButton = (await this.telegram("setChatMenuButton", {
        menu_button: { type: "web_app", text: "AI Hub Bar", web_app: { url: appURL } },
      })).status;
    }
    for (const language of ["en", "ru"]) {
      const scope = language === "en" ? {} : { language_code: language };
      results[`commands_${language}`] = (await this.telegram("setMyCommands", { ...scope, commands: text(language, "commands") })).status;
      results[`description_${language}`] = (await this.telegram("setMyDescription", { ...scope, description: text(language, "description") })).status;
      results[`short_${language}`] = (await this.telegram("setMyShortDescription", { ...scope, short_description: text(language, "short") })).status;
    }
    return { bot: username || null, results };
  }
}

// MARK: Helpers

function clean(name) {
  return String(name || "").replace(/[\u0000-\u001f]/g, "").trim().slice(0, 40);
}

export function hex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Telegram's Mini App `initData` check: the data-check string (every field but `hash`, sorted, `key=value` lines)
 * signed with HMAC-SHA-256 under HMAC-SHA-256("WebAppData", bot token). Returns the user, or null.
 */
export async function verifyInitData(initData, botToken, nowSeconds) {
  if (typeof initData !== "string" || !initData || !botToken) return null;
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash || !/^[0-9a-f]{64}$/.test(hash)) return null;
  params.delete("hash");
  const check = [...params.entries()].map(([k, v]) => `${k}=${v}`).sort().join("\n");
  const secret = await hmac(new TextEncoder().encode("WebAppData"), new TextEncoder().encode(botToken));
  const expected = hex(new Uint8Array(await hmac(secret, new TextEncoder().encode(check))));
  if (!timingSafeEqual(expected, hash)) return null;
  const authDate = Number(params.get("auth_date"));
  if (!Number.isFinite(authDate) || nowSeconds - authDate > INIT_DATA_MAX_AGE_S) return null;
  try {
    const user = JSON.parse(params.get("user") || "null");
    return user && Number.isInteger(user.id) ? user : null;
  } catch {
    return null;
  }
}

async function hmac(keyBytes, data) {
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", key, data);
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function sha256(value) {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}
