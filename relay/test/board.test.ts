// The board store: each board's sealed records (the relay never reads them), trust on first
// use of the board token, changes by sequence number, newer versions only, the daily write
// cap (5,000) and the size cap (20 MB), delete, usage.
import { env, runInDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import type { BoardStore } from "../src/board";

let n = 0;
/** A fresh board id per test: 22 base64url characters. */
function newBoardId(): string {
  n++;
  return `b${Date.now().toString(36)}${n.toString(36)}`.padEnd(22, "Z").slice(0, 22);
}

const TOKEN = "board-token-for-tests";

function req(method: string, path: string, body?: unknown, token = TOKEN): Promise<Response> {
  return SELF.fetch(`https://relay.test${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

type Rec = { key: string; version: string; data: string };
const v = (ms: number, w = "phone") => `${String(ms).padStart(15, "0")}-000000-${w}`;

async function put(id: string, records: Rec[], token = TOKEN): Promise<Response> {
  return req("PUT", `/b/${id}/records`, { records }, token);
}

async function changes(id: string, after = 0): Promise<{ seq: number; more?: boolean; records: (Rec & { seq?: number })[] }> {
  const r = await req("GET", `/b/${id}/changes?after=${after}`);
  expect(r.status).toBe(200);
  return r.json();
}

function stub(id: string): DurableObjectStub<BoardStore> {
  return env.BOARD.get(env.BOARD.idFromName(id));
}

describe("board store", () => {
  it("first_token_is_trusted_others_get_401", async () => {
    const id = newBoardId();
    expect((await put(id, [{ key: "task/a", version: v(1), data: "sealed-a" }])).status).toBe(200);
    expect((await put(id, [{ key: "task/b", version: v(1), data: "x" }], "someone-else")).status).toBe(401);
    expect((await req("GET", `/b/${id}/changes?after=0`, undefined, "someone-else")).status).toBe(401);
    const noAuth = await SELF.fetch(`https://relay.test/b/${id}/changes?after=0`);
    expect(noAuth.status).toBe(401);
    const stored = await runInDurableObject(stub(id), async (_i, state) => Object.fromEntries(await state.storage.list()));
    expect(JSON.stringify(stored)).not.toContain(TOKEN);
  });

  it("routes_only_well_formed_board_ids", async () => {
    expect((await req("GET", "/b/short/changes?after=0")).status).toBe(404);
    expect((await req("GET", `/b/${newBoardId()}/nothing`)).status).toBe(404);
  });

  it("put_then_changes_returns_them_in_seq_order", async () => {
    const id = newBoardId();
    await put(id, [
      { key: "task/a", version: v(1), data: "A" },
      { key: "project/p", version: v(1), data: "P" },
    ]);
    await put(id, [{ key: "task/b", version: v(2), data: "B" }]);
    const all = await changes(id);
    expect(all.records.map((r) => r.key)).toEqual(["task/a", "project/p", "task/b"]);
    expect(all.seq).toBe(3);
    const later = await changes(id, 2);
    expect(later.records.map((r) => r.key)).toEqual(["task/b"]);
    expect((await changes(id, 3)).records).toEqual([]);
    expect((await changes(id, 3)).seq).toBe(3);
    // A newer version of a record moves it to the end.
    await put(id, [{ key: "task/a", version: v(5), data: "A2" }]);
    const after = await changes(id, 3);
    expect(after.records).toEqual([{ key: "task/a", version: v(5), data: "A2" }]);
  });

  it("pages_of_at_most_500", async () => {
    const id = newBoardId();
    const recs: Rec[] = [];
    for (let i = 0; i < 520; i++) recs.push({ key: `task/t${i}`, version: v(1), data: "d" });
    expect((await put(id, recs.slice(0, 260))).status).toBe(200);
    expect((await put(id, recs.slice(260))).status).toBe(200);
    const first = await changes(id);
    expect(first.records.length).toBe(500);
    expect(first.more).toBe(true);
    expect(first.seq).toBe(500);
    const rest = await changes(id, first.seq);
    expect(rest.records.length).toBe(20);
    expect(rest.more).toBe(false);
  });

  it("an_older_version_is_ignored", async () => {
    const id = newBoardId();
    await put(id, [{ key: "task/a", version: v(5), data: "new" }]);
    const r = await put(id, [
      { key: "task/a", version: v(4), data: "old" },
      { key: "task/a", version: v(5), data: "same" },
    ]);
    expect(await r.json()).toMatchObject({ stored: 0 });
    expect((await changes(id)).records).toEqual([{ key: "task/a", version: v(5), data: "new" }]);
  });

  it("refuses_malformed_records", async () => {
    const id = newBoardId();
    expect((await req("PUT", `/b/${id}/records`, { records: "no" })).status).toBe(400);
    expect((await put(id, [{ key: "", version: v(1), data: "x" }])).status).toBe(400);
    expect((await put(id, [{ key: "task/a", version: 3 as unknown as string, data: "x" }])).status).toBe(400);
    const bad = await SELF.fetch(`https://relay.test/b/${id}/records`, {
      method: "PUT",
      headers: { Authorization: `Bearer ${TOKEN}` },
      body: "{not json",
    });
    expect(bad.status).toBe(400);
  });

  it("daily_write_cap_answers_429", async () => {
    const id = newBoardId();
    await put(id, [{ key: "task/first", version: v(1), data: "x" }]);
    await runInDurableObject(stub(id), async (instance) => {
      instance.writeLimit = 3;
    });
    expect((await put(id, [{ key: "task/a", version: v(1), data: "x" }, { key: "task/b", version: v(1), data: "x" }])).status).toBe(200);
    const over = await put(id, [{ key: "task/c", version: v(1), data: "x" }]);
    expect(over.status).toBe(429);
    expect(await over.json()).toEqual({ error: "daily limit" });
    expect((await changes(id)).records.map((r) => r.key)).not.toContain("task/c");
    // Reading still works over the cap.
    expect((await req("GET", `/b/${id}/usage`)).status).toBe(200);
    // A new UTC day starts the count again.
    await runInDurableObject(stub(id), async (instance) => {
      instance.now = () => Date.now() + 24 * 60 * 60 * 1000;
    });
    expect((await put(id, [{ key: "task/c", version: v(1), data: "x" }])).status).toBe(200);
  });

  it("size_cap_answers_429", async () => {
    const id = newBoardId();
    await runInDurableObject(stub(id), async (instance) => {
      instance.byteLimit = 1000;
    });
    expect((await put(id, [{ key: "task/a", version: v(1), data: "x".repeat(600) }])).status).toBe(200);
    const full = await put(id, [{ key: "task/b", version: v(1), data: "y".repeat(600) }]);
    expect(full.status).toBe(429);
    expect(await full.json()).toEqual({ error: "board full" });
    // Replacing a record with a smaller one fits.
    expect((await put(id, [{ key: "task/a", version: v(2), data: "x".repeat(100) }])).status).toBe(200);
    expect((await put(id, [{ key: "task/b", version: v(1), data: "y".repeat(600) }])).status).toBe(200);
  });

  it("usage_reports_today_and_the_caps", async () => {
    const id = newBoardId();
    await put(id, [
      { key: "task/a", version: v(1), data: "abc" },
      { key: "task/b", version: v(1), data: "de" },
    ]);
    const u = (await (await req("GET", `/b/${id}/usage`)).json()) as Record<string, number>;
    expect(u.writesToday).toBe(2);
    expect(u.writeLimit).toBe(5000);
    expect(u.byteLimit).toBe(20971520);
    expect(u.bytes).toBeGreaterThan(5);
  });

  it("delete_wipes_the_board", async () => {
    const id = newBoardId();
    await put(id, [{ key: "task/a", version: v(1), data: "x" }]);
    expect((await req("DELETE", `/b/${id}`, undefined, "someone-else")).status).toBe(401);
    expect((await req("DELETE", `/b/${id}`)).status).toBe(200);
    const stored = await runInDurableObject(stub(id), async (_i, state) =>
      state.storage.sql.exec("SELECT count(*) AS n FROM records").one(),
    );
    expect(stored.n).toBe(0);
    // A deleted board stays gone: an old device cannot bring it back.
    expect((await req("GET", `/b/${id}/changes?after=0`)).status).toBe(410);
    expect((await put(id, [{ key: "task/a", version: v(9), data: "x" }])).status).toBe(410);
  });

  it("the_relay_never_needs_the_plaintext", async () => {
    const id = newBoardId();
    const sealed = "AQ" + "x/+=".repeat(200) + "é";
    await put(id, [{ key: "task/a", version: v(1), data: sealed }]);
    expect((await changes(id)).records[0].data).toBe(sealed);
  });
});
