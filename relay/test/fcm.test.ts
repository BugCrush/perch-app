import { env, runInDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import type { MachineRelay } from "../src/machine";
import { FcmPushSender, parseServiceAccount, TokenCache, type ServiceAccount } from "../src/push";
import { connectHost, DEVICE_TOKEN, HOST_TOKEN, newMachineId } from "./helpers";

// ---------------------------------------------------------------- test key and fake Google

function b64(bytes: ArrayBuffer): string {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s);
}

function b64urlDecode(s: string): Uint8Array {
  const pad = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(pad), (c) => c.charCodeAt(0));
}

const ALG = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" } as const;

async function testAccount(): Promise<{ account: ServiceAccount; publicKey: CryptoKey }> {
  const pair = (await crypto.subtle.generateKey(
    { ...ALG, modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const der = (await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer;
  const body = b64(der).replace(/(.{64})/g, "$1\n");
  const pem = `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`;
  return {
    account: {
      project_id: "perch-test",
      client_email: "push@perch-test.iam.gserviceaccount.com",
      private_key: pem,
      token_uri: "https://oauth2.googleapis.com/token",
    },
    publicKey: pair.publicKey,
  };
}

type Call = { url: string; init: RequestInit; body: string };

/** A fake fetch for Google's token and FCM endpoints. */
class FakeGoogle {
  calls: Call[] = [];
  tokenCalls = 0;
  /** FCM answers by device token; default 200. */
  fcm: Record<string, { status: number; body: unknown }> = {};
  /** Answers the next FCM calls with these, in order, before [fcm]. */
  fcmQueue: { status: number; body: unknown }[] = [];
  expiresIn = 3600;

  fetch = async (input: RequestInfo | URL, init: RequestInit = {}): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const body = typeof init.body === "string" ? init.body : "";
    this.calls.push({ url, init, body });
    if (url === "https://oauth2.googleapis.com/token") {
      this.tokenCalls++;
      return Response.json({ access_token: `access-${this.tokenCalls}`, expires_in: this.expiresIn, token_type: "Bearer" });
    }
    if (url.startsWith("https://fcm.googleapis.com/v1/projects/")) {
      const queued = this.fcmQueue.shift();
      if (queued) return Response.json(queued.body, { status: queued.status });
      const token = JSON.parse(body).message.token as string;
      const r = this.fcm[token] ?? { status: 200, body: { name: "projects/perch-test/messages/1" } };
      return Response.json(r.body, { status: r.status });
    }
    return new Response("unexpected", { status: 599 });
  };

  fcmCalls(): Call[] {
    return this.calls.filter((c) => c.url.startsWith("https://fcm.googleapis.com/"));
  }
}

const unregistered = {
  status: 404,
  body: {
    error: {
      code: 404,
      message: "Requested entity was not found.",
      status: "NOT_FOUND",
      details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "UNREGISTERED" }],
    },
  },
};

// ---------------------------------------------------------------- sender

describe("FCM sender", () => {
  it("signs a service-account JWT with RS256 and exchanges it for an access token", async () => {
    const { account, publicKey } = await testAccount();
    const google = new FakeGoogle();
    const now = 1_800_000_000_000;
    const sender = new FcmPushSender(account, { fetch: google.fetch, now: () => now, cache: new TokenCache() });
    const r = await sender.send({ token: "fcm-1", deviceId: "phone", machineId: "machine-1", payload: "AAAA", priority: "high" });
    expect(r.ok).toBe(true);

    const tokenCall = google.calls[0];
    expect(tokenCall.url).toBe("https://oauth2.googleapis.com/token");
    expect(tokenCall.init.method).toBe("POST");
    const form = new URLSearchParams(tokenCall.body);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const jwt = form.get("assertion")!;
    const [h, c, s] = jwt.split(".");
    expect(JSON.parse(new TextDecoder().decode(b64urlDecode(h)))).toEqual({ alg: "RS256", typ: "JWT" });
    const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(c)));
    expect(claims).toEqual({
      iss: account.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now / 1000,
      exp: now / 1000 + 3600,
    });
    const valid = await crypto.subtle.verify(ALG, publicKey, b64urlDecode(s), new TextEncoder().encode(`${h}.${c}`));
    expect(valid).toBe(true);

    const send = google.fcmCalls()[0];
    expect(send.url).toBe("https://fcm.googleapis.com/v1/projects/perch-test/messages:send");
    expect((send.init.headers as Record<string, string>).Authorization).toBe("Bearer access-1");
  });

  it("caches the access token until shortly before it expires", async () => {
    const { account } = await testAccount();
    const google = new FakeGoogle();
    let now = 1_800_000_000_000;
    const cache = new TokenCache();
    const sender = new FcmPushSender(account, { fetch: google.fetch, now: () => now, cache });
    const m = { token: "fcm-1", deviceId: "phone", machineId: "machine-1", payload: "AAAA", priority: "high" as const };
    await sender.send(m);
    await sender.send(m);
    now += 50 * 60 * 1000; // 50 minutes: still good
    await sender.send(m);
    expect(google.tokenCalls).toBe(1);
    // Another sender in the same isolate shares the cache.
    await new FcmPushSender(account, { fetch: google.fetch, now: () => now, cache }).send(m);
    expect(google.tokenCalls).toBe(1);
    now += 6 * 60 * 1000; // 56 minutes: within 5 minutes of expiry
    await sender.send(m);
    expect(google.tokenCalls).toBe(2);
    const auths = google.fcmCalls().map((c) => (c.init.headers as Record<string, string>).Authorization);
    expect(auths).toEqual(["Bearer access-1", "Bearer access-1", "Bearer access-1", "Bearer access-1", "Bearer access-2"]);
  });

  it("fetches a new access token once when FCM refuses the cached one", async () => {
    const { account } = await testAccount();
    const google = new FakeGoogle();
    const sender = new FcmPushSender(account, { fetch: google.fetch, cache: new TokenCache() });
    google.fcmQueue.push({ status: 401, body: { error: { code: 401, status: "UNAUTHENTICATED" } } });
    const r = await sender.send({ token: "fcm-1", deviceId: "phone", machineId: "m", payload: "AAAA", priority: "high" });
    expect(r.ok).toBe(true);
    expect(google.tokenCalls).toBe(2);
    expect(google.fcmCalls().length).toBe(2);
  });

  it("sends a data-only, high-priority message with a collapse key", async () => {
    const { account } = await testAccount();
    const google = new FakeGoogle();
    const sender = new FcmPushSender(account, { fetch: google.fetch, cache: new TokenCache() });
    await sender.send({
      token: "fcm-1",
      deviceId: "phone",
      machineId: "machine-1",
      payload: "c2VhbGVk",
      priority: "high",
      collapseKey: "tag-1",
    });
    const body = JSON.parse(google.fcmCalls()[0].body);
    expect(body).toEqual({
      message: {
        token: "fcm-1",
        data: { m: "machine-1", p: "c2VhbGVk", w: "0" },
        android: { priority: "HIGH", collapse_key: "tag-1", ttl: "86400s" },
      },
    });
    // Data only: nothing the system would show by itself.
    expect(body.message.notification).toBeUndefined();
    expect(body.message.android.notification).toBeUndefined();
  });

  it("sends the withdraw variant with normal priority", async () => {
    const { account } = await testAccount();
    const google = new FakeGoogle();
    const sender = new FcmPushSender(account, { fetch: google.fetch, cache: new TokenCache() });
    await sender.send({
      token: "fcm-1",
      deviceId: "phone",
      machineId: "machine-1",
      payload: "d2l0aGRyYXc",
      priority: "normal",
      collapseKey: "tag-1",
      withdraw: true,
    });
    const body = JSON.parse(google.fcmCalls()[0].body);
    expect(body.message.data).toEqual({ m: "machine-1", p: "d2l0aGRyYXc", w: "1" });
    expect(body.message.android.priority).toBe("NORMAL");
    expect(body.message.android.collapse_key).toBe("tag-1");
  });

  it("reports unregistered tokens, and a token FCM calls invalid", async () => {
    const { account } = await testAccount();
    const google = new FakeGoogle();
    google.fcm["gone"] = unregistered;
    google.fcm["bad"] = {
      status: 400,
      body: {
        error: {
          code: 400,
          message: "The registration token is not a valid FCM registration token",
          status: "INVALID_ARGUMENT",
          details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "INVALID_ARGUMENT" }],
        },
      },
    };
    google.fcm["busy"] = { status: 503, body: { error: { code: 503, status: "UNAVAILABLE" } } };
    const sender = new FcmPushSender(account, { fetch: google.fetch, cache: new TokenCache() });
    const base = { deviceId: "phone", machineId: "m", payload: "AAAA", priority: "high" as const };
    expect(await sender.send({ ...base, token: "gone" })).toEqual({ ok: false, status: 404, unregistered: true });
    expect(await sender.send({ ...base, token: "bad" })).toEqual({ ok: false, status: 400, unregistered: true });
    expect(await sender.send({ ...base, token: "busy" })).toEqual({ ok: false, status: 503, unregistered: false });
  });

  it("reads the service account from the Worker secret", async () => {
    const { account } = await testAccount();
    expect(parseServiceAccount(JSON.stringify({ ...account, type: "service_account" }))?.project_id).toBe("perch-test");
    expect(parseServiceAccount(undefined)).toBeNull();
    expect(parseServiceAccount("not json")).toBeNull();
    expect(parseServiceAccount(JSON.stringify({ project_id: "x" }))).toBeNull();
  });
});

// ---------------------------------------------------------------- through the relay

async function post(path: string, token: string, body: unknown): Promise<Response> {
  return SELF.fetch(`https://relay.test${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
}

describe("relay push through FCM", () => {
  it("sends to every device but the excepted ones, forgets unregistered tokens, and withdraws", async () => {
    const mid = newMachineId();
    (await connectHost(mid)).close();
    await post(`/m/${mid}/devices/phone/push-token`, DEVICE_TOKEN, { token: "fcm-phone" });
    await post(`/m/${mid}/devices/tablet/push-token`, DEVICE_TOKEN, { token: "fcm-tablet" });
    await post(`/m/${mid}/devices/old/push-token`, DEVICE_TOKEN, { token: "fcm-old" });
    const { account } = await testAccount();
    const google = new FakeGoogle();
    google.fcm["fcm-old"] = unregistered;
    const stub = env.MACHINE.get(env.MACHINE.idFromName(mid));
    await runInDurableObject(stub, (instance: MachineRelay) => {
      instance.pushSender = new FcmPushSender(account, { fetch: google.fetch, cache: new TokenCache() });
    });

    const r = await post(`/m/${mid}/push`, HOST_TOKEN, { payload: "c2VhbGVk", collapseKey: "tag-1", except: ["tablet"] });
    expect(await r.json()).toEqual({ sent: 1, failed: 1 });
    const sent = google.fcmCalls().map((c) => JSON.parse(c.body).message);
    expect(sent.map((m) => m.token).sort()).toEqual(["fcm-old", "fcm-phone"]);
    for (const m of sent) expect(m.data).toEqual({ m: mid, p: "c2VhbGVk", w: "0" });
    const old = await runInDurableObject(stub, (_i, state) => state.storage.get("push:old"));
    expect(old).toBeUndefined();

    google.calls = [];
    const w = await post(`/m/${mid}/push`, HOST_TOKEN, { payload: "d2l0aGRyYXc", collapseKey: "tag-1", withdraw: true, priority: "normal" });
    expect(await w.json()).toEqual({ sent: 2, failed: 0 });
    const withdrawn = google.fcmCalls().map((c) => JSON.parse(c.body).message);
    expect(withdrawn.map((m) => m.token).sort()).toEqual(["fcm-phone", "fcm-tablet"]);
    for (const m of withdrawn) {
      expect(m.data.w).toBe("1");
      expect(m.android.priority).toBe("NORMAL");
    }
  });
});
