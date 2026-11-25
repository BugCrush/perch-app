// What a phone camera opens when it scans a host's pairing QR code (2026-11-26):
//
// GET /pair                         -> a small page: "Open in Perch" (the perch:// link built
//                                      from the address's #fragment) and "Get the app".
// GET /.well-known/assetlinks.json  -> Android App Links: the Perch app (package and release
//                                      certificate) may open https://<relay>/pair itself.
//
// The pairing fields sit after `#`, which a browser never sends: the relay sees only that
// someone opened /pair. With the app installed Android opens it directly and this page never
// shows.

export interface PairPageEnv {
  /** The app's package name (default dev.perch.perch_app). */
  APP_PACKAGE?: string;
  /** The release certificate's SHA-256, `AA:BB:…` (comma-separated for several). */
  APP_CERT_SHA256?: string;
  /** Where to get the app (default the public repository's latest release). */
  APP_DOWNLOAD_URL?: string;
}

const DEFAULT_PACKAGE = "dev.perch.perch_app";
const DEFAULT_DOWNLOAD = "https://github.com/BugCrush/perch-app/releases/latest";

export function assetLinks(env: PairPageEnv): Response {
  const prints = (env.APP_CERT_SHA256 ?? "")
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter((s) => /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/.test(s));
  const body = prints.length === 0
    ? []
    : [
        {
          relation: ["delegate_permission/common.handle_all_urls"],
          target: { namespace: "android_app", package_name: env.APP_PACKAGE || DEFAULT_PACKAGE, sha256_cert_fingerprints: prints },
        },
      ];
  return new Response(JSON.stringify(body), {
    headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=3600" },
  });
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

export function pairPage(env: PairPageEnv): Response {
  const download = escapeHtml(env.APP_DOWNLOAD_URL || DEFAULT_DOWNLOAD);
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Pair with Perch</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #1b1519; color: #f7eee8;
         font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 26rem; padding: 2rem 1.25rem; }
  h1 { font-size: 1.6rem; margin: 0 0 .5rem; }
  p { color: #d8cacf; }
  a.button { display: block; text-align: center; padding: .9rem 1rem; margin: .75rem 0; border-radius: 999px;
             text-decoration: none; font-weight: 700; }
  .open { background: #f7532b; color: #1b1519; }
  .get { border: 1px solid #6e5562; color: #f7eee8; }
  .hide { display: none; }
</style></head>
<body><main>
  <h1>Pair this phone with Perch</h1>
  <p id="lead">This code connects the Perch app to a computer. Open it in the app; if you do not have Perch yet, get it first, then scan the code again.</p>
  <a id="open" class="button open" href="#">Open in Perch</a>
  <a class="button get" href="${download}">Get Perch for Android</a>
  <p id="bad" class="hide">This address is not a complete Perch pairing code. Scan the code on the computer again.</p>
</main>
<script>
  // The pairing fields are after '#': they never left this phone.
  var f = location.hash.slice(1);
  if (/(^|&)v=1(&|$)/.test(f) && /(^|&)k=/.test(f)) {
    document.getElementById('open').href = 'perch://pair?' + f;
  } else {
    document.getElementById('open').className += ' hide';
    document.getElementById('bad').className = '';
  }
</script>
</body></html>`;
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=3600",
      "Referrer-Policy": "no-referrer",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
