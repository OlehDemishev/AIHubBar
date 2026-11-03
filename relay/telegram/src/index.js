// The shared bot's Worker (docs/specs/SPEC-telegram.md §7): routes the requests to the one `Hub` Durable Object, which
// keeps the Macs' WebSockets with the Hibernation API. The logic lives in `hub.js`.
//
//   POST /telegram        Telegram's webhook (secret header checked)
//   POST /v1/devices      a Mac registers: {name} → {device_id, device_key}
//   GET  /v1/connect      a Mac's WebSocket (Authorization: Bearer <device_key>)
//   POST /admin/setup     once after a deploy (Authorization: Bearer <ADMIN_SECRET>)

import { DurableObject } from "cloudflare:workers";
import { HubCore } from "./hub.js";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const hub = env.HUB.get(env.HUB.idFromName("hub"));
    if (url.pathname === "/telegram" && request.method === "POST") {
      if (!env.WEBHOOK_SECRET || request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== env.WEBHOOK_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
      return hub.fetch(request);
    }
    if (url.pathname === "/admin/setup" && request.method === "POST") {
      if (!env.ADMIN_SECRET || request.headers.get("Authorization") !== `Bearer ${env.ADMIN_SECRET}`) {
        return new Response("forbidden", { status: 403 });
      }
      return hub.fetch(request);
    }
    if ((url.pathname === "/v1/devices" && request.method === "POST") || url.pathname === "/v1/connect") {
      return hub.fetch(request);
    }
    return new Response("AI Hub Bar Telegram relay", { status: url.pathname === "/" ? 200 : 404 });
  },
};

export class Hub extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    // Keep-alive pings from the Macs are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    this.core = new HubCore({
      storage: ctx.storage,
      telegram: async (method, params) => {
        try {
          const response = await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/${method}`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(params),
          });
          const body = await response.json().catch(() => null);
          if (!response.ok) console.log(`Telegram ${method}: HTTP ${response.status}`);
          return { status: response.status, body };
        } catch {
          console.log(`Telegram ${method}: failed`);
          return { status: 0, body: null };
        }
      },
      sockets: {
        send: (deviceId, message) => {
          const sockets = ctx.getWebSockets(deviceId);
          for (const socket of sockets) {
            try { socket.send(JSON.stringify(message)); } catch { /* closing */ }
          }
          return sockets.length > 0;
        },
      },
      random: (n) => crypto.getRandomValues(new Uint8Array(n)),
      siteURL: env.SITE_URL || "https://github.com/OlehDemishev/AIHubBar",
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/telegram": {
        const update = await request.json().catch(() => null);
        if (update) await this.core.onUpdate(update);
        return new Response("ok");
      }
      case "/v1/devices": {
        const body = await request.json().catch(() => ({}));
        return Response.json(await this.core.register(body?.name));
      }
      case "/v1/connect": {
        if (request.headers.get("Upgrade") !== "websocket") return new Response("expected a WebSocket", { status: 426 });
        const deviceId = await this.core.authenticate(request.headers.get("Authorization"));
        if (!deviceId) return new Response("unknown device", { status: 401 });
        const [client, server] = Object.values(new WebSocketPair());
        // One socket per Mac: a reconnect replaces the old one.
        for (const old of this.ctx.getWebSockets(deviceId)) old.close(1000, "replaced");
        this.ctx.acceptWebSocket(server, [deviceId]);
        for (const message of await this.core.onConnect(deviceId)) server.send(JSON.stringify(message));
        return new Response(null, { status: 101, webSocket: client });
      }
      case "/admin/setup":
        return Response.json(await this.core.setup(`${url.origin}/telegram`, this.env.WEBHOOK_SECRET));
      default:
        return new Response("not found", { status: 404 });
    }
  }

  async webSocketMessage(socket, data) {
    const [deviceId] = this.ctx.getTags(socket);
    let message;
    try { message = JSON.parse(typeof data === "string" ? data : new TextDecoder().decode(data)); } catch { return; }
    for (const reply of await this.core.onMessage(deviceId, message)) socket.send(JSON.stringify(reply));
  }

  async webSocketClose(socket, code) {
    try { socket.close(code, "bye"); } catch { /* already closed */ }
  }
}
