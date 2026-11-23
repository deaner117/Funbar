// Relay for Hangout Mansion. Each room code gets one Durable Object holding up to MAX_PLAYERS
// WebSockets, each in its own numbered slot. Anything a player sends (text JSON or binary
// voice) is forwarded verbatim to everyone else in the room; the app logic lives in the
// headsets.
//
//   wss://<host>/room/<code>?id=<client id>
//
// Server -> client messages:
//   {"type":"welcome","slot":0,"peers":[1,2]}
//   {"type":"peer_join","slot":1}  /  {"type":"peer_leave","slot":1}
//   {"type":"pong"}       (reply to {"type":"ping"}, answered without waking the object)
//   {"type":"error","code":"full","reason":"..."}  (then the socket closes)
// Close codes: 4001 = the room is full, 4000 = replaced by a newer connection from the same
// device (a reconnect).
import { DurableObject } from "cloudflare:workers";

const MAX_PLAYERS = 4;
const OPEN = 1;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/") {
      return new Response("Hangout Mansion relay is running.\n");
    }
    const match = url.pathname.match(/^\/room\/([A-Za-z0-9_-]{1,16})$/);
    if (!match) {
      return new Response("Not found\n", { status: 404 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected a WebSocket upgrade\n", { status: 426 });
    }
    const room = env.ROOMS.get(env.ROOMS.idFromName(match[1].toUpperCase()));
    return room.fetch(request);
  },
};

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    // Keep-alive pings are answered by the runtime, so idle rooms can hibernate.
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'),
    );
  }

  // Open player sockets (not rejected ones, not ones being replaced).
  players() {
    return this.ctx.getWebSockets("player").filter((ws) => {
      const a = ws.deserializeAttachment();
      return ws.readyState === OPEN && a && !a.replaced;
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    const id = (url.searchParams.get("id") || "anon").slice(0, 40);
    const [client, server] = Object.values(new WebSocketPair());

    // The same device connecting again = a reconnect: take over its slot.
    let slot = -1;
    for (const old of this.players()) {
      const a = old.deserializeAttachment();
      if (a.id === id) {
        slot = a.slot;
        old.serializeAttachment({ ...a, replaced: true });
        old.send('{"type":"error","code":"replaced","reason":"replaced by a new connection"}');
        old.close(4000, "replaced by a new connection");
      }
    }
    const others = this.players();
    if (slot < 0) {
      const used = new Set(others.map((ws) => ws.deserializeAttachment().slot));
      for (let s = 0; s < MAX_PLAYERS; s++) {
        if (!used.has(s)) {
          slot = s;
          break;
        }
      }
    }
    if (slot < 0) {
      // Say why in a message too: a close code alone doesn't always reach the client.
      const reason = `This room is full (${MAX_PLAYERS} players)`;
      this.ctx.acceptWebSocket(server, ["rejected"]);
      server.send(JSON.stringify({ type: "error", code: "full", reason }));
      server.close(4001, reason);
      return new Response(null, { status: 101, webSocket: client });
    }

    this.ctx.acceptWebSocket(server, ["player"]);
    server.serializeAttachment({ id, slot });
    const peers = others.map((ws) => ws.deserializeAttachment().slot);
    server.send(JSON.stringify({ type: "welcome", slot, peers }));
    const join = JSON.stringify({ type: "peer_join", slot });
    for (const ws of others) ws.send(join);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    if (!this.ctx.getTags(ws).includes("player")) return;
    if (ws.deserializeAttachment()?.replaced) return;
    for (const other of this.players()) {
      if (other !== ws) other.send(message);
    }
  }

  async webSocketClose(ws, code, reason) {
    this.leave(ws);
    try {
      ws.close(1000, "bye");
    } catch {
      // already closed
    }
  }

  async webSocketError(ws) {
    this.leave(ws);
  }

  leave(ws) {
    if (!this.ctx.getTags(ws).includes("player")) return;
    const a = ws.deserializeAttachment();
    if (!a || a.replaced) return; // a newer connection took over this slot
    const msg = JSON.stringify({ type: "peer_leave", slot: a.slot });
    for (const other of this.players()) {
      if (other !== ws) other.send(msg);
    }
  }
}
