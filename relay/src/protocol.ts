// What travels between the relay, a host and its devices.
//
// Device <-> relay: binary frames are the app's encrypted channel, forwarded untouched.
//   Text frames from the relay: {"t":"hostOffline"} and {"t":"hostOnline"}.
// Host <-> relay: binary frames are [device id length (1 byte)][device id (UTF-8)][frame].
//   Text frames from the relay: {"t":"open","d":id} and {"t":"close","d":id}.
//   Text frames from the host: {"t":"close","d":id,"code"?:n,"reason"?:s}, and "ping"
//   every 30 s (answered "pong" by the runtime without waking the Durable Object).

export const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
export const MACHINE_ID_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;
/** A board id: 16 random bytes, base64url without padding. */
export const BOARD_ID_PATTERN = /^[A-Za-z0-9_-]{22}$/;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function envelope(deviceId: string, frame: ArrayBuffer | Uint8Array): Uint8Array {
  const id = encoder.encode(deviceId);
  const body = frame instanceof Uint8Array ? frame : new Uint8Array(frame);
  const out = new Uint8Array(1 + id.length + body.length);
  out[0] = id.length;
  out.set(id, 1);
  out.set(body, 1 + id.length);
  return out;
}

export function openEnvelope(data: ArrayBuffer | Uint8Array): { deviceId: string; frame: Uint8Array } | null {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.length < 1) return null;
  const len = bytes[0];
  if (len === 0 || bytes.length < 1 + len) return null;
  const deviceId = decoder.decode(bytes.subarray(1, 1 + len));
  if (!ID_PATTERN.test(deviceId)) return null;
  return { deviceId, frame: bytes.subarray(1 + len) };
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time comparison of two hex strings of the same length. */
export function sameHash(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** The bearer token from `Authorization: Bearer x`, else the `t` query parameter (browsers
 * cannot set headers on a WebSocket). */
export function tokenOf(request: Request, url: URL): string | null {
  const auth = request.headers.get("Authorization");
  if (auth && auth.startsWith("Bearer ")) return auth.slice(7).trim() || null;
  return url.searchParams.get("t");
}

export const hostOffline = JSON.stringify({ t: "hostOffline" });
export const hostOnline = JSON.stringify({ t: "hostOnline" });
