// Shared helpers for the README art: colours, text turned into paths, rough.js shapes, the logo.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import opentype from 'opentype.js';
import rough from 'roughjs';

export const here = path.dirname(fileURLToPath(import.meta.url));
export const root = path.resolve(here, '..', '..');

/// The app's palette (apps/perch_app/lib/src/ui/glass/palette.dart).
export const C = {
  orange: '#F7532B',
  cream: '#FCE6D1',
  ink: '#161310',
  ember: '#FF7A52',
  amber: '#E9A23B',
  green: '#3BE36B',
};

/// Colours per variant: the card behind the drawing, lines, text, quiet text, fills.
export const themes = {
  dark: {
    name: 'dark',
    bg: C.ink,
    line: '#EADBCB',
    text: C.cream,
    quiet: '#A8968A',
    accent: C.ember,
    orange: C.orange,
    amber: C.amber,
    panel: '#211C18',
    hatch: '#3A2E27',
    belly: C.cream,
    ok: C.green,
  },
  light: {
    name: 'light',
    bg: '#FFF8F0',
    line: '#2B231D',
    text: C.ink,
    quiet: '#7A685C',
    accent: '#D8431F',
    orange: C.orange,
    amber: '#C98316',
    panel: '#FBEBDC',
    hatch: '#F3D9C2',
    belly: C.cream,
    ok: '#1E9E4A',
  },
};

function loadFont(file) {
  const b = fs.readFileSync(file);
  return opentype.parse(b.buffer.slice(b.byteOffset, b.byteOffset + b.length));
}

const fs_ = (p) => path.join(here, 'node_modules', '@fontsource', p);
export const fonts = {
  hand: loadFont(fs_('caveat/files/caveat-latin-700-normal.woff')),
  handLight: loadFont(fs_('caveat/files/caveat-latin-500-normal.woff')),
  serif: loadFont(fs_('newsreader/files/newsreader-latin-500-normal.woff')),
  sans: loadFont(fs_('manrope/files/manrope-latin-500-normal.woff')),
  sansBold: loadFont(fs_('manrope/files/manrope-latin-700-normal.woff')),
};

export function textWidth(font, s, size) {
  return font.getAdvanceWidth(s, size, { kerning: true });
}

// Glyphs are drawn once per document (<defs>, in font units) and placed with <use>: a line
// of handwriting as plain path data is tens of kilobytes.
const glyphs = new Map();
const fontIds = new Map();

export function resetGlyphs() {
  glyphs.clear();
}

export function glyphDefs() {
  return [...glyphs.entries()].map(([id, d]) => `<path id="${id}" d="${d}"/>`).join('');
}

function glyphId(font, g) {
  if (!fontIds.has(font)) fontIds.set(font, `f${fontIds.size}`);
  const id = `${fontIds.get(font)}g${g.index}`;
  if (!glyphs.has(id)) glyphs.set(id, round0(g.getPath(0, 0, font.unitsPerEm).toPathData(0)));
  return id;
}

/// Text as glyphs placed with <use>; anchor 'start' | 'middle' | 'end'.
export function text(s, x, y, { font = fonts.hand, size = 28, fill = '#000', anchor = 'start', extra = '' } = {}) {
  const w = textWidth(font, s, size);
  const x0 = anchor === 'middle' ? x - w / 2 : anchor === 'end' ? x - w : x;
  const gs = font.stringToGlyphs(s);
  let at = 0;
  let uses = '';
  gs.forEach((g, i) => {
    if (g.path && g.path.commands && g.path.commands.length) uses += `<use href="#${glyphId(font, g)}" x="${Math.round(at)}"/>`;
    at += g.advanceWidth;
    if (i + 1 < gs.length) at += font.getKerningValue(g, gs[i + 1]);
  });
  const k = (size / font.unitsPerEm).toFixed(5);
  return `<g fill="${fill}" transform="translate(${+x0.toFixed(1)} ${+y.toFixed(1)}) scale(${k})"${extra}>${uses}</g>`;
}

/// Several lines of text, [lineHeight] apart.
export function lines(list, x, y, opts = {}) {
  const lh = opts.lineHeight ?? (opts.size ?? 28) * 1.15;
  return list.map((s, i) => text(s, x, y + i * lh, opts)).join('');
}

/// A rough.js generator with a fixed seed, so a rebuild draws the same strokes.
export function sketch(seed = 7) {
  const gen = rough.generator();
  let n = seed;
  const base = { roughness: 1.3, bowing: 1.1, strokeWidth: 2.2, disableMultiStroke: false };
  const draw = (drawable) =>
    gen
      .toPaths(drawable)
      .map((p) => {
        const d = round1(p.d);
        const fill = p.fill && p.fill !== 'none' ? p.fill : 'none';
        const stroke = p.stroke && p.stroke !== 'none' ? p.stroke : 'none';
        const sw = stroke === 'none' ? '' : ` stroke-width="${+(+p.strokeWidth).toFixed(2)}" stroke-linecap="round" stroke-linejoin="round"`;
        return `<path d="${d}" fill="${fill}" stroke="${stroke}"${sw}/>`;
      })
      .join('');
  const o = (opts) => ({ ...base, seed: n++, ...opts });
  return {
    rect: (x, y, w, h, opts = {}) => draw(gen.rectangle(x, y, w, h, o(opts))),
    round: (x, y, w, h, r, opts = {}) => draw(gen.path(roundedRect(x, y, w, h, r), o(opts))),
    line: (x1, y1, x2, y2, opts = {}) => draw(gen.line(x1, y1, x2, y2, o(opts))),
    circle: (x, y, d, opts = {}) => draw(gen.circle(x, y, d, o(opts))),
    ellipse: (x, y, w, h, opts = {}) => draw(gen.ellipse(x, y, w, h, o(opts))),
    path: (d, opts = {}) => draw(gen.path(d, o(opts))),
    curve: (pts, opts = {}) => draw(gen.curve(pts, o(opts))),
    linear: (pts, opts = {}) => draw(gen.linearPath(pts, o(opts))),
    polygon: (pts, opts = {}) => draw(gen.polygon(pts, o(opts))),
  };
}

export function roundedRect(x, y, w, h, r) {
  return `M${x + r} ${y}H${x + w - r}Q${x + w} ${y} ${x + w} ${y + r}V${y + h - r}Q${x + w} ${y + h} ${x + w - r} ${y + h}H${x + r}Q${x} ${y + h} ${x} ${y + h - r}V${y + r}Q${x} ${y} ${x + r} ${y}Z`;
}

/// Rounds every number in path data to one decimal.
export function round1(d) {
  return d.replace(/-?\d*\.?\d+(e-?\d+)?/g, (m) => {
    const v = Math.round(parseFloat(m) * 10) / 10;
    return String(Object.is(v, -0) ? 0 : v);
  });
}

/// Rounds every number in path data to whole units (for art drawn far smaller than its units).
export function round0(d) {
  return d.replace(/-?\d*\.?\d+(e-?\d+)?/g, (m) => String(Math.round(parseFloat(m)) || 0));
}

/// The logo's two paths (orange, cream) in its own coordinates (1023 x 1031).
export function logoPaths() {
  const svg = fs.readFileSync(path.join(root, 'assets', 'branding', 'perch-logo.svg'), 'utf8');
  const ds = [...svg.matchAll(/<path d="([^"]+)"/g)].map((m) => m[1]);
  return { orange: ds[0], cream: ds[1], width: 1023, height: 1031 };
}

/// The bird alone (no twig, leaf or terminal), as in the app's intro (`introBirdOnly`):
/// the logo's subpaths that reach into that area, rounded to whole units, plus the clip
/// polygons that cut what crosses its edge.
export const birdClip = [
  [[0, -60], [1100, -60], [1100, 552], [232, 552], [232, 495], [0, 495]],
  [[468, 546], [585, 546], [640, 621], [500, 621]],
];

function subpaths(d) {
  return d.split(/(?=M)/).filter((s) => s.trim());
}

function bbox(sp) {
  const n = sp.match(/-?\d*\.?\d+/g).map(Number);
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (let i = 0; i + 1 < n.length; i += 2) {
    x0 = Math.min(x0, n[i]); x1 = Math.max(x1, n[i]);
    y0 = Math.min(y0, n[i + 1]); y1 = Math.max(y1, n[i + 1]);
  }
  return [x0, y0, x1, y1];
}

function inBird([x0, y0, x1, y1]) {
  // The main area, or the legs' quad (loosely, by its box).
  const main = y0 < 552 && (x1 > 232 || y0 < 495);
  const legs = x1 > 468 && x0 < 640 && y0 < 621 && y1 > 546;
  return main || legs;
}

/// The whole logo thinned to within [tolerance] logo units.
export function logoSimplified(tolerance) {
  const { orange, cream } = logoPaths();
  const s = (d) => subpaths(d).map((sp) => simplify(sp, tolerance)).join('');
  return { orange: s(orange), cream: s(cream), width: 1023, height: 1031 };
}

export function birdPaths({ tolerance = 0 } = {}) {
  const { orange, cream } = logoPaths();
  const keep = (d) => {
    const sps = subpaths(d).filter((sp) => inBird(bbox(sp)));
    return tolerance ? sps.map((sp) => simplify(sp, tolerance)).join('') : round0(sps.join(''));
  };
  return { orange: keep(orange), cream: keep(cream) };
}

/// One subpath of M/C/Z commands as a polygon: the curves sampled, then thinned with
/// Ramer-Douglas-Peucker to within [tol] units, whole-unit coordinates.
function simplify(sp, tol) {
  const toks = sp.match(/[MCZ]|-?\d*\.?\d+/g);
  const pts = [];
  let i = 0, cmd = '', cx = 0, cy = 0;
  while (i < toks.length) {
    if (/[MCZ]/.test(toks[i])) cmd = toks[i++];
    if (cmd === 'Z') continue;
    if (cmd === 'M') { cx = +toks[i++]; cy = +toks[i++]; pts.push([cx, cy]); cmd = 'C'; continue; }
    const [x1, y1, x2, y2, x, y] = toks.slice(i, i + 6).map(Number);
    i += 6;
    for (const t of [0.25, 0.5, 0.75, 1]) {
      const u = 1 - t;
      pts.push([
        u * u * u * cx + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x,
        u * u * u * cy + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y,
      ]);
    }
    cx = x; cy = y;
  }
  // A closed loop starts and ends at one point: thin its two halves, split at the point
  // farthest from the start.
  let far = 0;
  pts.forEach(([x, y], k) => {
    if (Math.hypot(x - pts[0][0], y - pts[0][1]) > Math.hypot(pts[far][0] - pts[0][0], pts[far][1] - pts[0][1])) far = k;
  });
  const out = far > 0 ? rdp(pts.slice(0, far + 1), tol).slice(0, -1).concat(rdp(pts.slice(far), tol)) : pts;
  if (out.length < 3) return '';
  return 'M' + out.map(([x, y]) => `${Math.round(x)} ${Math.round(y)}`).join('L') + 'Z';
}

function rdp(pts, tol) {
  if (pts.length < 3) return pts;
  const [ax, ay] = pts[0];
  const [bx, by] = pts[pts.length - 1];
  const len = Math.hypot(bx - ax, by - ay) || 1e-9;
  let best = -1, at = 0;
  for (let k = 1; k < pts.length - 1; k++) {
    const [px, py] = pts[k];
    const dist = Math.abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / len;
    if (dist > best) { best = dist; at = k; }
  }
  if (best <= tol) return [pts[0], pts[pts.length - 1]];
  const left = rdp(pts.slice(0, at + 1), tol);
  return left.slice(0, -1).concat(rdp(pts.slice(at), tol));
}

export const birdClipPath = birdClip.map((poly) => 'M' + poly.map((p) => p.join(' ')).join('L') + 'Z').join('');

/// An arrow head at (x2, y2) pointing away from (x1, y1), as rough lines.
export function arrowHead(sk, x1, y1, x2, y2, opts = {}, len = 16) {
  const a = Math.atan2(y2 - y1, x2 - x1);
  const p = (da) => [x2 - len * Math.cos(a + da), y2 - len * Math.sin(a + da)];
  const [ax, ay] = p(0.45);
  const [bx, by] = p(-0.45);
  return sk.line(ax, ay, x2, y2, opts) + sk.line(bx, by, x2, y2, opts);
}

/// A complete SVG document with a rounded card behind it.
export function svgDoc(w, h, body, { bg, title, radius = 18 } = {}) {
  const card = bg ? `<rect width="${w}" height="${h}" rx="${radius}" fill="${bg}"/>` : '';
  const t = title ? `<title>${title}</title>` : '';
  const defs = glyphs.size ? `<defs>${glyphDefs()}</defs>` : '';
  return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}">${t}${defs}${card}${body}</svg>\n`;
}
