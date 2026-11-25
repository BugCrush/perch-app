import { SELF } from "cloudflare:test";

let counter = 0;

/** A fresh machine id per test (base64url-like, 22 characters). */
export function newMachineId(): string {
  counter++;
  return `m${Date.now().toString(36)}${counter.toString(36)}`.padEnd(22, "A");
}

export async function sha256Hex(text: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

type Message = string | ArrayBuffer;

/** A WebSocket test client that queues what it receives. */
export class Socket {
  private queue: Message[] = [];
  private waiters: (() => void)[] = [];
  closed: { code: number; reason: string } | null = null;

  /** Keeps messages in order while Blobs are read. */
  private chain: Promise<void> = Promise.resolve();

  constructor(readonly ws: WebSocket) {
    ws.accept();
    ws.addEventListener("message", (e) => {
      const data = e.data as unknown;
      this.chain = this.chain.then(async () => {
        this.queue.push(data instanceof Blob ? await data.arrayBuffer() : (data as Message));
        this.wake();
      });
    });
    ws.addEventListener("close", (e) => {
      this.closed = { code: e.code, reason: e.reason };
      this.wake();
    });
  }

  private wake(): void {
    const w = this.waiters;
    this.waiters = [];
    for (const f of w) f();
  }

  private wait(ms: number): Promise<void> {
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("timed out waiting for a message")), ms);
      this.waiters.push(() => {
        clearTimeout(t);
        resolve();
      });
    });
  }

  /** The next message (removed from the queue). */
  async next(ms = 5000): Promise<Message> {
    while (this.queue.length === 0) {
      if (this.closed) throw new Error(`closed ${this.closed.code} ${this.closed.reason}`);
      await this.wait(ms);
    }
    return this.queue.shift()!;
  }

  async nextJson(ms = 5000): Promise<Record<string, unknown>> {
    const m = await this.next(ms);
    if (typeof m !== "string") throw new Error("expected a text frame");
    return JSON.parse(m);
  }

  async nextBytes(ms = 5000): Promise<Uint8Array> {
    const m = await this.next(ms);
    if (typeof m === "string") throw new Error(`expected a binary frame, got ${m}`);
    return new Uint8Array(m);
  }

  async whenClosed(ms = 5000): Promise<{ code: number; reason: string }> {
    while (!this.closed) await this.wait(ms);
    return this.closed;
  }

  /** True when nothing arrives within [ms]. */
  async silent(ms = 200): Promise<boolean> {
    if (this.queue.length > 0) return false;
    try {
      await this.wait(ms);
    } catch {
      return true;
    }
    return this.queue.length === 0;
  }

  send(data: string | Uint8Array): void {
    this.ws.send(data);
  }

  close(): void {
    try {
      this.ws.close(1000, "done");
    } catch {
      // already closed
    }
  }
}

export async function connect(path: string, headers: Record<string, string> = {}): Promise<{ status: number; socket?: Socket; body?: string }> {
  const res = await SELF.fetch(`https://relay.test${path}`, { headers: { Upgrade: "websocket", ...headers } });
  if (res.status !== 101 || !res.webSocket) return { status: res.status, body: await res.text() };
  return { status: 101, socket: new Socket(res.webSocket) };
}

export const HOST_TOKEN = "host-token-for-tests";
export const DEVICE_TOKEN = "device-token-for-tests";

/** Connects a host, registering the token hashes on first contact. */
export async function connectHost(mid: string, token = HOST_TOKEN): Promise<Socket> {
  const r = await connect(`/m/${mid}/host`, {
    Authorization: `Bearer ${token}`,
    "X-Perch-Device-Token-Hash": await sha256Hex(DEVICE_TOKEN),
  });
  if (!r.socket) throw new Error(`host refused: ${r.status} ${r.body}`);
  return r.socket;
}

export async function connectDevice(mid: string, deviceId: string, token = DEVICE_TOKEN): Promise<Socket> {
  const r = await connect(`/m/${mid}/device?d=${deviceId}&t=${encodeURIComponent(token)}`);
  if (!r.socket) throw new Error(`device refused: ${r.status} ${r.body}`);
  return r.socket;
}

/** [len][id][frame], as the host sends and receives frames. */
export function envelope(deviceId: string, frame: Uint8Array): Uint8Array {
  const id = new TextEncoder().encode(deviceId);
  const out = new Uint8Array(1 + id.length + frame.length);
  out[0] = id.length;
  out.set(id, 1);
  out.set(frame, 1 + id.length);
  return out;
}

export function openEnvelope(bytes: Uint8Array): { deviceId: string; frame: Uint8Array } {
  const len = bytes[0];
  return { deviceId: new TextDecoder().decode(bytes.subarray(1, 1 + len)), frame: bytes.subarray(1 + len) };
}

export function randomFrame(n: number, seed = 1): Uint8Array {
  const b = new Uint8Array(n);
  let x = seed;
  for (let i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    b[i] = x & 0xff;
  }
  return b;
}
