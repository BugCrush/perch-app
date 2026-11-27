// Install in three steps, as toys: the terminal with the plugin commands (its spinner
// turns), the phone with the APK (the arrow bobs into the tray), and pairing (the camera's
// scan line sweeps, the QR code in 3D, and Allow pressed in the "Let this phone in?" card).
import { setup, THREE, puffy, chrome, soft, frontZ, C, lit, S, wx, wy, tau, span, bump } from '../kit.js';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

const W = 1280, H = 480;
// Screen text stays dark in both themes: the screens are cream.
const ink = C.ink, quiet = '#7A685C', accent = '#D8431F', amber = '#B87410';

export async function build(card, q) {
  const k = await setup(card, q, W, H);
  const { theme, hand, tag, label, add, slab, place, pill, ink: inked } = k;

  // ---- 1. The terminal.
  const t1 = k.terminal(225, 165, 370, 250);
  const z1 = t1.z + 0.3;
  tag(t1.g, -160, -62, z1, '&gt;', hand(26, accent));
  tag(t1.g, -140, -62, z1, '/plugin marketplace add', hand(26, ink));
  tag(t1.g, -140, -34, z1, 'BugCrush/perch-app', hand(26, ink));
  tag(t1.g, -160, 0, z1, '&gt;', hand(26, accent));
  tag(t1.g, -140, 0, z1, '/plugin install perch@perch', hand(26, ink));
  tag(t1.g, -140, 34, z1, 'then start a new session', hand(21, quiet, 500));
  tag(t1.g, -122, 76, z1, 'installing the Perch host…', hand(23, amber));
  const spin = new THREE.Group();
  spin.position.set(wx(-148), wy(76), z1);
  t1.g.add(spin);
  const arc = new THREE.Mesh(new THREE.TorusGeometry(0.95, 0.24, 12, 40, Math.PI * 1.5), chrome(C.amber, 0.08));
  arc.userData.inkGroup = k.nextId();
  spin.add(arc);
  k.shadow(225, 300, 34, 4, 0.9);

  // ---- 2. The phone and the APK.
  const p2 = k.phone(600, 165, 180, 285);
  const z2 = p2.z;
  const dl = new THREE.Group();
  p2.g.add(dl);
  const arrowMat = chrome(lit.orange, 0.1);
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.6, 0.6, 4.2, 16), arrowMat);
  shaft.position.y = 0.9;
  const head = new THREE.Mesh(new THREE.ConeGeometry(1.25, 1.8, 24), arrowMat);
  head.rotation.x = Math.PI; head.position.y = -1.9;
  for (const m of [shaft, head]) { m.userData.inkGroup = 60; dl.add(m); }
  const tray = place(p2.g, slab(-40, -12, 80, 11, 5.5, lit.orange, 0.8), puffy(lit.orange, { vertexColors: true }), z2 - 0.1);
  tag(p2.g, 0, 18, z2 + 0.5, 'perch-&lt;version&gt;.apk', hand(19, ink), 'center');
  tag(p2.g, 0, 42, z2 + 0.5, 'the latest release', hand(18, quiet, 500), 'center');
  const install = pill(p2.g, -52, 62, 104, 32, lit.orange, z2 - 0.1);
  tag(p2.g, 0, 78, z2 + 1.2, 'Install', hand(22, '#FFF6EC'), 'center');
  k.shadow(600, 318, 22, 4, 0.9);

  // ---- 3. Pairing: /perch shows a QR code, the camera scans it, Allow at the computer.
  const t3 = k.terminal(918, 132, 262, 186);
  const z3 = t3.z + 0.3;
  tag(t3.g, -110, -40, z3, '/perch', hand(27, accent));
  tag(t3.g, -110, -6, z3, 'Pair your', hand(23, ink));
  tag(t3.g, -110, 20, z3, 'phone', hand(23, ink));
  const qr = (parent, cx, cy, cell, z, seed) => {
    const n = 11, parts = [];
    let r = seed;
    const rnd = () => { r = (r * 16807) % 2147483647; return r / 2147483647; };
    const finder = (i, j) => [[0, 0], [n - 3, 0], [0, n - 3]].some(([a, b]) => i >= a && i < a + 3 && j >= b && j < b + 3);
    for (let j = 0; j < n; j++) for (let i = 0; i < n; i++) {
      const on = finder(i, j) || rnd() > 0.52;
      if (!on) continue;
      const b = new THREE.BoxGeometry(cell * 0.92, cell * 0.92, cell * 0.7);
      b.translate(cx + (i - n / 2 + 0.5) * cell, cy - (j - n / 2 + 0.5) * cell, 0);
      parts.push(b);
    }
    const m = add(parent, mergeGeometries(parts), new THREE.MeshPhysicalMaterial({ color: '#241a14', roughness: 0.35, clearcoat: 0.8 }));
    m.position.z = z;
    return m;
  };
  place(t3.g, slab(22, -62, 100, 100, 10, '#FFF6EC', 0.5), soft('#FFF6EC', { vertexColors: true }), t3.z - 0.25);
  qr(t3.g, wx(72), wy(-12), 0.78, t3.z + 0.25, 7);
  const ph = k.phone(1178, 152, 118, 212);
  qr(ph.g, 0, wy(-4), 0.42, ph.z + 0.2, 7);
  const scan = new THREE.Mesh(new THREE.CapsuleGeometry(0.18, 5.2, 6, 12), chrome(C.amber, 0.05));
  scan.rotation.z = Math.PI / 2;
  scan.userData.inkGroup = k.nextId();
  ph.g.add(scan);
  tag(ph.g, 0, 72, ph.z + 0.4, 'camera', hand(18, quiet, 500), 'center');
  k.shadow(1178, 268, 16, 3, 0.8);
  // The viewfinder corners, drawn.
  {
    const vf = { stroke: theme.name === 'dark' ? C.amber : '#C98316', strokeWidth: 3, roughness: 0.6 };
    const [cx, cy] = [1178, 148], d = 40, l = 14;
    for (const [sx, sy] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) k.svg.appendChild(k.rc.linearPath([[cx + sx * d, cy + sy * (d - l)], [cx + sx * d, cy + sy * d], [cx + sx * (d - l), cy + sy * d]], vf));
  }
  k.route(k.bez([1112, 146], [1088, 128], [1056, 124]), { stroke: theme.name === 'dark' ? C.amber : '#C98316', strokeWidth: 3, roughness: 0.8, strokeLineDash: [8, 7] });
  // "Let this phone in?"
  const dlg = k.group(952, 288);
  const dgeo = slab(-142, -46, 284, 92, 14, lit.orange, 0.7, { patches: [{ color: '#FFF6EC', puff: 0.15, radius: 6, soften: 0.3, draw: (c) => { c.beginPath(); c.roundRect(-136, -40, 272, 80, 10); c.fill(); } }] });
  add(dlg, dgeo, puffy(lit.orange, { vertexColors: true }));
  const dz = frontZ(dgeo, 0, 0, 2);
  tag(dlg, -122, -20, dz + 0.6, 'Let this phone in?', hand(24, ink));
  const allow = pill(dlg, -126, 6, 74, 28, lit.orange, dz - 0.15);
  pill(dlg, -44, 6, 106, 28, '#FFF6EC', dz - 0.15, { mat: soft('#FFF6EC', { vertexColors: true }) });
  pill(dlg, 70, 6, 58, 28, '#FFF6EC', dz - 0.15, { mat: soft('#FFF6EC', { vertexColors: true }) });
  tag(dlg, -89, 20, dz + 1.2, 'Allow', hand(20, '#FFF6EC'), 'center');
  tag(dlg, 9, 20, dz + 1.2, 'Watch only', hand(20, ink), 'center');
  tag(dlg, 99, 20, dz + 1.2, 'Deny', hand(20, ink), 'center');

  // ---- Arrows between the steps, and the captions.
  const line = { stroke: theme.name === 'dark' ? '#A8968A' : '#7A685C', strokeWidth: 2.6, roughness: 1.2 };
  k.route(k.bez([424, 172], [452, 150], [492, 170]), line);
  k.route(k.bez([706, 172], [736, 150], [778, 170]), line);
  const caption = (x, n, title, sub) => {
    k.disc(x, 378, n);
    label(title, x + 30, 377, hand(32, theme.text));
    label(sub, x + 30, 412, hand(22, theme.quiet, 500));
  };
  caption(60, 1, 'On the computer', 'add the plugin in Claude Code');
  caption(482, 2, 'On the phone', 'the app from the release');
  caption(812, 3, 'Pair', '/perch: Pair your phone, scan, Allow');
  label('away from home? /perch, then Enter invite code', 1240, 452, hand(21, theme.quiet, 500), 'right');

  k.finish();
  const frame = (i) => {
    const t = i / k.frames;
    spin.rotation.z = -tau * 2 * t;
    const drop = (t * 2) % 1;
    dl.position.set(0, wy(-62) - 2.2 * span(drop, 0, 0.6) + 2.2 * span(drop, 0.85, 1), z2 + 1.2);
    tray.scale.y = 1 - 0.25 * bump(drop, 0.62, 0.05);
    install.scale.z = 1 - 0.4 * bump(t, 0.9, 0.03);
    scan.position.set(0, wy(-4) + 3.4 * Math.sin(tau * t), ph.z + 1.0);
    allow.scale.z = 1 - 0.5 * bump(t, 0.55, 0.035);
    k.render(i);
  };
  return { frames: k.frames, frame };
}
