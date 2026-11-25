import { env, runInDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import type { MachineRelay } from "../src/machine";
import type { PushMessage, PushResult, PushSender } from "../src/push";
import {
  connect,
  connectDevice,
  connectHost,
  DEVICE_TOKEN,
  envelope,
  HOST_TOKEN,
  newMachineId,
  openEnvelope,
  randomFrame,
  sha256Hex,
} from "./helpers";

function stubFor(mid: string): DurableObjectStub<MachineRelay> {
  return env.MACHINE.get(env.MACHINE.idFromName(mid));
}

describe("routing", () => {
  it("answers on / and refuses unknown paths", async () => {
    expect(await (await SELF.fetch("https://relay.test/")).text()).toBe("Perch relay\n");
    expect((await SELF.fetch("https://relay.test/m/short/host")).status).toBe(404);
    expect((await SELF.fetch("https://relay.test/other")).status).toBe(404);
    expect((await SELF.fetch(`https://relay.test/m/${newMachineId()}/nothing`)).status).toBe(404);
  });

  it("host and device endpoints need a WebSocket", async () => {
    const mid = newMachineId();
    const r = await SELF.fetch(`https://relay.test/m/${mid}/host`, { headers: { Authorization: `Bearer ${HOST_TOKEN}` } });
    expect(r.status).toBe(426);
  });
});

describe("tokens", () => {
  it("registers both hashes on first contact and stores only hashes", async () => {
    const mid = newMachineId();
    const missing = await connect(`/m/${mid}/host`, { Authorization: `Bearer ${HOST_TOKEN}` });
    expect(missing.status).toBe(400);
    const host = await connectHost(mid);
    const stored = await runInDurableObject(stubFor(mid), async (_i, state) => {
      const all = await state.storage.list();
      return Object.fromEntries(all);
    });
    expect(stored.hostHash).toBe(await sha256Hex(HOST_TOKEN));
    expect(stored.deviceHash).toBe(await sha256Hex(DEVICE_TOKEN));
    expect(JSON.stringify(stored)).not.toContain(HOST_TOKEN);
    expect(JSON.stringify(stored)).not.toContain(DEVICE_TOKEN);
    host.close();
  });

  it("refuses a wrong host token after registration, even with a new device hash", async () => {
    const mid = newMachineId();
    (await connectHost(mid)).close();
    const wrong = await connect(`/m/${mid}/host`, {
      Authorization: "Bearer someone-else",
      "X-Perch-Device-Token-Hash": await sha256Hex("attacker-device-token"),
    });
    expect(wrong.status).toBe(403);
    const noToken = await connect(`/m/${mid}/host`);
    expect(noToken.status).toBe(401);
    // The registered device token still works; the attacker's does not.
    const host = await connectHost(mid);
    expect((await connect(`/m/${mid}/device?d=evil&t=attacker-device-token`)).status).toBe(403);
    const dev = await connectDevice(mid, "phone");
    expect(await host.nextJson()).toEqual({ t: "open", d: "phone" });
    dev.close();
    host.close();
  });

  it("refuses devices with a wrong or missing token, a bad id, or an unknown machine", async () => {
    const mid = newMachineId();
    expect((await connect(`/m/${mid}/device?d=phone&t=${DEVICE_TOKEN}`)).status).toBe(403); // not registered
    const host = await connectHost(mid);
    expect((await connect(`/m/${mid}/device?d=phone&t=wrong`)).status).toBe(403);
    expect((await connect(`/m/${mid}/device?d=phone`)).status).toBe(401);
    expect((await connect(`/m/${mid}/device?d=bad%20id&t=${DEVICE_TOKEN}`)).status).toBe(400);
    expect((await connect(`/m/${mid}/device?d=${"x".repeat(65)}&t=${DEVICE_TOKEN}`)).status).toBe(400);
    // A host token is not a device token.
    expect((await connect(`/m/${mid}/device?d=phone&t=${HOST_TOKEN}`)).status).toBe(403);
    // The header works as well as the query parameter.
    const viaHeader = await connect(`/m/${mid}/device?d=phone`, { Authorization: `Bearer ${DEVICE_TOKEN}` });
    expect(viaHeader.status).toBe(101);
    viaHeader.socket!.close();
    host.close();
  });

  it("a newer host connection replaces the older one", async () => {
    const mid = newMachineId();
    const first = await connectHost(mid);
    const second = await connectHost(mid);
    expect((await first.whenClosed()).code).toBe(4000);
    second.close();
  });
});

describe("forwarding", () => {
  it("forwards frames both ways and adds only the device id", async () => {
    const mid = newMachineId();
    const host = await connectHost(mid);
    const phone = await connectDevice(mid, "phone");
    const laptop = await connectDevice(mid, "laptop");
    expect(await host.nextJson()).toEqual({ t: "open", d: "phone" });
    expect(await host.nextJson()).toEqual({ t: "open", d: "laptop" });

    const f1 = randomFrame(300, 1);
    phone.send(f1);
    const got = openEnvelope(await host.nextBytes());
    expect(got.deviceId).toBe("phone");
    expect([...got.frame]).toEqual([...f1]);

    const f2 = randomFrame(200, 2);
    laptop.send(f2);
    const got2 = openEnvelope(await host.nextBytes());
    expect(got2.deviceId).toBe("laptop");
    expect([...got2.frame]).toEqual([...f2]);

    const back = randomFrame(500, 3);
    host.send(envelope("laptop", back));
    expect([...(await laptop.nextBytes())]).toEqual([...back]);
    expect(await phone.silent()).toBe(true);

    phone.close();
    expect(await host.nextJson()).toEqual({ t: "close", d: "phone" });
    // A frame for a device that left: the host is told it is gone.
    host.send(envelope("phone", randomFrame(10)));
    expect(await host.nextJson()).toEqual({ t: "close", d: "phone" });
    laptop.close();
    host.close();
  });

  it("the host can close one device", async () => {
    const mid = newMachineId();
    const host = await connectHost(mid);
    const phone = await connectDevice(mid, "phone");
    await host.nextJson();
    host.send(JSON.stringify({ t: "close", d: "phone", code: 4003, reason: "badKey" }));
    const c = await phone.whenClosed();
    expect(c.code).toBe(4003);
    host.close();
  });

  it("a device id connecting again replaces its older connection", async () => {
    const mid = newMachineId();
    const host = await connectHost(mid);
    const a = await connectDevice(mid, "phone");
    expect(await host.nextJson()).toEqual({ t: "open", d: "phone" });
    const b = await connectDevice(mid, "phone");
    expect(await host.nextJson()).toEqual({ t: "close", d: "phone" });
    expect(await host.nextJson()).toEqual({ t: "open", d: "phone" });
    expect((await a.whenClosed()).code).toBe(4000);
    // The old socket closing does not close the new one at the host.
    expect(await host.silent(300)).toBe(true);
    b.send(randomFrame(5));
    expect(openEnvelope(await host.nextBytes()).deviceId).toBe("phone");
    b.close();
    host.close();
  });

  it("tells devices hostOffline and hostOnline and queues nothing", async () => {
    const mid = newMachineId();
    (await connectHost(mid)).close(); // registers, then goes away
    const phone = await connectDevice(mid, "phone");
    expect(await phone.nextJson()).toEqual({ t: "hostOffline" });
    phone.send(randomFrame(20));
    expect(await phone.nextJson()).toEqual({ t: "hostOffline" });

    const host = await connectHost(mid);
    expect(await phone.nextJson()).toEqual({ t: "hostOnline" });
    // The frame sent while the host was away was dropped, not queued.
    expect(await host.silent(300)).toBe(true);

    host.close();
    expect(await phone.nextJson()).toEqual({ t: "hostOffline" });
    phone.close();
  });

  it("forwards a large message split into 900 KB chunks, in order", async () => {
    const mid = newMachineId();
    const host = await connectHost(mid);
    const phone = await connectDevice(mid, "phone");
    await host.nextJson();
    // As the encrypted channel sends a 2.3 MB history page: 3 frames under 1 MiB each.
    const total = randomFrame(2_300_000, 7);
    const chunk = 900 * 1024;
    const frames: Uint8Array[] = [];
    for (let i = 0; i < total.length; i += chunk) {
      const body = total.subarray(i, Math.min(i + chunk, total.length));
      const f = new Uint8Array(1 + body.length);
      f[0] = i + chunk >= total.length ? 2 : 1;
      f.set(body, 1);
      frames.push(f);
    }
    expect(frames.length).toBe(3);
    for (const f of frames) host.send(envelope("phone", f));
    const parts: Uint8Array[] = [];
    for (;;) {
      const f = await phone.nextBytes();
      parts.push(f.subarray(1));
      if (f[0] === 2) break;
    }
    const joined = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let o = 0;
    for (const p of parts) {
      joined.set(p, o);
      o += p.length;
    }
    expect(joined.length).toBe(total.length);
    expect(joined.every((b, i) => b === total[i])).toBe(true);
    phone.close();
    host.close();
  });

  it("answers the host's ping with pong", async () => {
    const mid = newMachineId();
    const host = await connectHost(mid);
    host.send("ping");
    expect(await host.next()).toBe("pong");
    host.close();
  });
});

class RecordingSender implements PushSender {
  sent: PushMessage[] = [];
  results: Record<string, PushResult> = {};
  async send(m: PushMessage): Promise<PushResult> {
    this.sent.push(m);
    return this.results[m.deviceId] ?? { ok: true, status: 200 };
  }
}

async function post(path: string, token: string | null, body: unknown): Promise<Response> {
  return SELF.fetch(`https://relay.test${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
}

describe("push", () => {
  it("stores a device's push token, refuses a wrong token, and deletes on null", async () => {
    const mid = newMachineId();
    (await connectHost(mid)).close();
    expect((await post(`/m/${mid}/devices/phone/push-token`, "wrong", { token: "fcm-1" })).status).toBe(403);
    expect((await post(`/m/${mid}/devices/phone/push-token`, HOST_TOKEN, { token: "fcm-1" })).status).toBe(403);
    expect((await post(`/m/${mid}/devices/phone/push-token`, DEVICE_TOKEN, { token: "fcm-1" })).status).toBe(200);
    const stored = await runInDurableObject(stubFor(mid), (_i, state) => state.storage.get<{ token: string }>("push:phone"));
    expect(stored?.token).toBe("fcm-1");
    expect((await post(`/m/${mid}/devices/phone/push-token`, DEVICE_TOKEN, { token: null })).status).toBe(200);
    const gone = await runInDurableObject(stubFor(mid), (_i, state) => state.storage.get("push:phone"));
    expect(gone).toBeUndefined();
  });

  it("passes the encrypted payload to the sender untouched, per device", async () => {
    const mid = newMachineId();
    (await connectHost(mid)).close();
    await post(`/m/${mid}/devices/phone/push-token`, DEVICE_TOKEN, { token: "fcm-phone" });
    await post(`/m/${mid}/devices/tablet/push-token`, DEVICE_TOKEN, { token: "fcm-tablet" });
    const sender = new RecordingSender();
    await runInDurableObject(stubFor(mid), (instance: MachineRelay) => {
      instance.pushSender = sender;
    });
    const payload = btoa(String.fromCharCode(...randomFrame(180, 9)));
    expect((await post(`/m/${mid}/push`, DEVICE_TOKEN, { payload })).status).toBe(403);
    const r = await post(`/m/${mid}/push`, HOST_TOKEN, { payload, collapseKey: "session-1" });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ sent: 2, failed: 0 });
    expect(sender.sent.map((m) => m.token).sort()).toEqual(["fcm-phone", "fcm-tablet"]);
    for (const m of sender.sent) {
      expect(m.payload).toBe(payload);
      expect(m.priority).toBe("high");
      expect(m.collapseKey).toBe("session-1");
    }

    // Only some devices; a token the push service no longer knows is forgotten.
    sender.sent = [];
    sender.results.tablet = { ok: false, status: 404, unregistered: true };
    const r2 = await post(`/m/${mid}/push`, HOST_TOKEN, { payload, devices: ["tablet"], priority: "normal" });
    expect(await r2.json()).toEqual({ sent: 0, failed: 1 });
    expect(sender.sent.map((m) => m.deviceId)).toEqual(["tablet"]);
    expect(sender.sent[0].priority).toBe("normal");
    const gone = await runInDurableObject(stubFor(mid), (_i, state) => state.storage.get("push:tablet"));
    expect(gone).toBeUndefined();
  });

  it("refuses bad push requests and reports push as not configured by default", async () => {
    const mid = newMachineId();
    (await connectHost(mid)).close();
    await post(`/m/${mid}/devices/phone/push-token`, DEVICE_TOKEN, { token: "fcm-phone" });
    expect((await post(`/m/${mid}/push`, HOST_TOKEN, { payload: "" })).status).toBe(400);
    expect((await post(`/m/${mid}/push`, HOST_TOKEN, { payload: "x".repeat(3001) })).status).toBe(400);
    const r = await post(`/m/${mid}/push`, HOST_TOKEN, { payload: "abc" });
    expect(await r.json()).toEqual({ sent: 0, failed: 1 });
  });
});

describe("daily cap per machine", () => {
  it("messages_over_the_daily_cap_close_with_4029", async () => {
    const mid = newMachineId();
    const host = await connectHost(mid);
    const phone = await connectDevice(mid, "phone");
    expect(await host.nextJson()).toEqual({ t: "open", d: "phone" });
    await runInDurableObject(stubFor(mid), (instance: MachineRelay) => {
      instance.messageLimit = 3;
    });
    phone.send(randomFrame(10, 1));
    await host.nextBytes();
    host.send(envelope("phone", randomFrame(10, 2)));
    await phone.nextBytes();
    phone.send(randomFrame(10, 3));
    await host.nextBytes();
    // The fourth message of the day is dropped and every socket of the machine is closed.
    phone.send(randomFrame(10, 4));
    expect(await host.whenClosed()).toEqual({ code: 4029, reason: "daily limit" });
    expect((await phone.whenClosed()).code).toBe(4029);
    // A new connection today is closed at once the same way; push is refused.
    const again = await connectHost(mid);
    expect((await again.whenClosed()).code).toBe(4029);
    const push = await post(`/m/${mid}/push`, HOST_TOKEN, { payload: "abc" });
    expect(push.status).toBe(429);
    // The count is kept in storage.
    const stored = await runInDurableObject(stubFor(mid), (_i, state) =>
      state.storage.get<number>(`count:${new Date().toISOString().slice(0, 10)}`),
    );
    expect(stored).toBeGreaterThanOrEqual(3);
  });

  it("the_count_resets_on_a_new_utc_day", async () => {
    const mid = newMachineId();
    const host = await connectHost(mid);
    const phone = await connectDevice(mid, "phone");
    await host.nextJson();
    await runInDurableObject(stubFor(mid), (instance: MachineRelay) => {
      instance.messageLimit = 2;
    });
    phone.send(randomFrame(10, 1));
    await host.nextBytes();
    phone.send(randomFrame(10, 2));
    await host.nextBytes();
    await runInDurableObject(stubFor(mid), (instance: MachineRelay) => {
      instance.now = () => Date.now() + 24 * 60 * 60 * 1000;
    });
    phone.send(randomFrame(10, 3));
    const got = openEnvelope(await host.nextBytes());
    expect(got.deviceId).toBe("phone");
    expect(host.closed).toBeNull();
    host.close();
    phone.close();
  });

  it("usage_needs_the_host_token", async () => {
    const mid = newMachineId();
    const host = await connectHost(mid);
    const phone = await connectDevice(mid, "phone");
    await host.nextJson();
    phone.send(randomFrame(10, 1));
    await host.nextBytes();
    const asDevice = await SELF.fetch(`https://relay.test/m/${mid}/usage`, { headers: { Authorization: `Bearer ${DEVICE_TOKEN}` } });
    expect(asDevice.status).toBe(403);
    const r = await SELF.fetch(`https://relay.test/m/${mid}/usage`, { headers: { Authorization: `Bearer ${HOST_TOKEN}` } });
    expect(r.status).toBe(200);
    expect(await r.json()).toMatchObject({ messagesToday: 1, messageLimit: 50000, exempt: true });
    host.close();
    phone.close();
  });
});
