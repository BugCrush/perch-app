import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("pairing from a phone camera", () => {
  it("serves the app's App Links file with the release certificate", async () => {
    const r = await SELF.fetch("https://relay.test/.well-known/assetlinks.json");
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Type")).toBe("application/json");
    const j = (await r.json()) as { target: { package_name: string; sha256_cert_fingerprints: string[] } }[];
    expect(j[0].target.package_name).toBe("dev.perch.perch_app");
    expect(j[0].target.sha256_cert_fingerprints[0]).toMatch(/^47:D6:D7:A7:/);
  });

  it("serves a page that turns the #fields into a perch:// link, and holds no secret itself", async () => {
    const r = await SELF.fetch("https://relay.test/pair");
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Type")).toContain("text/html");
    expect(r.headers.get("Content-Security-Policy")).toContain("default-src 'none'");
    const html = await r.text();
    expect(html).toContain("'perch://pair?' + f");
    expect(html).toContain("Get Perch for Android");
    expect(html).toContain("https://github.com/BugCrush/perch-app/releases/latest");
  });
});
