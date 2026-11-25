// The relay's one admin object (docs/superpowers/specs/2026-11-25-relay-invites-and-pool-design.md):
// invite codes (only their SHA-256 is kept), which machine registered with which invite, and
// the shared daily pool. Machine objects call it through RPC; the owner through /admin/...
// with the ADMIN_TOKEN secret (relay/tools/invites.mjs).
//
// POST /admin/invites {"name", "machines"?, "owner"?} -> {"id", "code", ...}  (the code is shown once)
// GET  /admin/invites                                  -> {"invites": [...]}
// POST /admin/invites/<id>/revoke                      -> {"id", "revoked": true}
// GET  /admin/pool                                     -> {"day", "used", "limit", "shut"}
import { DurableObject } from "cloudflare:workers";

import { sameHash, sha256Hex } from "./protocol";

/** Units a day machines on friends' invites may use together: 60% of the free plan's
 * 100,000 Durable Object requests (an incoming WebSocket message is 1/20 of one). */
export const POOL_DAILY_UNITS = 1_200_000;

/** An HTTP request (socket upgrade, push, usage, board call) in pool units. */
export const REQUEST_UNITS = 20;

export type Invite = {
  id: string;
  name: string;
  hash: string;
  machines: number;
  owner: boolean;
  revoked: boolean;
  createdAt: number;
  used: string[];
};

export type Registration =
  | { ok: true; invite: string; exempt: boolean }
  | { ok: false; error: "inviteRequired" | "inviteInvalid" | "inviteFull" | "inviteRevoked" };

export type Report = { shut: boolean; revoked: boolean; used: number; limit: number };

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

const CODE_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

/** `perch-xxxx-xxxx-xxxx`: 12 characters from 31, about 59 bits. */
export function newInviteCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  const c = [...bytes].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
  return `perch-${c.slice(0, 4)}-${c.slice(4, 8)}-${c.slice(8, 12)}`;
}

/** What people type: case and spaces do not matter. */
export function normaliseCode(code: string): string {
  return code.trim().toLowerCase().replace(/\s+/g, "");
}

interface AdminEnv {
  ADMIN_TOKEN?: string;
  POOL_DAILY_UNITS?: string;
}

export class RelayAdmin extends DurableObject<AdminEnv> {
  now: () => number = () => Date.now();

  private limit(): number {
    const n = Number(this.env.POOL_DAILY_UNITS);
    return Number.isFinite(n) && n > 0 ? n : POOL_DAILY_UNITS;
  }

  private async invites(): Promise<Map<string, Invite>> {
    return this.ctx.storage.list<Invite>({ prefix: "invite:" });
  }

  private async byCode(code: string): Promise<Invite | null> {
    const hash = await sha256Hex(normaliseCode(code));
    for (const inv of (await this.invites()).values()) {
      if (sameHash(hash, inv.hash)) return inv;
    }
    return null;
  }

  // ---------------------------------------------------------------- RPC from machines

  /** A machine registering for the first time with [code]. A machine already on the invite
   * (it registered again after `forget-devices` kept its id? never; ids rotate) is fine. */
  async register(machineId: string, code: string | null): Promise<Registration> {
    if (!code) return { ok: false, error: "inviteRequired" };
    const inv = await this.byCode(code);
    if (!inv) return { ok: false, error: "inviteInvalid" };
    if (inv.revoked) return { ok: false, error: "inviteRevoked" };
    if (!inv.used.includes(machineId)) {
      if (!inv.owner && inv.used.length >= inv.machines) return { ok: false, error: "inviteFull" };
      inv.used.push(machineId);
      await this.ctx.storage.put(`invite:${inv.id}`, inv);
    }
    await this.ctx.storage.put(`machine:${machineId}`, inv.id);
    return { ok: true, invite: inv.id, exempt: inv.owner };
  }

  /** Whether the invite a machine registered with still holds. */
  async revoked(inviteId: string): Promise<boolean> {
    const inv = await this.ctx.storage.get<Invite>(`invite:${inviteId}`);
    return !inv || inv.revoked;
  }

  /** Adds [units] to today's pool; says whether the pool is shut for friends' machines and
   * whether the machine's invite was revoked. */
  async report(units: number, inviteId: string | null): Promise<Report> {
    const day = utcDay(this.now());
    const key = `pool:${day}`;
    const used = ((await this.ctx.storage.get<number>(key)) ?? 0) + Math.max(0, Math.floor(units));
    await this.ctx.storage.put(key, used);
    const limit = this.limit();
    return { shut: used >= limit, revoked: inviteId ? await this.revoked(inviteId) : false, used, limit };
  }

  /** Today's pool without adding to it. */
  async pool(): Promise<{ day: string; used: number; limit: number; shut: boolean }> {
    const day = utcDay(this.now());
    const used = (await this.ctx.storage.get<number>(`pool:${day}`)) ?? 0;
    const limit = this.limit();
    // Old days are not needed.
    const old = await this.ctx.storage.list({ prefix: "pool:" });
    for (const k of old.keys()) if (k !== `pool:${day}`) await this.ctx.storage.delete(k);
    return { day, used, limit, shut: used >= limit };
  }

  // ---------------------------------------------------------------- the owner's API

  async fetch(request: Request): Promise<Response> {
    const admin = this.env.ADMIN_TOKEN;
    if (!admin) return json(404, { error: "notFound" });
    const auth = request.headers.get("Authorization") ?? "";
    const presented = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
    if (!presented || !sameHash(await sha256Hex(presented), await sha256Hex(admin))) return json(403, { error: "badToken" });
    const parts = new URL(request.url).pathname.split("/").filter((p) => p.length > 0); // admin, ...
    const m = request.method;
    if (parts[1] === "invites" && parts.length === 2 && m === "POST") {
      let body: { name?: unknown; machines?: unknown; owner?: unknown };
      try {
        body = await request.json();
      } catch {
        return json(400, { error: "badJson" });
      }
      const name = typeof body.name === "string" ? body.name.trim().slice(0, 60) : "";
      if (!name) return json(400, { error: "nameRequired" });
      const machines = typeof body.machines === "number" && body.machines >= 1 && body.machines <= 20 ? Math.floor(body.machines) : 3;
      const code = newInviteCode();
      const hash = await sha256Hex(code);
      const inv: Invite = { id: hash.slice(0, 8), name, hash, machines, owner: body.owner === true, revoked: false, createdAt: this.now(), used: [] };
      await this.ctx.storage.put(`invite:${inv.id}`, inv);
      return json(200, { ...view(inv), code });
    }
    if (parts[1] === "invites" && parts.length === 2 && m === "GET") {
      return json(200, { invites: [...(await this.invites()).values()].map(view) });
    }
    if (parts[1] === "invites" && parts.length === 4 && parts[3] === "revoke" && m === "POST") {
      const inv = await this.ctx.storage.get<Invite>(`invite:${parts[2]}`);
      if (!inv) return json(404, { error: "noSuchInvite" });
      inv.revoked = true;
      await this.ctx.storage.put(`invite:${inv.id}`, inv);
      return json(200, { id: inv.id, revoked: true });
    }
    if (parts[1] === "pool" && parts.length === 2 && m === "GET") return json(200, await this.pool());
    return json(404, { error: "notFound" });
  }
}

function view(inv: Invite) {
  return { id: inv.id, name: inv.name, machines: inv.machines, owner: inv.owner, revoked: inv.revoked, createdAt: inv.createdAt, used: inv.used.length };
}
