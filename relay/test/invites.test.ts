import { env, runInDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import type { RelayAdmin } from "../src/admin";
import type { MachineRelay } from "../src/machine";
import { DEVICE_TOKEN, HOST_TOKEN, newMachineId, sha256Hex } from "./helpers";

const ADMIN = "test-admin-token";

function machine(mid: string): DurableObjectStub<MachineRelay> {
  return env.MACHINE.get(env.MACHINE.idFromName(mid));
}

function adminStub(): DurableObjectStub<RelayAdmin> {
  return env.ADMIN.get(env.ADMIN.idFromName("admin"));
}

async function admin(method: string, path: string, body?: unknown, token = ADMIN): Promise<Response> {
  return SELF.fetch(`https://relay.test/admin/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function invite(name: string, extra: Record<string, unknown> = {}): Promise<{ id: string; code: string }> {
  const r = await admin("POST", "invites", { name, ...extra });
  expect(r.status).toBe(200);
  return (await r.json()) as { id: string; code: string };
}

/** A machine that needs an invite (invites are off in the other test files). */
async function strictMachine(opts: { reportEvery?: number } = {}): Promise<string> {
  const mid = newMachineId();
  await runInDurableObject(machine(mid), (i: MachineRelay) => {
    i.invitesRequired = true;
    if (opts.reportEvery) i.reportEvery = opts.reportEvery;
  });
  return mid;
}

async function check(mid: string, code?: string): Promise<Response> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${HOST_TOKEN}`,
    "X-Perch-Device-Token-Hash": await sha256Hex(DEVICE_TOKEN),
  };
  if (code) headers["X-Perch-Invite"] = code;
  return SELF.fetch(`https://relay.test/m/${mid}/check`, { headers });
}

describe("invites", () => {
  it("the admin API needs the admin token", async () => {
    expect((await admin("GET", "invites", undefined, "wrong")).status).toBe(403);
    expect((await admin("GET", "invites", undefined, "")).status).toBe(403);
    expect((await admin("GET", "invites")).status).toBe(200);
  });

  it("a new machine needs a valid code; the code is kept only as a hash", async () => {
    const inv = await invite("Alex");
    expect(inv.code).toMatch(/^perch-[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}$/);
    const mid = await strictMachine();
    expect(await (await check(mid)).json()).toEqual({ error: "inviteRequired" });
    expect(await (await check(mid, "perch-aaaa-bbbb-cccc")).json()).toEqual({ error: "inviteInvalid" });
    // Typed with capitals and spaces.
    const r = await check(mid, ` ${inv.code.toUpperCase()} `);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, exempt: false });
    const stored = await runInDurableObject(adminStub(), (_i, state) => state.storage.list({ prefix: "invite:" }));
    expect(JSON.stringify([...stored.values()])).not.toContain(inv.code);
    // Registered: later connections need no code.
    expect((await check(mid)).status).toBe(200);
  });

  it("an invite serves only as many machines as it allows; an owner invite any number, exempt", async () => {
    const one = await invite("Sam", { machines: 1 });
    expect((await check(await strictMachine(), one.code)).status).toBe(200);
    expect(await (await check(await strictMachine(), one.code)).json()).toEqual({ error: "inviteFull" });
    const owner = await invite("Owner", { owner: true, machines: 1 });
    for (let i = 0; i < 3; i++) {
      expect(await (await check(await strictMachine(), owner.code)).json()).toEqual({ ok: true, exempt: true });
    }
  });

  it("a revoked invite shuts its machines out", async () => {
    const inv = await invite("Kim");
    const mid = await strictMachine();
    expect((await check(mid, inv.code)).status).toBe(200);
    expect((await admin("POST", `invites/${inv.id}/revoke`)).status).toBe(200);
    expect(await (await check(mid)).json()).toEqual({ error: "inviteRevoked" });
    expect(await (await check(await strictMachine(), inv.code)).json()).toEqual({ error: "inviteRevoked" });
    const list = (await (await admin("GET", "invites")).json()) as { invites: { id: string; revoked: boolean; used: number }[] };
    expect(list.invites.find((i) => i.id === inv.id)).toMatchObject({ revoked: true, used: 1 });
  });

  it("machines registered before invites (the owner's) are exempt", async () => {
    const mid = newMachineId(); // invites off
    expect(await (await check(mid)).json()).toEqual({ ok: true, exempt: true });
  });
});

describe("shared pool", () => {
  it("counts requests and messages; when used up, friends' machines are refused and the owner's are not", async () => {
    const friend = await invite("Pat");
    const owner = await invite("Me", { owner: true });
    const f = await strictMachine({ reportEvery: 1 });
    const o = await strictMachine({ reportEvery: 1 });
    expect((await check(f, friend.code)).status).toBe(200);
    expect((await check(o, owner.code)).status).toBe(200);
    const pool = (await (await admin("GET", "pool")).json()) as { used: number; limit: number; shut: boolean };
    expect(pool.used).toBeGreaterThanOrEqual(40); // two requests, 20 units each
    expect(pool.limit).toBe(1_200_000);
    expect(pool.shut).toBe(false);
    // Nearly used up: the next request tips it over.
    await runInDurableObject(adminStub(), (_i, state) => state.storage.put(`pool:${new Date().toISOString().slice(0, 10)}`, 1_199_990));
    await check(f);
    expect(await (await check(f)).json()).toEqual({ error: "poolUsedUp" });
    await check(o);
    expect(await (await check(o)).json()).toEqual({ ok: true, exempt: true });
    expect(((await (await admin("GET", "pool")).json()) as { shut: boolean }).shut).toBe(true);
    // The usage answer shows the pool to the host.
    const u = await SELF.fetch(`https://relay.test/m/${o}/usage`, { headers: { Authorization: `Bearer ${HOST_TOKEN}` } });
    expect(await u.json()).toMatchObject({ exempt: true, pool: { shut: true, limit: 1_200_000 } });
    await runInDurableObject(adminStub(), (_i, state) => state.storage.put(`pool:${new Date().toISOString().slice(0, 10)}`, 0));
  });
});
