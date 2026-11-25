// Sending push notifications. The relay never reads the payload: the host encrypts it,
// the relay hands it to the sender as is, and the app decrypts it.
//
// FCM HTTP v1: the relay signs a JWT with the service account's key (RS256, WebCrypto),
// exchanges it at Google's token endpoint for an access token (cached until shortly
// before it expires), and posts one data-only message per device token.

export interface PushMessage {
  /** The device's FCM registration token. */
  token: string;
  /** The device id the token belongs to. */
  deviceId: string;
  /** The machine the payload is from (the app picks the key to decrypt it with). */
  machineId: string;
  /** The encrypted payload exactly as the host sent it (base64). */
  payload: string;
  priority: "high" | "normal";
  /** Messages with the same key replace each other on the device (one per session). */
  collapseKey?: string;
  /** Removes the notification shown for this key instead of showing one. */
  withdraw?: boolean;
}

export interface PushResult {
  ok: boolean;
  /** HTTP status from the push service, when there was one. */
  status?: number;
  /** The token is no longer valid; the relay forgets it. */
  unregistered?: boolean;
}

export interface PushSender {
  send(message: PushMessage): Promise<PushResult>;
}

/** Used when the Worker has no `FCM_SERVICE_ACCOUNT` secret. */
export class UnconfiguredPushSender implements PushSender {
  async send(): Promise<PushResult> {
    return { ok: false, status: 501 };
  }
}

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

/** The service account from the Worker secret (the JSON key file), or null. */
export function parseServiceAccount(text: string | undefined): ServiceAccount | null {
  if (!text) return null;
  try {
    const j = JSON.parse(text) as Record<string, unknown>;
    const { project_id, client_email, private_key, token_uri } = j;
    if (typeof project_id !== "string" || typeof client_email !== "string" || typeof private_key !== "string") return null;
    return { project_id, client_email, private_key, token_uri: typeof token_uri === "string" ? token_uri : undefined };
  } catch {
    return null;
  }
}

/** Access tokens by service-account email. One per isolate is shared by every object in it. */
export class TokenCache {
  private tokens = new Map<string, { token: string; expiresAt: number }>();
  get(key: string, now: number): string | null {
    const t = this.tokens.get(key);
    return t && t.expiresAt > now ? t.token : null;
  }
  put(key: string, token: string, expiresAt: number): void {
    this.tokens.set(key, { token, expiresAt });
  }
  drop(key: string): void {
    this.tokens.delete(key);
  }
}

const isolateCache = new TokenCache();

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
/** A token is renewed this long before Google says it expires. */
const RENEW_BEFORE_MS = 5 * 60 * 1000;
/** A notification FCM could not deliver within a day is dropped. */
const TTL = "86400s";

const encoder = new TextEncoder();

function base64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? encoder.encode(bytes) : bytes;
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

type Fetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export class FcmPushSender implements PushSender {
  private readonly fetcher: Fetch;
  private readonly now: () => number;
  private readonly cache: TokenCache;
  private key: Promise<CryptoKey> | null = null;

  constructor(
    readonly account: ServiceAccount,
    options: { fetch?: Fetch; now?: () => number; cache?: TokenCache } = {},
  ) {
    this.fetcher = options.fetch ?? ((input, init) => fetch(input, init));
    this.now = options.now ?? (() => Date.now());
    this.cache = options.cache ?? isolateCache;
  }

  private get tokenUri(): string {
    return this.account.token_uri ?? DEFAULT_TOKEN_URI;
  }

  private signingKey(): Promise<CryptoKey> {
    this.key ??= crypto.subtle.importKey(
      "pkcs8",
      pemToDer(this.account.private_key),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    return this.key;
  }

  /** The signed JWT Google exchanges for an access token. */
  async assertion(): Promise<string> {
    const iat = Math.floor(this.now() / 1000);
    const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
    const claims = base64url(
      JSON.stringify({ iss: this.account.client_email, scope: SCOPE, aud: this.tokenUri, iat, exp: iat + 3600 }),
    );
    const input = `${header}.${claims}`;
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", await this.signingKey(), encoder.encode(input));
    return `${input}.${base64url(new Uint8Array(sig))}`;
  }

  private async accessToken(): Promise<string> {
    const cached = this.cache.get(this.account.client_email, this.now());
    if (cached) return cached;
    const res = await this.fetcher(this.tokenUri, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: await this.assertion(),
      }).toString(),
    });
    if (!res.ok) throw new Error(`token endpoint answered ${res.status}`);
    const j = (await res.json()) as { access_token?: unknown; expires_in?: unknown };
    if (typeof j.access_token !== "string") throw new Error("token endpoint sent no access_token");
    const seconds = typeof j.expires_in === "number" ? j.expires_in : 3600;
    this.cache.put(this.account.client_email, j.access_token, this.now() + seconds * 1000 - RENEW_BEFORE_MS);
    return j.access_token;
  }

  static body(m: PushMessage): unknown {
    return {
      message: {
        token: m.token,
        data: { m: m.machineId, p: m.payload, w: m.withdraw ? "1" : "0" },
        android: {
          priority: m.priority === "high" ? "HIGH" : "NORMAL",
          ...(m.collapseKey ? { collapse_key: m.collapseKey } : {}),
          ttl: TTL,
        },
      },
    };
  }

  private async post(m: PushMessage, accessToken: string): Promise<Response> {
    return this.fetcher(`https://fcm.googleapis.com/v1/projects/${this.account.project_id}/messages:send`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify(FcmPushSender.body(m)),
    });
  }

  async send(m: PushMessage): Promise<PushResult> {
    let res: Response;
    try {
      res = await this.post(m, await this.accessToken());
      if (res.status === 401) {
        this.cache.drop(this.account.client_email);
        res = await this.post(m, await this.accessToken());
      }
    } catch {
      return { ok: false };
    }
    if (res.ok) return { ok: true, status: res.status };
    let unregistered = false;
    try {
      const j = (await res.json()) as {
        error?: { message?: unknown; details?: { errorCode?: unknown }[] };
      };
      const codes = (j.error?.details ?? []).map((d) => d.errorCode);
      const message = typeof j.error?.message === "string" ? j.error.message : "";
      unregistered =
        codes.includes("UNREGISTERED") ||
        (res.status === 400 && codes.includes("INVALID_ARGUMENT") && /registration token/i.test(message));
    } catch {
      // not JSON
    }
    return { ok: false, status: res.status, unregistered };
  }
}
