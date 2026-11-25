// One Durable Object per machine id. It forwards opaque encrypted frames between the
// host's WebSocket and each device's WebSocket, adding only the device id, and stores
// nothing but the two token hashes, device push tokens and timestamps.
import { DurableObject } from "cloudflare:workers";

import {
  envelope,
  hostOffline,
  hostOnline,
  ID_PATTERN,
  openEnvelope,
  sameHash,
  sha256Hex,
  tokenOf,
} from "./protocol";
import type { BoardStore } from "./board";
import { REQUEST_UNITS, type RelayAdmin } from "./admin";
import { FcmPushSender, parseServiceAccount, PushSender, UnconfiguredPushSender } from "./push";

export interface Env {
  MACHINE: DurableObjectNamespace<MachineRelay>;
  BOARD: DurableObjectNamespace<BoardStore>;
  ADMIN: DurableObjectNamespace<RelayAdmin>;
  /** "required": a machine registering for the first time needs an invite code. */
  INVITES?: string;
  /** The owner's key to /admin/... (a Worker secret). */
  ADMIN_TOKEN?: string;
  /** The shared pool's daily units (default POOL_DAILY_UNITS). */
  POOL_DAILY_UNITS?: string;
  /** "1": log a line per forwarded frame (size and first bytes); "full": also the whole
   * frame in base64. For local checks only. */
  RELAY_LOG_FRAMES?: string;
  /** The Firebase service-account key (JSON) for FCM; without it push is not configured. */
  FCM_SERVICE_ACCOUNT?: string;
}

type Attachment = { role: "host" } | { role: "device"; deviceId: string; replaced?: boolean };

const HASH_PATTERN = /^[0-9a-f]{64}$/;
const MAX_PUSH_PAYLOAD = 3000;

/** Messages (forwarded frames and push requests) one machine may send through the relay in
 * a UTC day, so one busy machine cannot use up the free allowance everybody shares. */
export const MACHINE_DAILY_LIMIT = 50000;

/** Units a machine gathers before it reports them to the pool (one report = one request). */
const REPORT_EVERY = 1000;

/** How often the day's count is written (every this many messages, and on a new day). */
const COUNT_FLUSH_EVERY = 100;

function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function hex(bytes: Uint8Array, n: number): string {
  return [...bytes.subarray(0, n)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export class MachineRelay extends DurableObject<Env> {
  /** FCM when the Worker has its service-account secret; replaced in tests. */
  pushSender: PushSender;

  /** The daily cap and the clock (replaced in tests). */
  messageLimit = MACHINE_DAILY_LIMIT;
  now: () => number = () => Date.now();

  /** Whether invites are required (the INVITES var unless a test sets it). */
  invitesRequired: boolean | null = null;

  /** Units not yet reported to the pool (a test may lower the threshold). */
  private unreported = 0;
  reportEvery = REPORT_EVERY;

  /** The UTC day the shared pool was found used up (friends' machines only). */
  private poolShutDay: string | null = null;

  private admin(): DurableObjectStub<RelayAdmin> {
    return this.env.ADMIN.get(this.env.ADMIN.idFromName("admin"));
  }

  private requireInvites(): boolean {
    return this.invitesRequired ?? this.env.INVITES === "required";
  }

  /** The invite this machine registered with and whether it is the owner's. Machines
   * registered before invites existed have none and are the owner's. */
  private async membership(): Promise<{ invite: string | null; exempt: boolean; revoked: boolean }> {
    const m = await this.ctx.storage.get<string | boolean>(["invite", "exempt", "revoked"]);
    const invite = (m.get("invite") as string | undefined) ?? null;
    return { invite, exempt: invite === null || m.get("exempt") === true, revoked: m.get("revoked") === true };
  }

  private poolShut(exempt: boolean): boolean {
    return !exempt && this.poolShutDay === utcDay(this.now());
  }

  /** Adds [units] for the shared pool; every [reportEvery] units tells the admin object and
   * closes everything when the pool is used up (friends) or the invite was revoked. */
  private async addUnits(units: number): Promise<void> {
    this.unreported += units;
    if (this.unreported < this.reportEvery) return;
    const n = this.unreported;
    this.unreported = 0;
    const m = await this.membership();
    let r;
    try {
      r = await this.admin().report(n, m.invite);
    } catch {
      return;
    }
    if (r.revoked && m.invite) {
      await this.ctx.storage.put("revoked", true);
      for (const ws of this.ctx.getWebSockets()) MachineRelay.close(ws, 4031, "invite revoked");
      return;
    }
    if (r.shut && !m.exempt) {
      this.poolShutDay = utcDay(this.now());
      for (const ws of this.ctx.getWebSockets()) MachineRelay.close(ws, 4030, "shared pool used up");
    }
  }

  /** Today's count, written to storage every [COUNT_FLUSH_EVERY] messages. */
  private counted: { day: string; count: number; unflushed: number } | null = null;

  /** Today's count (read from storage once per day or after the object woke up). */
  private async today(): Promise<{ day: string; count: number; unflushed: number }> {
    const day = utcDay(this.now());
    const c = this.counted;
    if (c && c.day === day) return c;
    if (c) this.ctx.waitUntil(this.ctx.storage.delete(`count:${c.day}`));
    const stored = (await this.ctx.storage.get<number>(`count:${day}`)) ?? 0;
    // Another wake-up may have loaded it meanwhile.
    if (this.counted && this.counted.day === day) return this.counted;
    return (this.counted = { day, count: stored, unflushed: 0 });
  }

  private async overLimit(): Promise<boolean> {
    return (await this.today()).count >= this.messageLimit;
  }

  /** Counts one message; false (and every socket closed with 4029) when the day's cap is
   * reached. */
  private async count(): Promise<boolean> {
    const c = await this.today();
    if (c.count >= this.messageLimit) {
      await this.flush(c);
      for (const ws of this.ctx.getWebSockets()) MachineRelay.close(ws, 4029, "daily limit");
      return false;
    }
    c.count++;
    c.unflushed++;
    await this.addUnits(1);
    if (c.unflushed >= COUNT_FLUSH_EVERY) await this.flush(c);
    return true;
  }

  private async flush(c: { day: string; count: number; unflushed: number }): Promise<void> {
    if (c.unflushed === 0 && (await this.ctx.storage.get<number>(`count:${c.day}`)) === c.count) return;
    c.unflushed = 0;
    await this.ctx.storage.put(`count:${c.day}`, c.count);
  }

  /** A WebSocket accepted only to be closed at once: over the daily cap. */
  private static refusedSocket(code = 4029, reason = "daily limit"): Response {
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    server.close(code, reason);
    return new Response(null, { status: 101, webSocket: client });
  }

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const account = parseServiceAccount(env.FCM_SERVICE_ACCOUNT);
    this.pushSender = account ? new FcmPushSender(account) : new UnconfiguredPushSender();
    // The host's keepalive is answered without waking the object from hibernation.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  // ---------------------------------------------------------------- requests

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter((p) => p.length > 0); // m, <id>, ...
    const rest = parts.slice(2);
    if (rest.length === 1 && rest[0] === "host") return this.hostSocket(request, url);
    if (rest.length === 1 && rest[0] === "device") return this.deviceSocket(request, url);
    if (rest.length === 1 && rest[0] === "push") return this.push(request, url);
    if (rest.length === 1 && rest[0] === "usage") return this.usage(request, url);
    if (rest.length === 1 && rest[0] === "check") return this.check(request, url);
    if (rest.length === 3 && rest[0] === "devices" && rest[2] === "push-token") {
      return this.pushToken(request, url, rest[1]);
    }
    return json(404, { error: "notFound" });
  }

  private async hashes(): Promise<{ host?: string; device?: string }> {
    const m = await this.ctx.storage.get<string>(["hostHash", "deviceHash"]);
    return { host: m.get("hostHash"), device: m.get("deviceHash") };
  }

  /** Checks the host token; on first contact registers both hashes (trust on first use). */
  private async authHost(request: Request, url: URL): Promise<Response | null> {
    const token = tokenOf(request, url);
    if (!token) return json(401, { error: "noToken" });
    const presented = await sha256Hex(token);
    const stored = await this.hashes();
    if (stored.host === undefined) {
      const deviceHash = request.headers.get("X-Perch-Device-Token-Hash") ?? "";
      if (!HASH_PATTERN.test(deviceHash)) return json(400, { error: "deviceTokenHashRequired" });
      const now = Date.now();
      if (this.requireInvites()) {
        const machineId = url.pathname.split("/").filter((p) => p.length > 0)[1];
        const reg = await this.admin().register(machineId, request.headers.get("X-Perch-Invite"));
        if (!reg.ok) return json(403, { error: reg.error });
        await this.ctx.storage.put({ hostHash: presented, deviceHash, registeredAt: now, invite: reg.invite, exempt: reg.exempt });
        return null;
      }
      await this.ctx.storage.put({ hostHash: presented, deviceHash, registeredAt: now });
      return null;
    }
    if (!sameHash(presented, stored.host)) return json(403, { error: "badToken" });
    if ((await this.membership()).revoked) return json(403, { error: "inviteRevoked" });
    return null;
  }

  private async authDevice(request: Request, url: URL): Promise<Response | null> {
    const token = tokenOf(request, url);
    if (!token) return json(401, { error: "noToken" });
    const stored = await this.hashes();
    if (stored.device === undefined) return json(403, { error: "unknownMachine" });
    return sameHash(await sha256Hex(token), stored.device) ? null : json(403, { error: "badToken" });
  }

  private hostSocketNow(): WebSocket | null {
    for (const ws of this.ctx.getWebSockets("host")) {
      if (ws.readyState === WebSocket.OPEN) return ws;
    }
    return null;
  }

  private deviceSockets(deviceId?: string): WebSocket[] {
    return this.ctx.getWebSockets(deviceId === undefined ? "dev" : `dev:${deviceId}`).filter((ws) => {
      const a = ws.deserializeAttachment() as Attachment | null;
      return ws.readyState === WebSocket.OPEN && a?.role === "device" && !a.replaced;
    });
  }

  private static send(ws: WebSocket, data: string | ArrayBuffer | Uint8Array): void {
    try {
      ws.send(data);
    } catch {
      // the socket is going away
    }
  }

  private static close(ws: WebSocket, code: number, reason: string): void {
    try {
      ws.close(code, reason);
    } catch {
      // already closed
    }
  }

  private async hostSocket(request: Request, url: URL): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return json(426, { error: "webSocketOnly" });
    const refused = await this.authHost(request, url);
    if (refused) return refused;
    if (await this.overLimit()) return MachineRelay.refusedSocket();
    const m = await this.membership();
    if (m.invite && (await this.admin().revoked(m.invite))) {
      await this.ctx.storage.put("revoked", true);
      return json(403, { error: "inviteRevoked" });
    }
    if (this.poolShut(m.exempt)) return MachineRelay.refusedSocket(4030, "shared pool used up");
    await this.addUnits(REQUEST_UNITS);
    for (const old of this.ctx.getWebSockets("host")) MachineRelay.close(old, 4000, "replaced");
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server, ["host"]);
    server.serializeAttachment({ role: "host" } satisfies Attachment);
    await this.ctx.storage.put("hostSeenAt", Date.now());
    // Devices waiting for the host start their handshake again.
    for (const ws of this.deviceSockets()) MachineRelay.send(ws, hostOnline);
    return new Response(null, { status: 101, webSocket: client });
  }

  private async deviceSocket(request: Request, url: URL): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return json(426, { error: "webSocketOnly" });
    const deviceId = url.searchParams.get("d") ?? "";
    if (!ID_PATTERN.test(deviceId)) return json(400, { error: "badDeviceId" });
    const refused = await this.authDevice(request, url);
    if (refused) return refused;
    if (await this.overLimit()) return MachineRelay.refusedSocket();
    if (this.poolShut((await this.membership()).exempt)) return MachineRelay.refusedSocket(4030, "shared pool used up");
    await this.addUnits(REQUEST_UNITS);
    const host = this.hostSocketNow();
    // A device id connects once: the newer connection replaces the older.
    for (const old of this.deviceSockets(deviceId)) {
      old.serializeAttachment({ role: "device", deviceId, replaced: true } satisfies Attachment);
      MachineRelay.close(old, 4000, "replaced");
      if (host) MachineRelay.send(host, JSON.stringify({ t: "close", d: deviceId }));
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server, ["dev", `dev:${deviceId}`]);
    server.serializeAttachment({ role: "device", deviceId } satisfies Attachment);
    await this.ctx.storage.put(`seen:${deviceId}`, Date.now());
    if (host) {
      MachineRelay.send(host, JSON.stringify({ t: "open", d: deviceId }));
    } else {
      MachineRelay.send(server, hostOffline);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  // ---------------------------------------------------------------- push

  /** Today's message count against the cap (the host's token only). */
  private async usage(request: Request, url: URL): Promise<Response> {
    if (request.method !== "GET") return json(405, { error: "getOnly" });
    const refused = await this.authHost(request, url);
    if (refused) return refused;
    const c = await this.today();
    await this.addUnits(REQUEST_UNITS);
    const m = await this.membership();
    let pool: { used: number; limit: number; shut: boolean } | undefined;
    try {
      const p = await this.admin().pool();
      pool = { used: p.used, limit: p.limit, shut: p.shut };
    } catch {
      pool = undefined;
    }
    return json(200, { messagesToday: c.count, messageLimit: this.messageLimit, exempt: m.exempt, pool });
  }

  /** Why a host connection would be refused, as JSON (a refused WebSocket upgrade does not
   * hand its body to every client): 200 {"ok": true}, or 403/429 {"error"}. */
  private async check(request: Request, url: URL): Promise<Response> {
    if (request.method !== "GET") return json(405, { error: "getOnly" });
    const refused = await this.authHost(request, url);
    if (refused) return refused;
    await this.addUnits(REQUEST_UNITS);
    if (await this.overLimit()) return json(429, { error: "dailyLimit" });
    const m = await this.membership();
    if (m.invite && (await this.admin().revoked(m.invite))) return json(403, { error: "inviteRevoked" });
    if (this.poolShut(m.exempt)) return json(429, { error: "poolUsedUp" });
    return json(200, { ok: true, exempt: m.exempt });
  }

  private async push(request: Request, url: URL): Promise<Response> {
    if (request.method !== "POST") return json(405, { error: "postOnly" });
    const refused = await this.authHost(request, url);
    if (refused) return refused;
    if (!(await this.count())) return json(429, { error: "daily limit" });
    if (this.poolShut((await this.membership()).exempt)) return json(429, { error: "poolUsedUp" });
    await this.addUnits(REQUEST_UNITS - 1);
    let body: {
      payload?: unknown;
      devices?: unknown;
      except?: unknown;
      priority?: unknown;
      collapseKey?: unknown;
      withdraw?: unknown;
    };
    try {
      body = await request.json();
    } catch {
      return json(400, { error: "badJson" });
    }
    const payload = body.payload;
    if (typeof payload !== "string" || payload.length === 0 || payload.length > MAX_PUSH_PAYLOAD) {
      return json(400, { error: "badPayload" });
    }
    const only = Array.isArray(body.devices) ? new Set(body.devices.filter((d) => typeof d === "string")) : null;
    // Devices that have the session open in front of the owner right now.
    const except = new Set(Array.isArray(body.except) ? body.except.filter((d) => typeof d === "string") : []);
    const priority = body.priority === "normal" ? "normal" : "high";
    const collapseKey = typeof body.collapseKey === "string" ? body.collapseKey.slice(0, 64) : undefined;
    const withdraw = body.withdraw === true;
    const machineId = url.pathname.split("/").filter((p) => p.length > 0)[1];
    const tokens = await this.ctx.storage.list<{ token: string; updatedAt: number }>({ prefix: "push:" });
    let sent = 0;
    let failed = 0;
    for (const [key, value] of tokens) {
      const deviceId = key.slice("push:".length);
      if ((only && !only.has(deviceId)) || except.has(deviceId)) continue;
      const r = await this.pushSender.send({
        token: value.token,
        deviceId,
        machineId,
        payload,
        priority,
        collapseKey,
        withdraw,
      });
      if (r.ok) {
        sent++;
      } else {
        failed++;
        if (r.unregistered) await this.ctx.storage.delete(key);
      }
    }
    return json(200, { sent, failed });
  }

  private async pushToken(request: Request, url: URL, deviceId: string): Promise<Response> {
    if (request.method !== "POST") return json(405, { error: "postOnly" });
    if (!ID_PATTERN.test(deviceId)) return json(400, { error: "badDeviceId" });
    const refused = await this.authDevice(request, url);
    if (refused) return refused;
    let body: { token?: unknown };
    try {
      body = await request.json();
    } catch {
      return json(400, { error: "badJson" });
    }
    if (body.token === null) {
      await this.ctx.storage.delete(`push:${deviceId}`);
      return json(200, { stored: false });
    }
    if (typeof body.token !== "string" || body.token.length === 0 || body.token.length > 4096) {
      return json(400, { error: "badToken" });
    }
    await this.ctx.storage.put(`push:${deviceId}`, { token: body.token, updatedAt: Date.now() });
    return json(200, { stored: true });
  }

  // ---------------------------------------------------------------- frames

  private log(direction: string, deviceId: string, frame: Uint8Array): void {
    const mode = this.env.RELAY_LOG_FRAMES;
    if (mode !== "1" && mode !== "full") return;
    const line: Record<string, unknown> = { relayFrame: direction, device: deviceId, bytes: frame.length, head: hex(frame, 16) };
    if (mode === "full") line.base64 = base64(frame);
    console.log(JSON.stringify(line));
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const a = ws.deserializeAttachment() as Attachment | null;
    if (!a) return;
    if (a.role === "host") {
      if (typeof message === "string") {
        let m: { t?: unknown; d?: unknown; code?: unknown; reason?: unknown };
        try {
          m = JSON.parse(message);
        } catch {
          return;
        }
        if (m.t === "close" && typeof m.d === "string") {
          const code = typeof m.code === "number" && m.code >= 4000 && m.code < 5000 ? m.code : 4001;
          const reason = typeof m.reason === "string" ? m.reason.slice(0, 100) : "closed by host";
          for (const d of this.deviceSockets(m.d)) MachineRelay.close(d, code, reason);
        }
        return;
      }
      const e = openEnvelope(message);
      if (!e) return;
      if (!(await this.count())) return;
      const targets = this.deviceSockets(e.deviceId);
      if (targets.length === 0) {
        MachineRelay.send(ws, JSON.stringify({ t: "close", d: e.deviceId }));
        return;
      }
      this.log("host->device", e.deviceId, e.frame);
      for (const d of targets) MachineRelay.send(d, e.frame);
      return;
    }
    if (a.replaced || typeof message === "string") return; // devices send only frames
    if (!(await this.count())) return;
    const host = this.hostSocketNow();
    if (!host) {
      MachineRelay.send(ws, hostOffline);
      return;
    }
    const frame = new Uint8Array(message);
    this.log("device->host", a.deviceId, frame);
    MachineRelay.send(host, envelope(a.deviceId, frame));
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    this.closed(ws);
    MachineRelay.close(ws, code === 1005 || code === 1006 ? 1000 : code, reason);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.closed(ws);
  }

  private closed(ws: WebSocket): void {
    const a = ws.deserializeAttachment() as Attachment | null;
    if (!a) return;
    if (a.role === "host") {
      if (this.hostSocketNow() === null) {
        for (const d of this.deviceSockets()) MachineRelay.send(d, hostOffline);
      }
      this.ctx.waitUntil(this.ctx.storage.put("hostSeenAt", Date.now()));
      return;
    }
    if (a.replaced) return;
    const host = this.hostSocketNow();
    if (host) MachineRelay.send(host, JSON.stringify({ t: "close", d: a.deviceId }));
  }
}
