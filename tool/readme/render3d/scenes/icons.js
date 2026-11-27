// The feature icons: ten small toys in the same inflated / chrome / soft-cream language,
// each moving the way the real thing would (the bell rings, the board's lines get written,
// the sand runs...). They share one sheet (5 x 2 cells); render.mjs captures each cell
// per frame and encodes one looping WebP per icon.
import { THREE, Stage, themes, inflate, puffy, chrome, soft, capped, fontsReady, C, lit } from '../core.js';

export const CELL = 140;
export const names = ['sessions', 'cards', 'notify', 'start', 'board', 'attach', 'search', 'limits', 'private', 'drafts'];
const COLS = 5;
const W = CELL * COLS, H = CELL * 2;

const tau = Math.PI * 2;
const clamp01 = (x) => Math.min(1, Math.max(0, x));
const ease = (x) => { const t = clamp01(x); return t * t * (3 - 2 * t); };
const span = (t, a, b) => ease((t - a) / (b - a));
const bump = (t, c, w) => Math.exp(-Math.pow((t - c) / w, 2)) + Math.exp(-Math.pow((t - c - 1) / w, 2)) + Math.exp(-Math.pow((t - c + 1) / w, 2));

export async function build(card, q) {
  const theme = themes[q.get('theme') ?? 'light'];
  const ratio = Number(q.get('ratio') ?? 1);
  const frames = Number(q.get('frames') ?? 40);
  card.style.width = W + 'px';
  card.style.height = H + 'px';
  await fontsReady();
  const canvas = document.createElement('canvas');
  canvas.style.left = '0px';
  canvas.style.top = '0px';
  card.appendChild(canvas);
  const stage = new Stage(canvas, theme, { width: W, height: H, pixelRatio: ratio, inkWidth: 1.6, jitter: 1.4 });
  stage.lights({ key: 3.0, fill: 0.6, rim: 1.8 });
  const scene = stage.scene;
  const camera = new THREE.OrthographicCamera(0, W, 0, -H, 1, 2000);
  camera.position.set(0, 0, 1000);
  let id = 1;
  const mesh = (parent, geo, mat) => { const m = new THREE.Mesh(geo, mat); m.userData.inkGroup = id++; parent.add(m); return m; };
  const inked = (o) => { o.traverse((m) => { if (m.isMesh) m.userData.inkGroup = id++; }); return o; };
  const blob = (draw, box, { radius = 14, depth = 1.0, dome = 0.1, color = lit.orange, patches = [], res = 2 } = {}) =>
    inflate({ base: draw, box, res, scale: 1, radius, depth, dome, soften: 0.6, smooth: 2, color, patches });
  const rr = (x, y, w, h, r) => (g) => { g.beginPath(); g.roundRect(x, y, w, h, r); g.fill(); };
  const top = (geo) => { let z = -Infinity; const p = geo.getAttribute('position'); for (let i = 0; i < p.count; i++) z = Math.max(z, p.getZ(i)); return z; };

  // A stroke (a tube along points) that can be drawn from its start: draw(from, to) in 0..1.
  const stroke = (parent, pts, r, mat, segs = 80) => {
    const radial = 12;
    const geo = new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts.map((p) => new THREE.Vector3(...p))), segs, r, radial);
    const tube = mesh(parent, geo, mat);
    const a = mesh(parent, new THREE.SphereGeometry(r, 16, 12), mat);
    const b = mesh(parent, new THREE.SphereGeometry(r, 16, 12), mat);
    const curve = geo.parameters.path;
    a.userData.inkGroup = b.userData.inkGroup = tube.userData.inkGroup;
    return (from, to) => {
      const i0 = Math.round(clamp01(from) * segs), i1 = Math.round(clamp01(to) * segs);
      const show = i1 > i0;
      tube.visible = a.visible = b.visible = show;
      if (!show) return;
      geo.setDrawRange(i0 * radial * 6, (i1 - i0) * radial * 6);
      a.position.copy(curve.getPointAt(i0 / segs));
      b.position.copy(curve.getPointAt(i1 / segs));
    };
  };

  const make = {
    sessions(g) {
      const geo = blob(rr(-44, -36, 88, 62, 13), [-50, -42, 100, 74], { color: lit.cream, patches: [{ color: lit.orange, puff: -0.3, radius: 5, draw: rr(-35, -27, 70, 44, 8) }] });
      mesh(g, geo, soft(lit.cream, { vertexColors: true, roughness: 0.5 }));
      const z = top(geo);
      const mat = chrome('#FFE2BE', 0.08);
      g.add(inked(capped([[-24, 12, z], [-14, 2, z + 1], [-24, -8, z]], 3.2, mat)));
      // Typed characters (beads) and the cursor after them.
      const beads = [-6, 4, 14].map((x) => { const b = mesh(g, new THREE.SphereGeometry(3.4, 16, 12), mat); b.position.set(x, -6, z); return b; });
      const cursor = inked(capped([[0, 0, 0], [10, 0, 0]], 3.0, mat));
      g.add(cursor);
      return (t) => {
        const typed = t < 0.85 ? Math.floor(clamp01((t - 0.1) / 0.45) * 3.999) : 0;
        beads.forEach((b, k) => { b.visible = k < typed; b.scale.setScalar(b.visible ? 1 : 0.01); });
        cursor.position.set(-8 + typed * 10, -9, z);
        cursor.visible = typed < 3 ? true : Math.floor(t * 10) % 2 === 0;
      };
    },
    cards(g) {
      const back = blob(rr(-30, -40, 60, 78, 10), [-36, -46, 72, 90], { color: lit.cream });
      const b = mesh(g, back, puffy(lit.cream, { vertexColors: true }));
      b.position.set(-12, 4, -12); b.rotation.z = 0.22;
      const flip = new THREE.Group();
      flip.position.set(10, -4, 0);
      g.add(flip);
      const front = blob(rr(-30, -40, 60, 78, 10), [-36, -46, 72, 90], { color: lit.orange });
      const f = mesh(flip, front, puffy(lit.orange, { vertexColors: true }));
      f.material.side = THREE.DoubleSide;
      const z = top(front);
      const tick = inked(capped([[-12, 0, z], [-3, -10, z + 1], [14, 12, z]], 4, chrome('#FFE2BE', 0.08)));
      flip.add(tick);
      flip.rotation.z = -0.12;
      return (t) => {
        flip.rotation.y = tau * span(t, 0.3, 0.72);
        flip.position.z = 14 * Math.sin(Math.PI * span(t, 0.3, 0.72));
        b.rotation.z = 0.22 + 0.04 * Math.sin(tau * t);
      };
    },
    notify(g) {
      const swing = new THREE.Group();
      g.add(swing);
      swing.position.y = 38;
      const inner = new THREE.Group();
      inner.position.y = -38;
      swing.add(inner);
      const prof = [[0, 34], [9, 33], [17, 27], [21, 12], [24, -6], [31, -16], [34, -21], [0, -21]].map(([x, y]) => new THREE.Vector2(x, y));
      const bell = mesh(inner, new THREE.LatheGeometry(prof, 48), puffy(C.amber));
      bell.material.side = THREE.DoubleSide;
      const clap = new THREE.Group();
      clap.position.y = -4;
      inner.add(clap);
      const ball = mesh(clap, new THREE.SphereGeometry(8, 24, 16), chrome(lit.orange, 0.08));
      ball.position.set(0, -22, 4);
      mesh(g, new THREE.SphereGeometry(6, 24, 16), chrome(C.amber, 0.08)).position.set(0, 38, 0);
      g.rotation.x = 0.2;
      return (t) => {
        const env = bump(t, 0.35, 0.16);
        const a = 0.42 * env * Math.sin(tau * 5 * t);
        swing.rotation.z = a;
        clap.rotation.z = -1.1 * a + 0.25 * env * Math.sin(tau * 5 * t - 1.2);
      };
    },
    start(g) {
      const geo = blob((c) => { c.beginPath(); c.arc(0, 0, 42, 0, Math.PI * 2); c.fill(); }, [-48, -48, 96, 96], {
        radius: 22, depth: 0.9, color: lit.orange,
        patches: [{ color: lit.cream, puff: 0.6, radius: 7, draw: (c) => { c.beginPath(); c.lineJoin = 'round'; c.lineWidth = 10; c.moveTo(-10, -20); c.lineTo(22, 0); c.lineTo(-10, 20); c.closePath(); c.fill(); c.stroke(); } }],
      });
      const m = mesh(g, geo, puffy(lit.orange, { vertexColors: true }));
      return (t) => {
        const press = bump(t, 0.3, 0.05);
        const pulse = 0.03 * Math.sin(tau * 2 * t);
        m.scale.set(1 + pulse + 0.05 * press, 1 + pulse + 0.05 * press, 1 - 0.45 * press);
      };
    },
    board(g) {
      const geo = blob(rr(-36, -42, 72, 88, 10), [-42, -48, 84, 100], { color: lit.cream, depth: 0.7 });
      mesh(g, geo, soft(lit.cream, { vertexColors: true, roughness: 0.5 }));
      const z = top(geo);
      const clip = blob(rr(-16, -50, 32, 16, 7), [-22, -56, 44, 28], { color: C.amber, radius: 7 });
      mesh(g, clip, chrome(C.amber, 0.1)).position.z = z - 4;
      const rows = [[-24, 46, lit.orange], [-4, 34, C.amber], [16, 40, lit.ember]];
      const bars = rows.map(([y, w, col]) => stroke(g, [[-20, -y - 6.5, z - 1], [-20 + w / 2, -y - 6.5, z - 0.5], [-20 + w, -y - 6.5, z - 1]], 6, puffy(col), 40));
      const nib = mesh(g, new THREE.SphereGeometry(3.5, 16, 12), chrome('#FFE2BE', 0.06));
      return (t) => {
        let pen = null;
        const gone = span(t, 0.88, 0.97);
        bars.forEach((draw, k) => {
          const u = clamp01((t - (0.06 + k * 0.24)) / 0.2);
          draw(gone, u);
          if (u > 0 && u < 1) pen = [-20 + rows[k][1] * u, -rows[k][0] - 6.5];
        });
        nib.visible = !!pen;
        if (pen) nib.position.set(pen[0], pen[1], z + 7);
      };
    },
    attach(g) {
      const pts = [];
      const arc = (cx, cy, r, a0, a1) => { for (let k = 0; k <= 10; k++) { const a = a0 + (a1 - a0) * k / 10; pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a), 0]); } };
      pts.push([-8, -14, 0]);
      arc(0, 28, 8, Math.PI, 0);
      arc(-2, -26, 18, 0, -Math.PI);
      arc(-4, 32, 14, Math.PI, 0);
      pts.push([10, -10, 0]);
      const dedup = pts.filter((p, i) => i === 0 || Math.hypot(p[0] - pts[i - 1][0], p[1] - pts[i - 1][1]) > 0.5);
      const clip = inked(capped(dedup.map(([x, y]) => [x, y, 0]), 4.2, chrome('#FFC48A', 0.08), { segments: 160, radial: 16 }));
      g.add(clip);
      return (t) => {
        const w = bump(t, 0.4, 0.14);
        clip.rotation.z = -0.5 + 0.22 * w * Math.sin(tau * 4 * t);
        clip.position.y = 3 * Math.sin(tau * t);
        clip.rotation.y = 0.25 * Math.sin(tau * t);
      };
    },
    search(g) {
      const lens = new THREE.Group();
      g.add(lens);
      mesh(lens, new THREE.TorusGeometry(24, 7, 24, 64), chrome('#FFD2A8', 0.08)).position.set(-8, 10, 0);
      const glass = mesh(lens, new THREE.SphereGeometry(23, 32, 16), new THREE.MeshPhysicalMaterial({ color: lit.cream, roughness: 0.05, clearcoat: 1, transparent: true, opacity: 0.75 }));
      glass.position.set(-8, 10, 0); glass.scale.z = 0.25;
      lens.add(inked(capped([[10, -10, 0], [34, -36, 0]], 8, puffy(lit.orange), { segments: 8, radial: 24 })));
      return (t) => {
        lens.position.set(9 * Math.cos(tau * t) - 2, 6 * Math.sin(tau * t), 0);
        lens.rotation.z = 0.12 * Math.sin(tau * t + 0.8);
      };
    },
    limits(g) {
      const turn = new THREE.Group();
      g.add(turn);
      const prof = [[3, 0], [10, 6], [20, 18], [24, 28], [22, 34], [0, 34]].map(([x, y]) => new THREE.Vector2(x, y));
      const glassMat = new THREE.MeshPhysicalMaterial({ color: '#FFF1E2', roughness: 0.05, clearcoat: 1, transparent: true, opacity: 0.5, side: THREE.DoubleSide });
      mesh(turn, new THREE.LatheGeometry(prof, 40), glassMat);
      mesh(turn, new THREE.LatheGeometry(prof, 40), glassMat).rotation.x = Math.PI;
      // Sand: a cone emptying from the upper bulb, a pile growing in the lower one.
      const upper = mesh(turn, new THREE.ConeGeometry(17, 18, 32), puffy(C.amber));
      upper.rotation.x = Math.PI; upper.position.y = 17;
      const lower = mesh(turn, new THREE.ConeGeometry(17, 18, 32), puffy(C.amber));
      lower.position.y = -17;
      const stream = mesh(turn, new THREE.CylinderGeometry(1.3, 1.3, 30, 8), puffy(C.amber));
      stream.position.y = -10;
      for (const y of [37, -37]) mesh(turn, new THREE.CylinderGeometry(28, 28, 7, 40), puffy(lit.orange)).position.y = y;
      for (const x of [-22, 22]) mesh(turn, new THREE.CylinderGeometry(2.4, 2.4, 70, 12), chrome(C.amber, 0.08)).position.set(x, 0, 10);
      g.rotation.x = 0.25; g.rotation.z = 0.12;
      return (t) => {
        const run = clamp01(t / 0.78);
        const a = Math.cbrt(Math.max(0.001, 1 - run)), b = Math.cbrt(Math.max(0.001, run));
        upper.scale.set(a, a, a); upper.position.y = 8 + 9 * a;
        lower.scale.set(b, b, b); lower.position.y = -34 + 9 * b + 8 * (1 - b) * 0;
        lower.position.y = -26 + 9 * (b - 1);
        stream.visible = run > 0.02 && run < 0.98;
        turn.rotation.z = Math.PI * span(t, 0.8, 0.98);
      };
    },
    private(g) {
      const body = blob(rr(-30, -6, 60, 48, 12), [-36, -12, 72, 60], { color: lit.orange, depth: 1.3 });
      const bm = mesh(g, body, puffy(lit.orange, { vertexColors: true }));
      const sh = Array.from({ length: 17 }, (_, i) => { const a = Math.PI * (i / 16); return [-18 * Math.cos(a), 6 + 26 * Math.sin(a), -4]; });
      sh.unshift([-18, -2, -4]); sh.push([18, -2, -4]);
      const shackle = inked(capped(sh, 5.5, chrome('#FFD2A8', 0.08), { segments: 80, radial: 16 }));
      g.add(shackle);
      const z = top(body);
      const kh = mesh(g, new THREE.SphereGeometry(6, 20, 14), new THREE.MeshPhysicalMaterial({ color: '#1a0f0a', roughness: 0.2, clearcoat: 1 }));
      kh.position.set(0, -18, z - 2); kh.scale.z = 0.4;
      g.position.y += 8;
      return (t) => {
        const up = span(t, 0.15, 0.3) * (1 - span(t, 0.58, 0.63));
        const click = bump(t, 0.64, 0.025);
        shackle.position.y = 10 * up - 1.5 * click;
        shackle.rotation.y = 0.9 * span(t, 0.28, 0.4) * (1 - span(t, 0.48, 0.58));
        bm.scale.set(1 + 0.04 * click, 1 - 0.05 * click, 1);
      };
    },
    drafts(g) {
      // The written line, revealed as the pencil moves along it.
      const path = Array.from({ length: 30 }, (_, k) => { const x = -46 + k * 2.2; return [x, -30 + 5 * Math.sin(x / 5), 0]; });
      const write = stroke(g, path, 3.2, puffy(lit.ember), 120);
      const p = new THREE.Group();
      const pencil = new THREE.Group();
      mesh(pencil, new THREE.CylinderGeometry(9, 9, 60, 6), puffy(lit.orange)).position.y = 46;
      const tip = mesh(pencil, new THREE.ConeGeometry(9, 18, 6), soft(lit.cream));
      tip.position.y = 7; tip.rotation.x = Math.PI;
      const lead = mesh(pencil, new THREE.ConeGeometry(3.4, 7, 12), new THREE.MeshPhysicalMaterial({ color: '#2B231D', roughness: 0.3 }));
      lead.position.y = 0; lead.rotation.x = Math.PI;
      mesh(pencil, new THREE.CylinderGeometry(9.6, 9.6, 9, 24), chrome('#FFD2A8', 0.08)).position.y = 80;
      mesh(pencil, new THREE.CapsuleGeometry(9, 4, 8, 24), puffy(lit.ember)).position.y = 88;
      pencil.rotation.z = -0.65;
      pencil.rotation.y = 0.4;
      p.add(pencil);
      g.add(p);
      g.position.set(-4, 2, 0);
      g.scale.setScalar(0.84);
      return (t) => {
        const w = span(t, 0.08, 0.7);
        const k = Math.min(path.length - 1, w * (path.length - 1));
        const i0 = Math.floor(k), f = k - i0, i1 = Math.min(path.length - 1, i0 + 1);
        const x = path[i0][0] + (path[i1][0] - path[i0][0]) * f, y = path[i0][1] + (path[i1][1] - path[i0][1]) * f;
        const back = span(t, 0.78, 0.98);
        const lift = 6 * Math.sin(Math.PI * back);
        p.position.set(x + (path[0][0] - x) * back, y + (path[0][1] - y) * back + lift, 3 + lift);
        write(span(t, 0.8, 0.96), w);
      };
    },
  };

  const anims = [];
  names.forEach((n, i) => {
    const g = new THREE.Group();
    anims.push(make[n](g));
    const wrap = new THREE.Group();
    wrap.add(g);
    wrap.position.set(CELL * (i % COLS) + CELL / 2, -(CELL * Math.floor(i / COLS) + CELL / 2), 0);
    wrap.rotation.set(-0.18, -0.32, 0);
    wrap.scale.setScalar(1.18);
    scene.add(wrap);
  });
  stage.assignIds();
  const frame = (i) => {
    const t = i / frames;
    for (const a of anims) a(t);
    stage.render(camera, 3.1 + Math.floor(i / 4) * 0.71);
  };
  return { frames, frame, cell: CELL, names, cols: COLS };
}
