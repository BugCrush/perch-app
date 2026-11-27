// Shared parts for the flat-camera diagrams (install, using Perch, roadmap): an
// orthographic stage where 1 world unit = 10 CSS pixels, so the handwritten layer lines up
// with the 3D, and a box of toys: puffy slabs, phones, terminal windows, pills, labels.
import { THREE, Stage, themes, inflate, puffy, chrome, soft, capped, blobShadow, frontZ, fontsReady, C, lit } from './core.js';
import rough from 'roughjs';

export const S = 0.1;
export const wx = (x) => x * S, wy = (y) => -y * S;
export const tau = Math.PI * 2;
export const clamp01 = (x) => Math.min(1, Math.max(0, x));
export const ease = (x) => { const t = clamp01(x); return t * t * (3 - 2 * t); };
export const span = (t, a, b) => ease((t - a) / (b - a));
/// A bump around [c] that wraps around the loop.
export const bump = (t, c, w) => [-1, 0, 1].reduce((s, k) => s + Math.exp(-Math.pow((t - c - k) / w, 2)), 0);

export async function setup(card, q, W, H, { background = true, radius = 22, inkWidth = 1.9, jitter = 2.2 } = {}) {
  const theme = themes[q.get('theme') ?? 'light'];
  const frames = Number(q.get('frames') ?? 40);
  const ratio = Number(q.get('ratio') ?? 1);
  const dark = theme.name === 'dark';
  card.style.width = W + 'px';
  card.style.height = H + 'px';
  if (background) card.style.background = theme.bg;
  card.style.borderRadius = radius + 'px';
  await fontsReady();

  const under = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  under.setAttribute('width', W);
  under.setAttribute('height', H);
  under.style.cssText = 'left:0;top:0';
  card.appendChild(under);
  const canvas = document.createElement('canvas');
  canvas.style.left = '0px';
  canvas.style.top = '0px';
  card.appendChild(canvas);
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('width', W);
  svg.setAttribute('height', H);
  svg.style.cssText = 'left:0;top:0;pointer-events:none';
  card.appendChild(svg);

  const stage = new Stage(canvas, theme, { width: W, height: H, pixelRatio: ratio, inkWidth, jitter });
  stage.lights({ key: 3.0, fill: 0.6, rim: 1.8 });
  const scene = stage.scene;
  const camera = new THREE.OrthographicCamera(0, W * S, 0, -H * S, 1, 200);
  camera.position.set(0, 0, 100);
  camera.lookAt(0, 0, 0);
  camera.updateMatrixWorld();

  let nextId = 100;
  const add = (parent, geo, mat) => { const m = new THREE.Mesh(geo, mat); m.userData.inkGroup = nextId++; parent.add(m); return m; };
  const ink = (o) => { o.traverse((m) => { if (m.isMesh) m.userData.inkGroup = nextId++; }); return o; };

  /// A puffy rounded slab drawn at (x, y, w, h) in its parent's pixel space; front only.
  const slab = (x, y, w, h, r, color, depth = 0.6, { patches = [], back = false, res = 1.2 } = {}) =>
    inflate({ box: [x - 6, y - 6, w + 12, h + 12], res, scale: S, radius: Math.min(r, h / 2, w / 2), depth, dome: 0.04, soften: 0.3, smooth: 1, color, back, patches,
      base: (g) => { g.beginPath(); g.roundRect(x, y, w, h, r); g.fill(); } });
  const place = (parent, geo, mat, z = 0) => { const m = add(parent, geo, mat); m.position.z = z; return m; };

  /// A group placed at pixel (cx, cy); its children use pixel offsets from there.
  const group = (cx, cy, z = 0) => { const g = new THREE.Group(); g.position.set(wx(cx), wy(cy), z); scene.add(g); return g; };

  /// A phone: dark puffy body, cream screen pressed in. Returns { g, z } (z = screen surface).
  const phone = (cx, cy, w, h, { tilt = 0 } = {}) => {
    const g = group(cx, cy);
    const body = inflate({
      box: [-w / 2 - 12, -h / 2 - 12, w + 24, h + 24], res: 0.8, scale: S, radius: 26, depth: 1.1, dome: 0.05, soften: 0.5, smooth: 2,
      color: dark ? '#3A302A' : '#2B231D',
      base: (c) => { c.beginPath(); c.roundRect(-w / 2, -h / 2, w, h, 30); c.fill(); },
      patches: [{ color: lit.cream, puff: -0.35, radius: 9, soften: 0.3, draw: (c) => { c.beginPath(); c.roundRect(-w / 2 + 11, -h / 2 + 18, w - 22, h - 36, 18); c.fill(); } }],
    });
    add(g, body, puffy('#2B231D', { vertexColors: true }));
    g.rotation.y = tilt;
    return { g, z: frontZ(body, 0, 0, 3) };
  };

  /// A terminal window: cream soft slab with an orange title bar and chrome dots.
  const terminal = (cx, cy, w, h, { z = 0, tilt = 0 } = {}) => {
    const g = group(cx, cy, z);
    const geo = inflate({
      box: [-w / 2 - 8, -h / 2 - 8, w + 16, h + 16], res: 0.7, scale: S, radius: 22, depth: 0.9, dome: 0.03, soften: 0.4, smooth: 2, color: '#FBEBDC',
      base: (c) => { c.beginPath(); c.roundRect(-w / 2, -h / 2, w, h, 18); c.fill(); },
      patches: [{ color: lit.orange, puff: 0.25, radius: 8, soften: 0.3, draw: (c) => { c.beginPath(); c.roundRect(-w / 2 + 2, -h / 2 + 2, w - 4, 30, [16, 16, 4, 4]); c.fill(); } }],
    });
    add(g, geo, soft('#FBEBDC', { vertexColors: true, roughness: 0.5 }));
    const tz = frontZ(geo, wx(-w / 2 + 24), wy(-h / 2 + 17), 1.2);
    for (const k of [0, 1, 2]) add(g, new THREE.SphereGeometry(0.55, 16, 12), chrome('#FFE2BE', 0.06)).position.set(wx(-w / 2 + 22 + k * 20), wy(-h / 2 + 17), tz + 0.2);
    g.rotation.y = tilt;
    return { g, z: frontZ(geo, 0, 0, 3) };
  };

  /// A pill button (puffy) at pixel (x, y) relative to the parent group.
  const pill = (parent, x, y, w, h, color, z, { mat } = {}) => {
    const geo = slab(x, y, w, h, h / 2, color, 0.8);
    return place(parent, geo, mat ?? puffy(color, { vertexColors: true }), z);
  };

  // Hand-drawn layer.
  const rc = rough.svg(svg, { options: { seed: 5 } });
  const rcUnder = rough.svg(under, { options: { seed: 9 } });
  const arrowHead = (x1, y1, x2, y2, o, el = svg, r = rc) => {
    const a = Math.atan2(y2 - y1, x2 - x1), len = 15;
    const p = (da) => [x2 - len * Math.cos(a + da), y2 - len * Math.sin(a + da)];
    el.appendChild(r.linearPath([p(0.45), [x2, y2], p(-0.45)], o));
  };
  const bez = (p0, p1, p2) => (t) => [(1 - t) * (1 - t) * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0], (1 - t) * (1 - t) * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]];
  const route = (r, o, { both = false, head = true } = {}) => {
    const pts = Array.from({ length: 12 }, (_, i) => r(i / 11));
    svg.appendChild(rc.curve(pts, o));
    if (head) { const [a, b] = [r(0.9), r(1)]; arrowHead(a[0], a[1], b[0], b[1], o); }
    if (both) { const [c, d] = [r(0.1), r(0)]; arrowHead(c[0], c[1], d[0], d[1], o); }
  };

  /// Projects a point of [obj] (local world units) to CSS pixels.
  const proj = (obj, x, y, z) => {
    obj.updateMatrixWorld(true);
    const v = new THREE.Vector3(x, y, z).applyMatrix4(obj.matrixWorld).project(camera);
    return [(v.x + 1) / 2 * W, (1 - v.y) / 2 * H];
  };
  const label = (html, x, y, style, anchor = 'left') => {
    const d = document.createElement('div');
    d.innerHTML = html;
    const tx = anchor === 'center' ? '-50%' : anchor === 'right' ? '-100%' : '0';
    d.style.cssText = `position:absolute;left:${x}px;top:${y}px;transform:translate(${tx},-50%);white-space:nowrap;${style}`;
    card.appendChild(d);
    return d;
  };
  /// A label on a 3D object (pixel offsets from the object's group origin, at depth z).
  const tag = (obj, px, py, z, html, style, anchor = 'left') => {
    const [x, y] = proj(obj, wx(px), wy(py), z);
    return label(html, x, y, style, anchor);
  };
  const hand = (size, color, w = 700) => `font:${w} ${size}px/1.1 Caveat;color:${color};`;

  const shadow = (x, y, w, d, o = 1) => {
    const sh = blobShadow(w, d, theme.shadow * o, theme.shadowRgb);
    sh.rotation.x = 0;
    sh.position.set(wx(x), wy(y), -9);
    scene.add(sh);
    return sh;
  };

  /// A numbered puffy disc (the install steps).
  const disc = (x, y, n, r = 18) => {
    const g = group(x, y);
    const geo = inflate({ box: [-r - 6, -r - 6, 2 * r + 12, 2 * r + 12], res: 1.5, scale: S, radius: r, depth: 0.8, dome: 0.1, soften: 0.3, smooth: 1, color: lit.orange,
      base: (c) => { c.beginPath(); c.arc(0, 0, r, 0, tau); c.fill(); } });
    add(g, geo, puffy(lit.orange, { vertexColors: true }));
    label(String(n), x, y + 1, hand(26, '#FFF6EC'), 'center');
    return g;
  };

  const render = (i, { boil = false } = {}) => stage.render(camera, boil ? Math.floor(i / 4) * 1.37 : 0.5);
  return { theme, dark, frames, stage, scene, camera, add, ink, slab, place, group, phone, terminal, pill, rc, rcUnder, svg, under, arrowHead, bez, route, proj, label, tag, hand, shadow, disc, render, finish: () => stage.assignIds(), nextId: () => nextId++ };
}

export { THREE, inflate, puffy, chrome, soft, capped, frontZ, C, lit };
