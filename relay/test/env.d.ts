import type { Env as RelayEnv } from "../src/machine";

declare global {
  namespace Cloudflare {
    // eslint-disable-next-line @typescript-eslint/no-empty-object-type
    interface Env extends RelayEnv {}
  }
}

export {};
