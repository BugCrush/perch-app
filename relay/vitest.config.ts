import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      // Tests register machines without invites unless they turn them on (invites.test.ts).
      miniflare: { bindings: { INVITES: "", ADMIN_TOKEN: "test-admin-token" } },
    })],
});
