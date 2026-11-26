// The walker: Perch's bird flying from square to square over a grid of the project's
// commits per day, landing on each active day for a moment and taking off again. Squares
// never change; brighter squares are days with more commits. Writes walker-dark.svg and
// walker-light.svg: plain SVG with a CSS animation, no scripts, fonts or outside links.
//
//   git log --date=format-local:%Y-%m-%d --format=%ad | node walker.mjs <out folder> [--today YYYY-MM-DD]
//   (run git and this script with the same TZ: days are counted in that time zone, UTC if unset)
//
// Needs only Node: the bird and the letters come from walker-data.json (build-art.mjs).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const data = JSON.parse(fs.readFileSync(path.join(here, 'walker-data.json'), 'utf8'));

const TZ = process.env.TZ || 'UTC';
const CELL = 11, GAP = 3, PITCH = CELL + GAP;
const MIN_WEEKS = 30, MAX_WEEKS = 53;
const MAX_STOPS = 60;
const BIRD_H = 30; // px, the bird from head to feet
const LEFT = 40, TOP = 74, RIGHT = 22, BOTTOM = 52;

const palettes = {
  dark: {
    bg: '#161310', text: '#FCE6D1', quiet: '#A8968A', empty: '#2A231E', future: '#241E1A',
    levels: ['#5C2A1B', '#933A21', '#D04A27', '#FF7A52'], belly: '#FCE6D1', today: '#FCE6D1',
  },
  light: {
    bg: '#FFF8F0', text: '#161310', quiet: '#7A685C', empty: '#F1E2D2', future: '#F6EADD',
    levels: ['#F8C6AE', '#F59874', '#F0663F', '#C9381A'], belly: '#FCE6D1', today: '#161310',
  },
};
const ORANGE = '#F7532B';

// ---------------------------------------------------------------------------------------
// Days.

const DAY = 86400000;
const iso = (ms) => new Date(ms).toISOString().slice(0, 10);
const parse = (s) => Date.parse(s + 'T00:00:00Z');
const weekday = (ms) => (new Date(ms).getUTCDay() + 6) % 7; // Monday 0 … Sunday 6

function todayIn(tz) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return parts; // YYYY-MM-DD
}

function readCounts(text) {
  const counts = new Map();
  for (const line of text.split(/\r?\n/)) {
    const d = line.trim();
    if (!/^\d{4}-\d\d-\d\d$/.test(d)) continue;
    counts.set(d, (counts.get(d) ?? 0) + 1);
  }
  return counts;
}

/// The grid: weeks as columns (Monday on top), from the first commit's week to this week,
/// at least MIN_WEEKS wide (later weeks are drawn as not yet come) and at most MAX_WEEKS.
function layout(counts, today) {
  const days = [...counts.keys()].sort();
  const t = parse(today);
  const first = days.length ? Math.min(parse(days[0]), t) : t;
  const thisMonday = t - weekday(t) * DAY;
  let start = first - weekday(first) * DAY;
  let weeks = Math.round((thisMonday - start) / (7 * DAY)) + 1;
  if (weeks > MAX_WEEKS) {
    start = thisMonday - (MAX_WEEKS - 1) * 7 * DAY;
    weeks = MAX_WEEKS;
  }
  const cols = Math.max(weeks, MIN_WEEKS);
  const nonzero = days.filter((d) => parse(d) >= start && parse(d) <= t).map((d) => counts.get(d)).sort((a, b) => a - b);
  const q = (p) => nonzero.length ? nonzero[Math.min(nonzero.length - 1, Math.floor(p * nonzero.length))] : 1;
  const cuts = [q(0.25), q(0.5), q(0.75)];
  const level = (n) => (n <= 0 ? 0 : n <= cuts[0] ? 1 : n <= cuts[1] ? 2 : n <= cuts[2] ? 3 : 4);
  const cells = [];
  for (let c = 0; c < cols; c++) {
    for (let r = 0; r < 7; r++) {
      const ms = start + (c * 7 + r) * DAY;
      const d = iso(ms);
      const n = counts.get(d) ?? 0;
      cells.push({ c, r, d, n, future: ms > t, today: ms === t, level: level(n), x: LEFT + c * PITCH, y: TOP + r * PITCH });
    }
  }
  return { cells, cols, start, today: t };
}

// ---------------------------------------------------------------------------------------
// Drawing helpers.

const f = (v) => +v.toFixed(2);

function textPath(s, x, y, size, fill, anchor = 'start') {
  const { upm, glyphs } = data.font;
  let at = 0, uses = '';
  for (const ch of s) {
    const g = glyphs[ch] ?? glyphs['?'];
    if (g.d) uses += `<use href="#t${ch.codePointAt(0)}" x="${at}"/>`;
    at += g.a;
  }
  const w = (at * size) / upm;
  const x0 = anchor === 'middle' ? x - w / 2 : anchor === 'end' ? x - w : x;
  for (const ch of s) used.add(glyphs[ch] ? ch : '?');
  return `<g fill="${fill}" transform="translate(${f(x0)} ${f(y)}) scale(${(size / upm).toFixed(5)})">${uses}</g>`;
}
let used = new Set();

function glyphDefs() {
  return [...used]
    .filter((ch) => data.font.glyphs[ch].d)
    .map((ch) => `<path id="t${ch.codePointAt(0)}" d="${data.font.glyphs[ch].d}"/>`)
    .join('');
}

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// ---------------------------------------------------------------------------------------
// The flight plan.

/// The days the bird lands on: every active day in order, thinned evenly to MAX_STOPS.
function stops(cells) {
  const active = cells.filter((c) => c.n > 0 && !c.future);
  if (active.length <= MAX_STOPS) return active;
  const out = [];
  for (let i = 0; i < MAX_STOPS; i++) out.push(active[Math.round((i * (active.length - 1)) / (MAX_STOPS - 1))]);
  return out;
}

/// Keyframes for the bird's position (feet), facing, and which pose shows (sitting/flying).
function plan(list) {
  const feet = (c) => [c.x + CELL / 2, c.y + CELL / 2 + 2];
  const SIT = 1.2; // s on each square
  const hops = [];
  let t = 0;
  let facing = 1;
  for (let i = 0; i < list.length; i++) {
    const a = feet(list[i]);
    const b = feet(list[(i + 1) % list.length]);
    const dist = Math.hypot(b[0] - a[0], b[1] - a[1]);
    const fly = list.length === 1 ? 0 : Math.min(2.6, 0.5 + dist / 160);
    const dir = b[0] < a[0] - 0.5 ? -1 : b[0] > a[0] + 0.5 ? 1 : facing;
    hops.push({ a, b, t0: t, sitEnd: t + SIT, end: t + SIT + fly, dist, faceSit: facing, faceFly: dir });
    facing = dir;
    t += SIT + fly;
  }
  return { hops, total: t };
}

function keyframes({ hops, total }) {
  const pct = (s) => `${f((s / total) * 100)}%`;
  const eps = Math.min(0.02, total / 5000);
  const pos = [];
  const sit = [];
  const put = (s, [x, y], face, lift = 0) => pos.push(`${pct(s)}{transform:translate(${f(x)}px,${f(y)}px) scale(${face},1) rotate(${f(lift)}deg)}`);
  for (const h of hops) {
    put(h.t0, h.a, h.faceSit);
    put(Math.max(h.t0, h.sitEnd - eps), h.a, h.faceSit);
    sit.push(`${pct(h.t0)}{opacity:1}`, `${pct(Math.max(h.t0, h.sitEnd - eps))}{opacity:1}`);
    if (h.end - h.sitEnd < 1e-6) continue;
    sit.push(`${pct(h.sitEnd)}{opacity:0}`, `${pct(h.end - eps)}{opacity:0}`);
    // An arc, higher for a longer hop, eased at both ends.
    const steps = 10;
    const height = 14 + Math.min(60, h.dist * 0.28);
    for (let k = 0; k <= steps; k++) {
      const u = k / steps;
      const e = u < 0.5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2;
      const x = h.a[0] + (h.b[0] - h.a[0]) * e;
      const y = h.a[1] + (h.b[1] - h.a[1]) * e - height * 4 * e * (1 - e);
      // Nose up on the way up, down on the way down.
      const tilt = -12 * (1 - 2 * e);
      put(h.sitEnd + (h.end - h.sitEnd) * u, [x, y], h.faceFly, k === 0 || k === steps ? 0 : tilt);
    }
  }
  const last = hops[hops.length - 1];
  put(total, last.b, last.faceFly);
  sit.push(`100%{opacity:1}`);
  return { pos: pos.join(''), sit: sit.join('') };
}

// ---------------------------------------------------------------------------------------
// The SVG.

function svg(theme, counts, today) {
  used = new Set();
  const P = palettes[theme];
  const { cells, cols, start } = layout(counts, today);
  const W = LEFT + cols * PITCH - GAP + RIGHT;
  const H = TOP + 7 * PITCH - GAP + BOTTOM;
  let body = '';

  // Header: what this is, and the totals.
  const total = [...counts.values()].reduce((a, b) => a + b, 0);
  const active = [...counts.values()].filter((n) => n > 0).length;
  const since = parse([...counts.keys()].sort()[0] ?? today);
  const sinceText = `${new Date(since).getUTCDate()} ${months[new Date(since).getUTCMonth()]} ${new Date(since).getUTCFullYear()}`;
  body += textPath('Perch, day by day', LEFT, 24, 14, P.text);
  body += textPath(`${total} commits on ${active} days since ${sinceText}`, LEFT, 42, 11, P.quiet);

  // Month names over the first column of each month.
  let lastMonth = -1;
  for (let c = 0; c < cols; c++) {
    const ms = start + c * 7 * DAY;
    const m = new Date(ms).getUTCMonth();
    if (m !== lastMonth && (c < cols - 2 || lastMonth === -1)) {
      body += textPath(months[m], LEFT + c * PITCH, TOP - 8, 10, P.quiet);
      lastMonth = m;
    }
  }
  for (const [r, s] of [[0, 'Mon'], [2, 'Wed'], [4, 'Fri']]) body += textPath(s, LEFT - 8, TOP + r * PITCH + 9, 9, P.quiet, 'end');

  // The squares.
  for (const c of cells) {
    if (c.future) {
      body += `<rect x="${c.x + 0.5}" y="${c.y + 0.5}" width="${CELL - 1}" height="${CELL - 1}" rx="2" fill="none" stroke="${P.future}"/>`;
      continue;
    }
    const fill = c.level ? P.levels[c.level - 1] : P.empty;
    body += `<rect x="${c.x}" y="${c.y}" width="${CELL}" height="${CELL}" rx="2.5" fill="${fill}"><title>${c.d}: ${c.n} commit${c.n === 1 ? '' : 's'}</title></rect>`;
    if (c.today) body += `<rect x="${c.x - 1.5}" y="${c.y - 1.5}" width="${CELL + 3}" height="${CELL + 3}" rx="3.5" fill="none" stroke="${P.today}" stroke-width="1" opacity=".55"/>`;
  }

  // Legend.
  const ly = TOP + 7 * PITCH - GAP + 30;
  const lx = W - RIGHT - 30 - 5 * PITCH + GAP;
  body += textPath('fewer', lx - 6, ly + 9, 10, P.quiet, 'end');
  [P.empty, ...P.levels].forEach((col, i) => (body += `<rect x="${lx + i * PITCH}" y="${ly}" width="${CELL}" height="${CELL}" rx="2.5" fill="${col}"/>`));
  body += textPath('more', lx + 5 * PITCH + 2, ly + 9, 10, P.quiet);
  body += textPath('commits per day · updated on every push', LEFT, ly + 9, 10, P.quiet);
  // (the legend sits at the right end of the same line)

  // The bird.
  const b = data.bird;
  const s = BIRD_H / b.height;
  const list = stops(cells);
  let bird = '';
  let css = '';
  if (list.length) {
    const kf = keyframes(plan(list));
    const T = f(plan(list).total);
    const poly = (pts) => 'M' + pts.map((p) => p.join(' ')).join('L') + 'Z';
    const [sx, sy] = b.shoulder;
    const defs =
      `<path id="bo" d="${b.orange}" fill-rule="evenodd" clip-rule="evenodd"/>` +
      `<path id="bc" d="${b.cream}" fill-rule="evenodd" clip-rule="evenodd"/>` +
      `<clipPath id="only"><path d="${b.clip.map(poly).join('')}"/></clipPath>` +
      `<clipPath id="body"><use href="#bo"/><use href="#bc"/></clipPath>` +
      `<clipPath id="wing"><path d="${poly(b.wing)}"/></clipPath>` +
      `<g id="b" clip-path="url(#only)"><use href="#bo" fill="${ORANGE}"/><use href="#bc" fill="${P.belly}"/></g>`;
    const place = `scale(${s.toFixed(5)}) translate(${-b.feet[0]} ${-b.feet[1]})`;
    bird =
      `<defs>${defs}</defs>` +
      `<g class="m"><g transform="${place}">` +
      `<g class="sit"><use href="#b"/></g>` +
      `<g class="fly"><use href="#b"/><g clip-path="url(#body)"><path d="${poly(b.wing)}" fill="${ORANGE}" clip-path="url(#only)"/></g>` +
      `<g class="w"><g clip-path="url(#wing)"><use href="#b"/></g></g></g>` +
      `</g></g>`;
    const turn = (deg, k) => `translate(${sx}px,${sy}px) rotate(${deg}deg) scale(${k},1) translate(${-sx}px,${-sy}px)`;
    css =
      `.m{transform-origin:0 0;animation:m ${T}s linear infinite}` +
      `.sit{animation:s ${T}s step-end infinite}` +
      `.fly{animation:s2 ${T}s step-end infinite}` +
      `.w{transform-origin:0 0;animation:w .28s ease-in-out infinite}` +
      `@keyframes m{${kf.pos}}` +
      `@keyframes s{${kf.sit}}` +
      `@keyframes s2{${kf.sit.replace(/opacity:1/g, 'opacity:X').replace(/opacity:0/g, 'opacity:1').replace(/opacity:X/g, 'opacity:0')}}` +
      `@keyframes w{0%,100%{transform:${turn(0, 1)}}50%{transform:${turn(100, 0.88)}}}` +
      `@media (prefers-reduced-motion:reduce){.m,.sit,.fly,.w{animation:none}.fly{opacity:0}.m{transform:translate(${f(list[list.length - 1].x + CELL / 2)}px,${f(list[list.length - 1].y + CELL / 2 + 2)}px)}}`;
  }

  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}">` +
    `<title>Perch's bird hopping across the project's commits per day</title>` +
    `<style>${css}</style>` +
    `<defs>${glyphDefs()}</defs>` +
    `<rect width="${W}" height="${H}" rx="12" fill="${P.bg}"/>` +
    body +
    bird +
    `</svg>\n`
  );
}

function main() {
  const args = process.argv.slice(2);
  const out = args[0];
  if (!out) {
    console.error('usage: git log … | node walker.mjs <out folder> [--today YYYY-MM-DD]');
    process.exit(2);
  }
  const ti = args.indexOf('--today');
  const today = ti >= 0 ? args[ti + 1] : todayIn(TZ);
  const counts = readCounts(fs.readFileSync(0, 'utf8'));
  fs.mkdirSync(out, { recursive: true });
  for (const theme of ['dark', 'light']) {
    const file = path.join(out, `walker-${theme}.svg`);
    const text = svg(theme, counts, today);
    fs.writeFileSync(file, text);
    console.log(`${file}  ${(text.length / 1024).toFixed(1)} KB`);
  }
}

main();
