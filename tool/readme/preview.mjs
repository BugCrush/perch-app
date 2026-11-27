// A local preview of the public README as GitHub renders it, light and dark, beside the
// README on main. Nothing is published: the README text goes through GitHub's public
// markdown API (the same renderer as the repository page) and the result is written to
// <repo>/.scratch/preview with the pictures linked from public/assets.
//   node tool/readme/preview.mjs [--base main]
//   python3 -m http.server 4320 --bind 127.0.0.1 --directory .scratch/preview
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const out = path.join(root, '.scratch', 'preview');
const base = process.argv.includes('--base') ? process.argv[process.argv.indexOf('--base') + 1] : 'main';
fs.mkdirSync(out, { recursive: true });

function ghEnv() {
  try {
    const t = execFileSync('gh', ['auth', 'token', '--user', 'BugCrush'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return t ? { ...process.env, GH_TOKEN: t } : process.env;
  } catch { return process.env; }
}

function render(markdownFile) {
  return execFileSync('gh', ['api', '-X', 'POST', 'markdown', '-f', 'mode=gfm', '-f', 'context=BugCrush/perch-app', '-F', `text=@${markdownFile}`], { encoding: 'utf8', env: ghEnv(), maxBuffer: 1 << 26 });
}

async function css(name) {
  const file = path.join(out, name);
  if (!fs.existsSync(file)) {
    const r = await fetch(`https://cdn.jsdelivr.net/npm/github-markdown-css@5.8.1/${name}`);
    if (!r.ok) throw new Error(`${name}: ${r.status}`);
    fs.writeFileSync(file, await r.text());
  }
}

/// GitHub picks a <picture> source by the viewer's colour scheme (and here, motion
/// preference); the preview forces both by choosing the source itself.
function forcePictures(html, theme, reduced) {
  const matches = (media) => media.split(/\s+and\s+/).every((c) => {
    const m = c.match(/\(\s*prefers-(color-scheme|reduced-motion)\s*:\s*([a-z-]+)\s*\)/);
    if (!m) return true;
    return m[1] === 'color-scheme' ? m[2] === theme : (m[2] === 'reduce') === reduced;
  });
  return html.replace(/<picture>([\s\S]*?)<\/picture>/g, (all, inner) => {
    const sources = [...inner.matchAll(/<source[^>]*media="([^"]*)"[^>]*srcset="([^"]*)"[^>]*>/g)];
    const img = inner.match(/<img[^>]*>/)?.[0] ?? '';
    const pick = sources.find((s) => matches(s[1]));
    return pick ? img.replace(/src="[^"]*"/, `src="${pick[2]}"`) : img;
  });
}

function page(body, theme, title) {
  const bg = theme === 'dark' ? '#0d1117' : '#ffffff';
  const border = theme === 'dark' ? '#3d444d' : '#d1d9e0';
  const head = theme === 'dark' ? '#151b23' : '#f6f8fa';
  const fg = theme === 'dark' ? '#f0f6fc' : '#1f2328';
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<link rel="stylesheet" href="github-markdown-${theme}.css">
<style>
  html, body { margin: 0; background: ${bg}; color-scheme: ${theme}; }
  .box { max-width: 896px; margin: 24px auto; border: 1px solid ${border}; border-radius: 6px; }
  .bar { background: ${head}; border-bottom: 1px solid ${border}; padding: 8px 16px; font: 600 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: ${fg}; border-radius: 6px 6px 0 0; }
  .markdown-body { padding: 32px; }
  @media (max-width: 767px) { .markdown-body { padding: 16px; } .box { margin: 0; border-radius: 0; } }
</style></head><body><div class="box"><div class="bar">README</div><article class="markdown-body">${body}</article></div></body></html>`;
}

const docs = {
  new: path.join(root, 'public', 'README.md'),
  current: path.join(out, 'current.md'),
};
fs.writeFileSync(docs.current, execFileSync('git', ['show', `${base}:public/README.md`], { cwd: root, encoding: 'utf8' }));

await css('github-markdown-light.css');
await css('github-markdown-dark.css');
const link = path.join(out, 'assets');
fs.rmSync(link, { force: true, recursive: false });
fs.symlinkSync(path.join(root, 'public', 'assets'), link);

// The commit walker, drawn locally from this repository's history (the README points at
// the copy the walker workflow publishes; the preview uses this one).
const walkerDir = path.join(out, 'walker');
fs.mkdirSync(walkerDir, { recursive: true });
const log = execFileSync('git', ['log', '--date=format-local:%Y-%m-%d', '--format=%ad', base], { cwd: root, encoding: 'utf8', env: { ...process.env, TZ: process.env.TZ || 'UTC' }, maxBuffer: 1 << 26 });
execFileSync('node', [path.join(here, 'walker.mjs'), walkerDir], { input: log, env: { ...process.env, TZ: process.env.TZ || 'UTC' } });

for (const [name, file] of Object.entries(docs)) {
  const html = render(file).replaceAll('https://raw.githubusercontent.com/BugCrush/perch-app/readme-assets/walker-', 'walker/walker-');
  fs.writeFileSync(path.join(out, `${name}.fragment.html`), html);
  for (const theme of ['light', 'dark']) for (const reduced of [false, true]) {
    const f = `${name}-${theme}${reduced ? '-still' : ''}.html`;
    fs.writeFileSync(path.join(out, f), page(forcePictures(html, theme, reduced), theme, `${name} README (${theme})`));
  }
}

fs.writeFileSync(path.join(out, 'index.html'), `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Perch README preview</title>
<style>
  :root { --bg: #FFF8F0; --fg: #161310; --line: #E6D3C0; --on: #F7532B; }
  :root[data-theme="dark"] { --bg: #161310; --fg: #FCE6D1; --line: #3A2E27; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg); font: 14px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  header { display: flex; flex-wrap: wrap; gap: 16px; align-items: center; padding: 10px 16px; border-bottom: 1px solid var(--line); position: sticky; top: 0; background: var(--bg); }
  header b { margin-right: 6px; }
  .seg { display: inline-flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  .seg button { border: 0; background: none; color: inherit; padding: 6px 12px; font: inherit; cursor: pointer; }
  .seg button[aria-pressed="true"] { background: var(--on); color: #fff; }
  main { display: flex; height: calc(100% - 52px); }
  main > section { flex: 1; display: flex; flex-direction: column; min-width: 0; border-left: 1px solid var(--line); }
  main > section:first-child { border-left: 0; }
  main h2 { margin: 0; padding: 6px 16px; font-size: 13px; font-weight: 600; opacity: .75; }
  iframe { flex: 1; width: 100%; border: 0; }
  .hidden { display: none !important; }
  .note { opacity: .7; font-size: 12px; }
</style></head><body>
<header>
  <span><b>Perch README</b><span class="note">local preview, rendered by GitHub's markdown API</span></span>
  <span class="seg" id="view"><button data-v="new">New</button><button data-v="current">Current</button><button data-v="both">Side by side</button></span>
  <span class="seg" id="theme"><button data-v="light">Light</button><button data-v="dark">Dark</button></span>
  <span class="seg" id="motion"><button data-v="on">Motion</button><button data-v="reduced">Reduced motion</button></span>
</header>
<main>
  <section id="sNew"><h2>New (readme-v2)</h2><iframe id="fNew"></iframe></section>
  <section id="sCur"><h2>Current (main)</h2><iframe id="fCur"></iframe></section>
</main>
<script>
  const s = Object.assign({ view: 'new', theme: 'light', motion: 'on' }, Object.fromEntries(new URLSearchParams(location.hash.slice(1))));
  function apply() {
    for (const k of ['view', 'theme', 'motion']) document.querySelectorAll('#' + k + ' button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.v === s[k])));
    document.documentElement.dataset.theme = s.theme;
    const suf = s.theme + (s.motion === 'reduced' ? '-still' : '') + '.html';
    const set = (f, src) => { if (!f.src.endsWith(src)) f.src = src; };
    set(document.getElementById('fNew'), 'new-' + suf);
    set(document.getElementById('fCur'), 'current-' + suf);
    document.getElementById('sNew').classList.toggle('hidden', s.view === 'current');
    document.getElementById('sCur').classList.toggle('hidden', s.view === 'new');
    location.hash = new URLSearchParams(s).toString();
  }
  for (const k of ['view', 'theme', 'motion']) document.getElementById(k).addEventListener('click', (e) => { if (e.target.dataset.v) { s[k] = e.target.dataset.v; apply(); } });
  apply();
</script></body></html>
`);
console.log(`preview written to ${out}`);
