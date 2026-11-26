// Draws the README's banner and its two hand-drawn diagrams, dark and light, into
// public/assets/readme (or the folder given): every word is a path, no fonts or scripts.
//   cd tool/readme && npm ci && node build-art.mjs [out folder]
import fs from 'node:fs';
import { walkerData } from './walker-data.mjs';
import path from 'node:path';
import { C, themes, fonts, text, sketch, logoSimplified, birdPaths, birdClipPath, arrowHead, svgDoc, resetGlyphs, root, here } from './lib.mjs';

const out = path.resolve(process.argv[2] ?? path.join(root, 'public', 'assets', 'readme'));
fs.mkdirSync(out, { recursive: true });

const logo = logoSimplified(0.7);
const bird = birdPaths({ tolerance: 1.2 });

/// The whole logo placed with its top-left at (x, y), [h] high.
function logoAt(x, y, h, t) {
  const s = h / logo.height;
  return `<g transform="translate(${x} ${y}) scale(${s.toFixed(5)})"><path d="${logo.orange}" fill="${C.orange}" fill-rule="evenodd"/><path d="${logo.cream}" fill="${t.belly}" fill-rule="evenodd"/></g>`;
}

/// The bird alone, its feet at (x, y) (feet are at about (560, 621) in logo units), [h] high.
let clipN = 0;
function birdAt(x, y, h, t, { flip = false } = {}) {
  const s = h / 600;
  const id = `bc${clipN++}`;
  const fx = flip ? -s : s;
  return `<clipPath id="${id}"><path d="${birdClipPath}"/></clipPath><g transform="translate(${x} ${y}) scale(${fx.toFixed(5)} ${s.toFixed(5)}) translate(-560 -621)"><g clip-path="url(#${id})"><path d="${bird.orange}" fill="${C.orange}" fill-rule="evenodd"/><path d="${bird.cream}" fill="${t.belly}" fill-rule="evenodd"/></g></g>`;
}

const hand = (s, x, y, size, fill, anchor = 'start') => text(s, x, y, { font: fonts.hand, size, fill, anchor });
const handL = (s, x, y, size, fill, anchor = 'start') => text(s, x, y, { font: fonts.handLight, size, fill, anchor });

// ---------------------------------------------------------------------------------------
// Banner, 1280 x 400.

function banner(t) {
  const sk = sketch(11);
  const W = 1280, H = 400;
  let b = '';
  b += logoAt(92, 38, 324, t);
  b += text('Perch', 468, 212, { font: fonts.serif, size: 168, fill: t.name === 'dark' ? C.orange : C.orange });
  // A brushy underline under the name.
  b += sk.curve([[474, 240], [600, 232], [760, 236], [868, 226]], { stroke: t.amber, strokeWidth: 4.5, roughness: 1.6 });
  b += text('Watch and steer your Claude Code sessions', 472, 296, { font: fonts.sans, size: 33, fill: t.text });
  b += text('from your phone.', 472, 340, { font: fonts.sans, size: 33, fill: t.text });
  b += handL('Android  ·  Windows  ·  macOS  ·  a Claude Code plugin', 1196, 378, 25, t.quiet, 'end');
  return svgDoc(W, H, b, { bg: t.bg, title: 'Perch: watch and steer your Claude Code sessions from your phone', radius: 22 });
}

// ---------------------------------------------------------------------------------------
// Shared little drawings.

function phone(sk, x, y, w, h, t, opts = {}) {
  let s = sk.round(x, y, w, h, 24, { stroke: t.line, strokeWidth: 2.6, fill: t.panel, fillStyle: 'solid' });
  s += sk.line(x + w / 2 - 18, y + 14, x + w / 2 + 18, y + 14, { stroke: t.line, strokeWidth: 2, roughness: 0.6 });
  if (opts.home !== false) s += sk.line(x + w / 2 - 22, y + h - 14, x + w / 2 + 22, y + h - 14, { stroke: t.quiet, strokeWidth: 2, roughness: 0.6 });
  return s;
}

function terminal(sk, x, y, w, h, t) {
  let s = sk.round(x, y, w, h, 12, { stroke: t.line, strokeWidth: 2.4, fill: t.panel, fillStyle: 'solid' });
  s += sk.line(x + 4, y + 28, x + w - 4, y + 28, { stroke: t.line, strokeWidth: 1.8, roughness: 0.8 });
  for (let i = 0; i < 3; i++) s += sk.circle(x + 16 + i * 15, y + 14, 7, { stroke: t.quiet, strokeWidth: 1.4, roughness: 0.5 });
  return s;
}

function lock(sk, x, y, t, color) {
  let s = sk.round(x, y + 9, 18, 14, 3, { stroke: color, strokeWidth: 2, roughness: 0.7 });
  s += sk.path(`M${x + 4} ${y + 9}V${y + 5}Q${x + 4} ${y} ${x + 9} ${y}Q${x + 14} ${y} ${x + 14} ${y + 5}V${y + 9}`, { stroke: color, strokeWidth: 2, roughness: 0.6 });
  return s;
}

function arrow(sk, pts, t, { color = t.line, both = false, dash = false, width = 2.4 } = {}) {
  const o = { stroke: color, strokeWidth: width, roughness: 1.1 };
  let s = sk.curve(pts, o);
  if (dash) s = s.replace(/<path /g, '<path stroke-dasharray="9 9" ');
  const n = pts.length;
  s += arrowHead(sk, pts[n - 2][0], pts[n - 2][1], pts[n - 1][0], pts[n - 1][1], { ...o, roughness: 0.6 });
  if (both) s += arrowHead(sk, pts[1][0], pts[1][1], pts[0][0], pts[0][1], { ...o, roughness: 0.6 });
  return s;
}

// ---------------------------------------------------------------------------------------
// How it works, 1280 x 800.

function architecture(t) {
  const sk = sketch(23);
  const W = 1280, H = 800;
  let b = '';

  // The phone, with the bird perched on it.
  const px = 92, py = 262, pw = 196, ph = 370;
  b += phone(sk, px, py, pw, ph, t);
  // A small conversation on its screen and a card.
  for (const [i, wdt] of [[0, 120], [1, 90], [2, 132]].map((v) => v)) {
    b += sk.line(px + 26, py + 58 + i * 26, px + 26 + wdt, py + 58 + i * 26, { stroke: t.quiet, strokeWidth: 3, roughness: 0.7 });
  }
  b += sk.round(px + 18, py + 150, pw - 36, 150, 14, { stroke: t.line, strokeWidth: 2, fill: t.hatch, fillStyle: 'hachure', hachureGap: 7, fillWeight: 1.4 });
  b += hand('Allow Bash?', px + 34, py + 190, 26, t.text);
  b += sk.round(px + 30, py + 240, 62, 36, 16, { stroke: t.line, strokeWidth: 1.8, roughness: 0.8 });
  b += hand('Deny', px + 61, py + 266, 22, t.text, 'middle');
  b += sk.round(px + 102, py + 240, 66, 36, 16, { stroke: C.orange, strokeWidth: 1.8, fill: C.orange, fillStyle: 'solid', roughness: 0.8 });
  b += hand('Allow', px + 135, py + 266, 22, C.ink, 'middle');
  b += sk.round(px + 18, py + 318, pw - 64, 30, 14, { stroke: t.quiet, strokeWidth: 1.6, roughness: 0.8 });
  b += birdAt(px + pw / 2 + 10, py + 4, 96, t);
  b += hand('Perch app', px + pw / 2, py + ph + 52, 40, t.text, 'middle');
  b += handL('on your Android phone', px + pw / 2, py + ph + 84, 26, t.quiet, 'middle');

  // Your computer: the host, the sessions, the plugin.
  const cx = 858, cy = 150, cw = 372, chh = 590;
  b += sk.round(cx, cy, cw, chh, 22, { stroke: t.line, strokeWidth: 2.4, roughness: 1.4 });
  b += hand('your computer', cx + 24, cy + 46, 36, t.text);
  b += handL('Windows or macOS', cx + 24, cy + 78, 25, t.quiet);
  const hx = cx + 26, hy = cy + 104, hw = cw - 52, hh = 118;
  b += sk.round(hx, hy, hw, hh, 14, { stroke: C.orange, strokeWidth: 2.8, fill: t.hatch, fillStyle: 'hachure', hachureGap: 8, fillWeight: 1.5 });
  b += hand('Perch host', hx + 20, hy + 44, 36, t.accent);
  b += handL('a small background program,', hx + 20, hy + 76, 25, t.text);
  b += handL('starts when you log in', hx + 20, hy + 102, 25, t.text);

  // Arrows between host and sessions.
  const ay0 = hy + hh + 10, ay1 = cy + 372;
  b += arrow(sk, [[hx + 34, ay0], [hx + 30, (ay0 + ay1) / 2], [hx + 34, ay1]], t, { both: true });
  b += handL('reads sessions and transcripts,', hx + 62, ay0 + 32, 24, t.text);
  b += handL('types your answers', hx + 62, ay0 + 58, 24, t.text);
  b += handL('hooks send instant updates', hx + 62, ay0 + 92, 24, t.quiet);

  // Two terminals with Claude Code in them.
  const tx = hx, ty = cy + 384;
  b += terminal(sk, tx + 70, ty, 230, 120, t);
  b += terminal(sk, tx, ty + 34, 230, 120, t);
  b += hand('> claude', tx + 16, ty + 34 + 62, 26, t.accent);
  b += sk.line(tx + 16, ty + 34 + 84, tx + 150, ty + 34 + 84, { stroke: t.quiet, strokeWidth: 2.6, roughness: 0.7 });
  b += sk.line(tx + 16, ty + 34 + 104, tx + 110, ty + 34 + 104, { stroke: t.quiet, strokeWidth: 2.6, roughness: 0.7 });
  // The plugin's tag on the sessions.
  b += sk.round(tx + 188, ty + 92, 132, 62, 12, { stroke: C.orange, strokeWidth: 2.2, fill: t.bg, fillStyle: 'solid', roughness: 1 });
  b += hand('Perch plugin', tx + 254, ty + 118, 23, t.accent, 'middle');
  b += handL('/perch · hooks', tx + 254, ty + 143, 21, t.text, 'middle');
  b += hand('Claude Code sessions', tx + 6, ty + 186, 30, t.text);

  // The relay.
  const rx = 590, ry = 258;
  b += sk.ellipse(rx, ry, 290, 148, { stroke: t.line, strokeWidth: 2.4, fill: t.hatch, fillStyle: 'hachure', hachureGap: 9, fillWeight: 1.3, roughness: 1.6 });
  b += lock(sk, rx - 64, ry - 34, t, t.accent);
  b += hand('relay', rx + 8, ry - 12, 38, t.text, 'middle');
  b += handL('sealed messages only', rx, ry + 22, 25, t.text, 'middle');
  b += handL('it cannot read them', rx, ry + 48, 22, t.quiet, 'middle');
  b += handL('away from home · a Cloudflare Worker', rx, ry + 112, 24, t.quiet, 'middle');

  // Phone <-> relay <-> computer.
  b += arrow(sk, [[px + pw + 14, py + 70], [380, 236], [rx - 150, ry - 4]], t, { both: true });
  b += arrow(sk, [[rx + 150, ry - 4], [760, 236], [hx - 10, hy + 50]], t, { both: true });

  // Same Wi-Fi: direct.
  const dy = 566;
  b += arrow(sk, [[px + pw + 14, dy], [570, dy + 8], [cx - 10, dy]], t, { both: true, dash: true, color: C.amber, width: 2.8 });
  b += hand('at home, on the same Wi-Fi: direct', 575, dy - 22, 30, t.amber, 'middle');
  b += lock(sk, 405, dy + 22, t, t.amber);
  b += handL('end-to-end encrypted, keys made at pairing', 433, dy + 42, 24, t.text);

  // Pairing and trust.
  b += handL('pairing: scan the QR code from /perch,', 575, 680, 24, t.quiet, 'middle');
  b += handL('then Allow the phone at the computer', 575, 708, 24, t.quiet, 'middle');

  // Push notifications: host -> relay -> Firebase -> phone.
  const fx = 300, fy = 46, fw = 230, fh = 66;
  b += sk.round(fx, fy, fw, fh, 14, { stroke: t.line, strokeWidth: 2.2, roughness: 1.1 });
  b += hand('Firebase push', fx + fw / 2, fy + 30, 27, t.text, 'middle');
  b += handL("Google's push service", fx + fw / 2, fy + 54, 21, t.quiet, 'middle');
  b += arrow(sk, [[rx + 18, ry - 80], [rx - 10, 150], [fx + fw - 30, fy + fh + 8]], t, { color: t.accent, dash: true });
  b += arrow(sk, [[fx - 8, fy + 34], [210, 80], [px + pw / 2 + 20, py - 104]], t, { color: t.accent, dash: true });
  b += hand('push, sealed per device:', 640, 92, 27, t.accent);
  b += handL('Google carries text it cannot read', 640, 122, 23, t.text);

  return svgDoc(W, H, b, { bg: t.bg, title: 'How Perch works: the phone app talks to the Perch host on your computer, directly on the same Wi-Fi or through a relay that only passes sealed messages; the host watches your Claude Code sessions', radius: 22 });
}

// ---------------------------------------------------------------------------------------
// A day with Perch, 1280 x 420.

function dayStrip(t) {
  const sk = sketch(41);
  const W = 1280, H = 430;
  let b = '';
  const pw = 250, gap = 60, x0 = 40, top = 34, cap = 330;
  const X = (i) => x0 + i * (pw + gap);
  const num = (i, label, sub) => {
    const x = X(i);
    let s = sk.circle(x + 20, cap - 9, 38, { stroke: C.orange, strokeWidth: 2.4, fill: C.orange, fillStyle: 'solid', roughness: 0.9 });
    s += hand(String(i + 1), x + 20, cap + 2, 30, C.ink, 'middle');
    s += hand(label, x + 48, cap + 1, 30, t.text);
    s += handL(sub, x + 48, cap + 32, 23, t.quiet);
    return s;
  };

  // 1. Claude asks while you're away.
  {
    const x = X(0);
    b += terminal(sk, x, top + 40, pw, 200, t);
    b += hand('Claude wants to run', x + 16, top + 102, 25, t.text);
    b += hand('npm run migrate', x + 16, top + 132, 25, t.accent);
    b += hand('1. Yes', x + 22, top + 172, 24, t.text);
    b += hand('2. No', x + 22, top + 200, 24, t.quiet);
    b += hand('waiting…', x + pw - 16, top + 226, 22, t.quiet, 'end');
    // An empty mug: you stepped away.
    b += sk.round(x + pw - 64, top - 4, 34, 36, 6, { stroke: t.line, strokeWidth: 2 });
    b += sk.path(`M${x + pw - 30} ${top + 4}Q${x + pw - 16} ${top + 6} ${x + pw - 18} ${top + 16}Q${x + pw - 20} ${top + 26} ${x + pw - 30} ${top + 24}`, { stroke: t.line, strokeWidth: 2 });
    b += sk.curve([[x + pw - 54, top - 12], [x + pw - 50, top - 22], [x + pw - 54, top - 32]], { stroke: t.quiet, strokeWidth: 1.6 });
    b += sk.curve([[x + pw - 42, top - 12], [x + pw - 38, top - 22], [x + pw - 42, top - 32]], { stroke: t.quiet, strokeWidth: 1.6 });
    b += num(0, "Claude asks", "while you're away");
  }

  // 2. Your phone buzzes.
  {
    const x = X(1);
    const fx = x + 60, fy = top + 8, fw = 130, fh = 240;
    b += phone(sk, fx, fy, fw, fh, t);
    b += sk.round(fx + 10, fy + 40, fw - 20, 62, 12, { stroke: C.orange, strokeWidth: 2, fill: t.hatch, fillStyle: 'hachure', hachureGap: 6, fillWeight: 1.2 });
    b += hand('billing-api', fx + 20, fy + 66, 21, t.accent);
    b += handL('needs you', fx + 20, fy + 90, 20, t.text);
    // Buzz marks either side.
    for (const side of [-1, 1]) {
      const bx = side < 0 ? fx - 14 : fx + fw + 14;
      for (const k of [0, 1]) {
        const ox = side * k * 14;
        b += sk.curve([[bx + ox, fy + 90], [bx + ox + side * 8, fy + 120], [bx + ox, fy + 150]], { stroke: C.orange, strokeWidth: 2.4, roughness: 0.8 });
      }
    }
    b += num(1, 'Your phone buzzes', 'a notification, sealed');
  }

  // 3. You answer from the card.
  {
    const x = X(2);
    const fx = x + 60, fy = top + 8, fw = 130, fh = 240;
    b += phone(sk, fx, fy, fw, fh, t);
    b += sk.round(fx + 10, fy + 40, fw - 20, 150, 12, { stroke: t.line, strokeWidth: 1.8, fill: t.hatch, fillStyle: 'hachure', hachureGap: 7, fillWeight: 1.2 });
    b += hand('Run npm run', fx + 20, fy + 68, 21, t.text);
    b += hand('migrate?', fx + 20, fy + 92, 21, t.text);
    b += sk.round(fx + 18, fy + 112, fw - 36, 28, 13, { stroke: C.orange, strokeWidth: 1.8, fill: C.orange, fillStyle: 'solid', roughness: 0.8 });
    b += hand('Allow', fx + fw / 2, fy + 133, 20, C.ink, 'middle');
    b += sk.round(fx + 18, fy + 148, fw - 36, 28, 13, { stroke: t.line, strokeWidth: 1.6, roughness: 0.8 });
    b += hand('Deny', fx + fw / 2, fy + 169, 20, t.text, 'middle');
    // The tap.
    b += sk.circle(fx + fw - 24, fy + 132, 22, { stroke: t.amber, strokeWidth: 2.2, roughness: 1 });
    b += sk.circle(fx + fw - 24, fy + 132, 38, { stroke: t.amber, strokeWidth: 1.4, roughness: 1.2 });
    b += num(2, 'You answer', 'from the card: Allow');
  }

  // 4. Claude carries on.
  {
    const x = X(3);
    b += terminal(sk, x, top + 40, pw, 200, t);
    b += sk.linear([[x + 18, top + 96], [x + 26, top + 106], [x + 42, top + 84]], { stroke: t.ok, strokeWidth: 3, roughness: 0.6 });
    b += hand('Allowed from Perch', x + 52, top + 102, 23, t.text);
    b += hand('Migrating 12 tables…', x + 18, top + 140, 23, t.text);
    b += hand('done in 41 s', x + 18, top + 170, 23, t.accent);
    b += sk.line(x + 18, top + 202, x + 120, top + 202, { stroke: t.quiet, strokeWidth: 2.4, roughness: 0.7 });
    // The bird back on the terminal.
    b += birdAt(x + pw - 52, top + 42, 64, t);
    b += num(3, 'Claude carries on', 'and you hear when it is done');
  }

  // Arrows between the panels.
  for (let i = 0; i < 3; i++) {
    const a = X(i) + pw + 8, z = X(i + 1) - 8, y = top + 140;
    b += arrow(sk, [[a, y], [(a + z) / 2, y - 16], [z, y]], t, { color: t.quiet, width: 2.2 });
  }
  return svgDoc(W, H, b, { bg: t.bg, title: 'A day with Perch: Claude asks something while you are away, your phone buzzes, you answer from the card, Claude carries on', radius: 22 });
}

// ---------------------------------------------------------------------------------------
// Install in 3 steps, 1280 x 480.

/// A QR code's look (made-up modules, not a code): finder squares and a fixed scatter.
function qr(sk, x, y, size, t) {
  const n = 13, m = size / n;
  let s = sk.rect(x, y, size, size, { stroke: t.line, strokeWidth: 1.8, roughness: 0.8 });
  const block = (i, j) => `<rect x="${f1(x + i * m)}" y="${f1(y + j * m)}" width="${f1(m)}" height="${f1(m)}" fill="${t.line}"/>`;
  const finder = (i, j) => {
    let r = '';
    for (let a = 0; a < 3; a++) for (let c = 0; c < 3; c++) if (a !== 1 || c !== 1) r += block(i + a, j + c);
    return r;
  };
  s += finder(1, 1) + finder(n - 4, 1) + finder(1, n - 4);
  let seed = 7;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  for (let i = 1; i < n - 1; i++) for (let j = 1; j < n - 1; j++) {
    const inFinder = (i < 5 && j < 5) || (i > n - 6 && j < 5) || (i < 5 && j > n - 6);
    if (!inFinder && rnd() < 0.45) s += block(i, j);
  }
  return s;
}
const f1 = (v) => +v.toFixed(1);

function captionAt(sk, x, y, n, label, sub, t) {
  let s = '';
  let tx = x;
  if (n) {
    s += sk.circle(x + 20, y - 9, 38, { stroke: C.orange, strokeWidth: 2.4, fill: C.orange, fillStyle: 'solid', roughness: 0.9 });
    s += hand(String(n), x + 20, y + 2, 30, C.ink, 'middle');
    tx = x + 48;
  }
  s += hand(label, tx, y + 1, 31, n ? t.text : t.accent);
  s += handL(sub, tx, y + 33, 23, t.quiet);
  return s;
}

function installSteps(t) {
  const sk = sketch(57);
  const W = 1280, H = 480;
  let b = '';
  const cap = 384;

  // 1. The plugin, in Claude Code on the computer.
  {
    const x = 40, y = 52, w = 370, h = 240;
    b += terminal(sk, x, y, w, h, t);
    b += hand('>', x + 16, y + 68, 24, t.accent) + hand('/plugin marketplace add', x + 36, y + 68, 24, t.text);
    b += hand('BugCrush/perch-app', x + 36, y + 96, 24, t.text);
    b += hand('>', x + 16, y + 132, 24, t.accent) + hand('/plugin install perch@perch', x + 36, y + 132, 24, t.text);
    b += handL('then start a new session', x + 36, y + 166, 22, t.quiet);
    // The host arriving in the background.
    b += sk.path(`M${x + 30} ${y + 208}A10 10 0 1 1 ${x + 40} ${y + 198}`, { stroke: t.amber, strokeWidth: 2.4, roughness: 0.6 });
    b += hand('installing the Perch host…', x + 52, y + 214, 23, t.amber);
    b += captionAt(sk, x, cap, 1, 'On the computer', 'add the plugin in Claude Code', t);
  }

  // 2. The app, on the phone.
  {
    const x = 492, fw = 170, fh = 270, fx = x + 20, fy = 36;
    b += phone(sk, fx, fy, fw, fh, t);
    const ax = fx + fw / 2;
    b += sk.line(ax, fy + 50, ax, fy + 118, { stroke: C.orange, strokeWidth: 4, roughness: 0.8 });
    b += arrowHead(sk, ax, fy + 60, ax, fy + 120, { stroke: C.orange, strokeWidth: 4, roughness: 0.6 }, 22);
    b += sk.line(ax - 34, fy + 134, ax + 34, fy + 134, { stroke: C.orange, strokeWidth: 3, roughness: 0.8 });
    b += hand('perch-1.0.0.apk', ax, fy + 176, 22, t.text, 'middle');
    b += handL('latest release', ax, fy + 200, 19, t.quiet, 'middle');
    b += sk.round(fx + 30, fy + 216, fw - 60, 32, 15, { stroke: C.orange, strokeWidth: 1.8, fill: C.orange, fillStyle: 'solid', roughness: 0.8 });
    b += hand('Install', ax, fy + 239, 21, C.ink, 'middle');
    b += captionAt(sk, x - 30, cap, 2, 'On the phone', 'the app from the release', t);
  }

  // 3. Pair: /perch shows a QR code, the phone's camera scans it, Allow at the computer.
  {
    const x = 790, y = 40, w = 260, h = 186;
    b += terminal(sk, x, y, w, h, t);
    b += hand('/perch', x + 16, y + 70, 25, t.accent);
    b += hand('Pair your', x + 16, y + 104, 23, t.text);
    b += hand('phone', x + 16, y + 130, 23, t.text);
    b += qr(sk, x + w - 112, y + 44, 96, t);
    // The phone's camera on the code.
    const fx = 1110, fy = 52, fw = 126, fh = 214;
    b += phone(sk, fx, fy, fw, fh, t);
    const c = (cx, cy, dx, dy) => sk.linear([[cx + dx * 18, cy], [cx, cy], [cx, cy + dy * 18]], { stroke: t.amber, strokeWidth: 2.6, roughness: 0.6 });
    b += c(fx + 22, fy + 58, 1, 1) + c(fx + fw - 22, fy + 58, -1, 1) + c(fx + 22, fy + 148, 1, -1) + c(fx + fw - 22, fy + 148, -1, -1);
    b += qr(sk, fx + 38, fy + 78, 50, t);
    b += handL('camera', fx + fw / 2, fy + 182, 19, t.quiet, 'middle');
    b += arrow(sk, [[fx - 8, fy + 110], [fx - 30, fy + 96], [x + w + 6, y + 96]], t, { color: t.amber, dash: true, width: 2.2 });
    // Allow at the computer.
    const dx = 818, dy = 238, dw = 272, dh = 104;
    b += sk.round(dx, dy, dw, dh, 12, { stroke: C.orange, strokeWidth: 2.4, fill: t.bg, fillStyle: 'solid', roughness: 1 });
    b += hand('Let this phone in?', dx + 16, dy + 34, 23, t.text);
    const btn = (bx, bw, label, main) =>
      sk.round(bx, dy + 52, bw, 34, 15, main ? { stroke: C.orange, strokeWidth: 1.8, fill: C.orange, fillStyle: 'solid', roughness: 0.8 } : { stroke: t.line, strokeWidth: 1.6, roughness: 0.8 }) +
      hand(label, bx + bw / 2, dy + 76, 20, main ? C.ink : t.text, 'middle');
    b += btn(dx + 14, 70, 'Allow', true) + btn(dx + 92, 104, 'Watch only', false) + btn(dx + 204, 56, 'Deny', false);
    b += captionAt(sk, x, cap, 3, 'Pair', '/perch: Pair your phone, scan, Allow', t);
    b += handL('away from home? /perch, then Enter invite code', 1238, 456, 21, t.quiet, 'end');
  }

  // Arrows between the steps.
  b += arrow(sk, [[424, 170], [450, 156], [486, 170]], t, { color: t.quiet, width: 2.2 });
  b += arrow(sk, [[708, 170], [738, 156], [776, 170]], t, { color: t.quiet, width: 2.2 });
  return svgDoc(W, H, b, { bg: t.bg, title: 'Install Perch in three steps: add the plugin in Claude Code, install the app on the phone, pair them with /perch', radius: 22 });
}

// ---------------------------------------------------------------------------------------
// Using Perch: a tour of what the app does, 1280 x 480.

function usingPerch(t) {
  const sk = sketch(73);
  const W = 1280, H = 480;
  let b = '';
  const pw = 212, X = (i) => 34 + i * 250, fy = 34, fw = 184, fh = 300, cap = 392;
  const screen = (i) => {
    const fx = X(i) + (pw - fw) / 2;
    return { fx, s: phone(sk, fx, fy, fw, fh, t), cx: fx + fw / 2 };
  };
  const pill = (x, y, w, h, label, main, size = 20) =>
    sk.round(x, y, w, h, h / 2 - 1, main ? { stroke: C.orange, strokeWidth: 1.8, fill: C.orange, fillStyle: 'solid', roughness: 0.8 } : { stroke: t.line, strokeWidth: 1.6, roughness: 0.8 }) +
    hand(label, x + w / 2, y + h / 2 + size * 0.33, size, main ? C.ink : t.text, 'middle');

  // 1. Every session and its state.
  {
    const { fx, s } = screen(0);
    b += s;
    b += hand('Studio PC', fx + 16, fy + 58, 24, t.text);
    const rows = [
      ['billing-api', 'working', t.amber],
      ['photo-app', 'needs you', t.accent],
      ['api-docs', 'done', t.ok],
    ];
    rows.forEach(([name, state, col], k) => {
      const ry = fy + 76 + k * 66;
      b += sk.round(fx + 12, ry, fw - 24, 56, 12, { stroke: t.quiet, strokeWidth: 1.4, roughness: 0.8 });
      b += hand(name, fx + 24, ry + 24, 20, t.text);
      b += hand(state, fx + 24, ry + 47, 19, col);
      if (k === 0) for (let q = 0; q < 4; q++) b += sk.line(fx + fw - 50 + q * 7, ry + 34 - (q % 2) * 8, fx + fw - 50 + q * 7, ry + 42, { stroke: col, strokeWidth: 2.4, roughness: 0.4 });
      if (k === 1) b += sk.circle(fx + fw - 36, ry + 28, 12, { stroke: col, strokeWidth: 2, fill: col, fillStyle: 'solid', roughness: 0.6 });
      if (k === 2) b += sk.linear([[fx + fw - 46, ry + 28], [fx + fw - 40, ry + 35], [fx + fw - 28, ry + 20]], { stroke: col, strokeWidth: 2.6, roughness: 0.5 });
    });
    b += captionAt(sk, X(0), cap, 0, 'Every session', 'working, needs you, done', t);
  }

  // 2. Cards: a question deck with Submit.
  {
    const { fx, s, cx } = screen(1);
    b += s;
    b += sk.round(fx + 10, fy + 34, fw - 20, 236, 14, { stroke: t.line, strokeWidth: 1.8, fill: t.hatch, fillStyle: 'hachure', hachureGap: 8, fillWeight: 1.1 });
    b += handL('Claude asks · 2 of 2', fx + 22, fy + 62, 18, t.quiet);
    b += hand('Which formats?', fx + 22, fy + 90, 22, t.text);
    [['CSV', true], ['TSV', true], ['JSON', false]].forEach(([o, on], k) => {
      const oy = fy + 104 + k * 34;
      b += sk.round(fx + 20, oy, fw - 40, 28, 10, { stroke: t.quiet, strokeWidth: 1.3, roughness: 0.7 });
      b += hand(o, fx + 32, oy + 21, 19, t.text);
      b += sk.rect(fx + fw - 48, oy + 7, 14, 14, on ? { stroke: C.orange, strokeWidth: 1.6, fill: C.orange, fillStyle: 'solid', roughness: 0.6 } : { stroke: t.line, strokeWidth: 1.4, roughness: 0.6 });
    });
    b += pill(fx + 34, fy + 214, fw - 68, 34, 'Submit', true);
    b += captionAt(sk, X(1), cap, 0, 'Answer cards', 'Allow, Approve a plan, Submit', t);
  }

  // 3. A new session in any folder, with any model.
  {
    const { fx, s } = screen(2);
    b += s;
    b += hand('New session', fx + 16, fy + 60, 24, t.text);
    // Folder.
    b += sk.round(fx + 12, fy + 80, fw - 24, 44, 10, { stroke: t.quiet, strokeWidth: 1.4, roughness: 0.8 });
    b += sk.path(`M${fx + 24} ${fy + 92}H${fx + 34}L${fx + 38} ${fy + 96}H${fx + 50}V${fy + 112}H${fx + 24}Z`, { stroke: t.accent, strokeWidth: 1.8, roughness: 0.5 });
    b += hand('billing-api', fx + 58, fy + 109, 20, t.text);
    // Model.
    b += sk.round(fx + 12, fy + 134, fw - 24, 44, 10, { stroke: t.quiet, strokeWidth: 1.4, roughness: 0.8 });
    b += handL('model', fx + 24, fy + 162, 19, t.quiet);
    b += hand('Opus', fx + 84, fy + 162, 20, t.text);
    b += handL('the terminal opens', fx + 16, fy + 206, 18, t.quiet);
    b += handL('on the machine', fx + 16, fy + 226, 18, t.quiet);
    b += pill(fx + 34, fy + 244, fw - 68, 34, 'Start', true);
    b += captionAt(sk, X(2), cap, 0, 'Start a session', 'any folder, any model', t);
  }

  // 4. The board: Run on… and the report back in Review.
  {
    const { fx, s } = screen(3);
    b += s;
    b += hand('Board', fx + 16, fy + 58, 24, t.text);
    b += sk.round(fx + 12, fy + 74, fw - 24, 104, 12, { stroke: t.line, strokeWidth: 1.6, fill: t.hatch, fillStyle: 'hachure', hachureGap: 8, fillWeight: 1.1 });
    b += hand('Stream the', fx + 24, fy + 100, 20, t.text);
    b += hand('CSV export', fx + 24, fy + 124, 20, t.text);
    b += pill(fx + 24, fy + 136, 104, 30, 'Run on…', true, 19);
    b += arrow(sk, [[fx + fw / 2, fy + 186], [fx + fw / 2 + 6, fy + 202], [fx + fw / 2, fy + 218]], t, { color: t.quiet, width: 2 });
    b += sk.round(fx + 12, fy + 222, fw - 24, 56, 12, { stroke: t.ok, strokeWidth: 1.8, roughness: 0.8 });
    b += hand('Review', fx + 24, fy + 246, 20, t.ok);
    b += handL("Claude's report", fx + 24, fy + 268, 18, t.text);
    b += captionAt(sk, X(3), cap, 0, 'Run tasks', 'Run on…, then Review', t);
  }

  // 5. Stop, and a push when Claude is done or needs you.
  {
    const { fx, s, cx } = screen(4);
    b += s;
    // The notification.
    b += sk.round(fx + 8, fy + 34, fw - 16, 58, 12, { stroke: C.orange, strokeWidth: 2, fill: t.bg, fillStyle: 'solid', roughness: 0.9 });
    b += sk.path(`M${fx + 22} ${fy + 72}Q${fx + 22} ${fy + 48} ${fx + 31} ${fy + 48}Q${fx + 40} ${fy + 48} ${fx + 40} ${fy + 72}Z`, { stroke: C.orange, strokeWidth: 1.8, roughness: 0.5 });
    b += hand('api-docs', fx + 50, fy + 58, 19, t.accent);
    b += handL('Claude is done', fx + 50, fy + 80, 18, t.text);
    for (const [k, w] of [[0, 130], [1, 100], [2, 140], [3, 80]]) b += sk.line(fx + 20, fy + 122 + k * 24, fx + 20 + w, fy + 122 + k * 24, { stroke: t.quiet, strokeWidth: 3, roughness: 0.7 });
    b += sk.round(fx + 40, fy + 230, fw - 80, 40, 19, { stroke: t.accent, strokeWidth: 2.4, roughness: 0.9 });
    b += sk.rect(cx - 30, fy + 244, 12, 12, { stroke: t.accent, strokeWidth: 1.8, fill: t.accent, fillStyle: 'solid', roughness: 0.5 });
    b += hand('Stop', cx + 8, fy + 258, 22, t.accent, 'middle');
    b += captionAt(sk, X(4), cap, 0, 'Stop, or be told', 'a push when done or needed', t);
  }
  return svgDoc(W, H, b, { bg: t.bg, title: 'Using Perch: see every session, answer cards, start sessions, run tasks from the board, stop a session or get a push', radius: 22 });
}

for (const t of Object.values(themes)) {
  for (const [name, fn] of [['banner', banner], ['how-it-works', architecture], ['a-day-with-perch', dayStrip], ['install', installSteps], ['using-perch', usingPerch]]) {
    clipN = 0;
    resetGlyphs();
    const file = path.join(out, `${name}-${t.name}.svg`);
    const svg = fn(t);
    fs.writeFileSync(file, svg);
    console.log(`${path.relative(root, file)}  ${(svg.length / 1024).toFixed(1)} KB`);
  }
}

// The walker's bird and letters, so the walker itself needs no packages.
const wd = path.join(here, 'walker-data.json');
fs.writeFileSync(wd, JSON.stringify(walkerData()) + '\n');
console.log(`${path.relative(root, wd)}  ${(fs.statSync(wd).size / 1024).toFixed(1)} KB`);
