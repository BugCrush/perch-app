// One Durable Object per board (docs/superpowers/specs/2026-11-24-projects-first-board-design.md,
// section 5): the board's records, each sealed by the owner's devices with the board key.
// The store sees a record's key, a version string (a hybrid clock, compared as a string),
// its size and when it changes; never a title, a description or a report.
//
// GET    /b/<id>/changes?after=<seq>  -> {"seq", "more", "records": [{"key","version","data"}]} (<= 500, by seq)
// PUT    /b/<id>/records {"records": [...]} -> {"seq", "stored"}; only versions newer than the stored one
// DELETE /b/<id>                      -> wipes the board; afterwards every request answers 410
// GET    /b/<id>/usage                -> {"writesToday", "writeLimit", "bytes", "byteLimit"}
//
// Auth: `Authorization: Bearer <token>`; the first token seen is kept as a SHA-256 hash
// (trust on first use, as the machine relay does). Caps: 5,000 stored records a UTC day and
// 20 MB per board; over either the store answers 429 and the devices keep their own copies.
import { DurableObject } from "cloudflare:workers";

import { sameHash, sha256Hex, tokenOf } from "./protocol";

export const BOARD_WRITE_LIMIT = 5000;
export const BOARD_BYTE_LIMIT = 20 * 1024 * 1024;
const PAGE = 500;
const MAX_RECORDS_PER_PUT = 500;
const MAX_KEY = 200;
const MAX_VERSION = 128;
const MAX_DATA = 2 * 1024 * 1024;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

type Meta = { tokenHash?: string; deleted?: boolean; seq: number; bytes: number; day: string; writes: number };

export class BoardStore extends DurableObject {
  /** Replaceable in tests. */
  writeLimit = BOARD_WRITE_LIMIT;
  byteLimit = BOARD_BYTE_LIMIT;
  now: () => number = () => Date.now();

  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env as never);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(
        "CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY, version TEXT NOT NULL, seq INTEGER NOT NULL, data TEXT NOT NULL)",
      );
      this.ctx.storage.sql.exec("CREATE INDEX IF NOT EXISTS records_seq ON records (seq)");
    });
  }

  private async meta(): Promise<Meta> {
    const m = (await this.ctx.storage.get<Meta>("meta")) ?? { seq: 0, bytes: 0, day: "", writes: 0 };
    const today = utcDay(this.now());
    if (m.day !== today) {
      m.day = today;
      m.writes = 0;
    }
    return m;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter((p) => p.length > 0); // b, <id>, ...
    const action = parts[2] ?? "";
    const token = tokenOf(request, url);
    if (!token) return json(401, { error: "noToken" });
    const meta = await this.meta();
    const presented = await sha256Hex(token);
    if (meta.tokenHash === undefined) {
      meta.tokenHash = presented;
      await this.ctx.storage.put("meta", meta);
    } else if (!sameHash(presented, meta.tokenHash)) {
      return json(401, { error: "badToken" });
    }
    if (meta.deleted) return json(410, { error: "deleted" });

    if (parts.length === 2 && request.method === "DELETE") {
      this.ctx.storage.sql.exec("DELETE FROM records");
      await this.ctx.storage.put("meta", { tokenHash: meta.tokenHash, deleted: true, seq: meta.seq, bytes: 0, day: meta.day, writes: meta.writes });
      return json(200, { deleted: true });
    }
    if (action === "changes" && request.method === "GET") return this.changes(url, meta);
    if (action === "records" && request.method === "PUT") return this.put(request, meta);
    if (action === "usage" && request.method === "GET") {
      return json(200, { writesToday: meta.writes, writeLimit: this.writeLimit, bytes: meta.bytes, byteLimit: this.byteLimit });
    }
    return json(404, { error: "notFound" });
  }

  private changes(url: URL, meta: Meta): Response {
    const after = Math.max(0, Number.parseInt(url.searchParams.get("after") ?? "0", 10) || 0);
    const rows = this.ctx.storage.sql
      .exec<{ key: string; version: string; seq: number; data: string }>(
        "SELECT key, version, seq, data FROM records WHERE seq > ? ORDER BY seq LIMIT ?",
        after,
        PAGE + 1,
      )
      .toArray();
    const more = rows.length > PAGE;
    const page = more ? rows.slice(0, PAGE) : rows;
    return json(200, {
      seq: page.length > 0 ? page[page.length - 1].seq : meta.seq,
      more,
      records: page.map((r) => ({ key: r.key, version: r.version, data: r.data })),
    });
  }

  private async put(request: Request, meta: Meta): Promise<Response> {
    let body: { records?: unknown };
    try {
      body = await request.json();
    } catch {
      return json(400, { error: "badJson" });
    }
    if (!Array.isArray(body.records) || body.records.length > MAX_RECORDS_PER_PUT) return json(400, { error: "badRecords" });
    const incoming: { key: string; version: string; data: string }[] = [];
    for (const r of body.records as unknown[]) {
      const o = r as { key?: unknown; version?: unknown; data?: unknown } | null;
      if (
        !o ||
        typeof o.key !== "string" ||
        typeof o.version !== "string" ||
        typeof o.data !== "string" ||
        o.key.length === 0 ||
        o.key.length > MAX_KEY ||
        o.version.length === 0 ||
        o.version.length > MAX_VERSION ||
        o.data.length > MAX_DATA
      ) {
        return json(400, { error: "badRecord" });
      }
      incoming.push({ key: o.key, version: o.version, data: o.data });
    }
    // Only newer versions are stored (the last of a key in one request counts).
    const winners = new Map<string, { key: string; version: string; data: string; oldSize: number }>();
    for (const r of incoming) {
      const prev = winners.get(r.key);
      if (prev && !(r.version > prev.version)) continue;
      const stored = this.ctx.storage.sql
        .exec<{ version: string; size: number }>(
          "SELECT version, length(key) + length(version) + length(data) AS size FROM records WHERE key = ?",
          r.key,
        )
        .toArray()[0];
      if (stored && !(r.version > stored.version)) continue;
      winners.set(r.key, { ...r, oldSize: stored ? stored.size : 0 });
    }
    if (winners.size === 0) return json(200, { seq: meta.seq, stored: 0 });
    if (meta.writes + winners.size > this.writeLimit) return json(429, { error: "daily limit" });
    let bytes = meta.bytes;
    for (const w of winners.values()) bytes += w.key.length + w.version.length + w.data.length - w.oldSize;
    if (bytes > this.byteLimit) return json(429, { error: "board full" });
    let seq = meta.seq;
    for (const w of winners.values()) {
      seq++;
      this.ctx.storage.sql.exec(
        "INSERT INTO records (key, version, seq, data) VALUES (?, ?, ?, ?) " +
          "ON CONFLICT(key) DO UPDATE SET version = excluded.version, seq = excluded.seq, data = excluded.data",
        w.key,
        w.version,
        seq,
        w.data,
      );
    }
    meta.seq = seq;
    meta.bytes = bytes;
    meta.writes += winners.size;
    await this.ctx.storage.put("meta", meta);
    return json(200, { seq, stored: winners.size });
  }
}
