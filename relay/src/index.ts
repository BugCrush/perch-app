// The Perch relay Worker: routes /m/<machine id>/... to that machine's Durable Object and
// /b/<board id>/... to that board's store.
import { BOARD_ID_PATTERN, MACHINE_ID_PATTERN } from "./protocol";
import type { Env } from "./machine";

export { MachineRelay } from "./machine";
export { BoardStore } from "./board";
export { RelayAdmin } from "./admin";
export type { Env } from "./machine";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "") {
      return new Response("Perch relay\n", { headers: { "Content-Type": "text/plain" } });
    }
    const parts = url.pathname.split("/").filter((p) => p.length > 0);
    if (parts[0] === "admin") return env.ADMIN.get(env.ADMIN.idFromName("admin")).fetch(request);
    if (parts[0] === "b" && parts.length >= 2 && parts.length <= 3 && BOARD_ID_PATTERN.test(parts[1])) {
      return env.BOARD.get(env.BOARD.idFromName(parts[1])).fetch(request);
    }
    if (parts.length < 3 || parts[0] !== "m" || !MACHINE_ID_PATTERN.test(parts[1])) {
      return new Response("Not found\n", { status: 404 });
    }
    const stub = env.MACHINE.get(env.MACHINE.idFromName(parts[1]));
    return stub.fetch(request);
  },
} satisfies ExportedHandler<Env>;
