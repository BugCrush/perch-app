// Renders the README's 3D pictures: each scene in scenes/ is opened in headless Chrome
// (three.js on SwiftShader, so no GPU is needed), stepped frame by frame, captured, and
// encoded as an animated WebP (img2webp) plus a still for reduced motion.
//   cd tool/readme && npm ci && cd render3d && npm ci
//   node render.mjs                      every scene, both themes
//   node render.mjs hero light --still   one scene/theme; --still writes only frame 0 as PNG
//   node render.mjs hero light --frame 12 --png out.png
// Needs Google Chrome (CHROME=path to override) and img2webp (libwebp) on PATH.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const outDir = path.join(root, 'public', 'assets', 'readme');
const work = path.join(root, '.scratch', 'render3d');

/// What to render: scene, output name, frames, frame delay (ms), WebP quality, scale.
export const jobs = [
  { scene: 'hero', name: 'hero', frames: 80, delay: 50, q: 66, ratio: 1.25 },
  { scene: 'flow', name: 'how-it-works-3d', frames: 64, delay: 60, q: 70, ratio: 1.25 },
  { scene: 'install', name: 'install-3d', frames: 40, delay: 80, q: 80, ratio: 1.25 },
  { scene: 'using', name: 'using-perch-3d', frames: 40, delay: 80, q: 80, ratio: 1.25 },
  { scene: 'roadmap', name: 'roadmap-3d', frames: 40, delay: 80, q: 80, ratio: 1.25 },
  { scene: 'icons', name: 'features', frames: 40, delay: 70, q: 70, ratio: 1.25 },
];

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.woff': 'font/woff', '.json': 'application/json', '.png': 'image/png' };

function serve() {
  const server = http.createServer((req, res) => {
    const p = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
    if (!p.startsWith(root) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'content-type': types[path.extname(p)] ?? 'application/octet-stream' });
    fs.createReadStream(p).pipe(res);
  });
  return new Promise((ok) => server.listen(0, '127.0.0.1', () => ok(server)));
}

async function main() {
  const args = process.argv.slice(2);
  const flags = new Set(args.filter((a) => a.startsWith('--')));
  const val = (f) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : undefined; };
  const pos = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--') && ['--frame', '--png'].includes(args[i - 1])));
  const only = pos[0], onlyTheme = pos[1];
  const server = await serve();
  const port = server.address().port;
  const browser = await puppeteer.launch({
    executablePath: process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--hide-scrollbars'],
  });
  try {
    for (const job of jobs) {
      if (only && job.scene !== only) continue;
      for (const theme of ['light', 'dark']) {
        if (onlyTheme && theme !== onlyTheme) continue;
        await renderJob(browser, port, job, theme, { flags, frame: val('--frame'), png: val('--png') });
      }
    }
  } finally {
    await browser.close();
    server.close();
  }
}

async function renderJob(browser, port, job, theme, { flags, frame, png }) {
  const page = await browser.newPage();
  page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warn') console.log(`[${job.scene}] ${m.text()}`); });
  page.on('pageerror', (e) => console.log(`[${job.scene}] ${e.message}`));
  await page.setViewport({ width: 1600, height: 1200, deviceScaleFactor: job.ratio });
  const url = `http://127.0.0.1:${port}/tool/readme/render3d/index.html?scene=${job.scene}&theme=${theme}&frames=${job.frames}&ratio=${job.ratio}`;
  const t0 = Date.now();
  await page.goto(url);
  await page.waitForFunction('window.__ready || window.__error', { timeout: 300000, polling: 200 });
  const err = await page.evaluate('window.__error');
  if (err) throw new Error(err);
  const card = await page.$('#card');
  const box = await card.boundingBox();
  const clip = { x: box.x, y: box.y, width: box.width, height: box.height };
  const shot = async (i, file) => {
    await page.evaluate((k) => window.__frame(k), i);
    await page.screenshot({ path: file, clip, omitBackground: true });
  };
  if (job.scene === 'icons' && frame === undefined) {
    // One sheet per frame; each cell becomes its own looping picture.
    const meta = await page.evaluate('window.__meta');
    const dirs = meta.names.map((n) => { const d = path.join(work, `icon-${n}-${theme}`); fs.rmSync(d, { recursive: true, force: true }); fs.mkdirSync(d, { recursive: true }); return d; });
    for (let i = 0; i < job.frames; i++) {
      await page.evaluate((k) => window.__frame(k), i);
      for (const [k] of meta.names.entries()) {
        const x = box.x + (k % meta.cols) * meta.cell, y = box.y + Math.floor(k / meta.cols) * meta.cell;
        await page.screenshot({ path: path.join(dirs[k], `f${String(i).padStart(3, '0')}.png`), clip: { x, y, width: meta.cell, height: meta.cell }, omitBackground: true });
      }
    }
    let total = 0;
    meta.names.forEach((n, k) => {
      const files = fs.readdirSync(dirs[k]).sort().map((f) => path.join(dirs[k], f));
      const anim = path.join(outDir, `feature-${n}-${theme}.webp`);
      const still = path.join(outDir, `feature-${n}-${theme}-still.webp`);
      execFileSync('img2webp', ['-loop', '0', '-min_size', '-lossy', '-q', String(job.q), '-m', '6', '-d', String(job.delay), ...files, '-o', anim]);
      execFileSync('cwebp', ['-quiet', '-q', String(job.q), '-alpha_q', '100', '-m', '6', files[0], '-o', still]);
      total += fs.statSync(anim).size + fs.statSync(still).size;
      console.log(`  feature-${n}-${theme}: ${(fs.statSync(anim).size / 1024).toFixed(0)} KB`);
    });
    console.log(`feature icons (${theme}): ${meta.names.length} animations + stills, ${(total / 1024).toFixed(0)} KB`);
    await page.close();
    return;
  }
  if (frame !== undefined || flags.has('--still')) {
    const file = png ?? path.join(work, `${job.name}-${theme}.png`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    await shot(Number(frame ?? 0), file);
    console.log(`${file} (${Date.now() - t0} ms)`);
    await page.close();
    return;
  }
  const dir = path.join(work, `${job.name}-${theme}`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const files = [];
  for (let i = 0; i < job.frames; i++) {
    const f = path.join(dir, `f${String(i).padStart(3, '0')}.png`);
    await shot(i, f);
    files.push(f);
    if (i % 10 === 0) process.stdout.write(`${job.name}-${theme}: frame ${i}/${job.frames}\r`);
  }
  await page.close();
  // The still (reduced motion, and the first paint): frame 0.
  const still = path.join(outDir, `${job.name}-${theme}${job.frames > 1 ? '-still' : ''}.webp`);
  execFileSync('cwebp', ['-quiet', '-q', String(Math.min(95, job.q + 6)), '-alpha_q', '100', '-m', '6', files[0], '-o', still]);
  if (job.frames > 1) {
    const anim = path.join(outDir, `${job.name}-${theme}.webp`);
    execFileSync('img2webp', ['-loop', '0', '-min_size', '-lossy', '-q', String(job.q), '-m', '6', '-d', String(job.delay), ...files, '-o', anim]);
    console.log(`${anim}: ${(fs.statSync(anim).size / 1024).toFixed(0)} KB, still ${(fs.statSync(still).size / 1024).toFixed(0)} KB (${((Date.now() - t0) / 1000).toFixed(0)} s)`);
  } else {
    console.log(`${still}: ${(fs.statSync(still).size / 1024).toFixed(0)} KB`);
  }
}

await main();
