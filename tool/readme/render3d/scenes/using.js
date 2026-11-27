// A tour of the app in five toy phones: every session (the working one's meter moves, the
// one that needs you pulses), answering a question deck (a box gets ticked, Submit), a new
// session (Start), the board (Run on…, the report comes back to Review), and Stop with a
// push sliding in when Claude is done.
import { setup, THREE, puffy, chrome, soft, frontZ, C, lit, wx, wy, tau, span, bump, capped } from '../kit.js';

const W = 1280, H = 480;
const ink = C.ink, quiet = '#7A685C', accent = '#D8431F', amber = '#B87410', green = '#1E9E4A';
const card = '#FFF6EC';

export async function build(cardEl, q) {
  const k = await setup(cardEl, q, W, H);
  const { theme, hand, tag, label, add, slab, place, pill } = k;
  const cardMat = () => soft(card, { vertexColors: true, roughness: 0.5 });
  const row = (g, x, y, w, h, z, color = card, rim = null) => {
    const geo = rim
      ? slab(x, y, w, h, 12, rim, 0.6, { patches: [{ color, puff: 0.12, radius: 5, soften: 0.3, draw: (c) => { c.beginPath(); c.roundRect(x + 4, y + 4, w - 8, h - 8, 9); c.fill(); } }] })
      : slab(x, y, w, h, 12, color, 0.6);
    return place(g, geo, rim ? puffy(rim, { vertexColors: true }) : cardMat(), z - 0.15);
  };
  const xs = [140, 390, 640, 890, 1140];
  const phones = xs.map((x) => { const p = k.phone(x, 180, 190, 315); k.shadow(x, 345, 22, 4, 0.9); return p; });
  const anim = [];

  // 1. Every session, with its state.
  {
    const { g, z } = phones[0];
    tag(g, -70, -112, z + 0.4, 'Studio PC', hand(25, ink));
    row(g, -76, -88, 152, 54, z); row(g, -76, -26, 152, 54, z); row(g, -76, 36, 152, 54, z);
    const r = (y, name, state, col) => { tag(g, -64, y - 10, z + 0.6, name, hand(20, ink)); tag(g, -64, y + 12, z + 0.6, state, hand(17, col)); };
    r(-61, 'billing-api', 'working', amber);
    r(1, 'photo-app', 'needs you', accent);
    r(63, 'api-docs', 'done', green);
    const bars = [0, 1, 2].map((i) => { const b = add(g, new THREE.CapsuleGeometry(0.45, 1.2, 4, 10), puffy(C.amber)); b.position.set(wx(38 + i * 12), wy(-61), z + 0.6); return b; });
    const dot = add(g, new THREE.SphereGeometry(0.75, 20, 14), puffy(lit.orange)); dot.position.set(wx(56), wy(1), z + 0.6);
    g.add(k.ink(capped([[wx(44), wy(63), z + 0.6], [wx(51), wy(70), z + 0.7], [wx(66), wy(54), z + 0.6]], 0.28, chrome('#5BD27F', 0.08), { segments: 16, radial: 10 })));
    anim.push((t) => {
      bars.forEach((b, i) => { b.scale.y = 0.7 + 0.6 * (0.5 + 0.5 * Math.sin(tau * (3 * t + i * 0.31))); });
      dot.scale.setScalar(1 + 0.25 * (0.5 + 0.5 * Math.sin(tau * 2 * t)));
    });
  }
  // 2. A question deck.
  {
    const { g, z } = phones[1];
    row(g, -80, -128, 160, 250, z);
    tag(g, -66, -108, z + 0.5, 'Claude asks · 2 of 2', hand(16, quiet, 500));
    tag(g, -66, -84, z + 0.5, 'Which formats?', hand(22, ink));
    const boxes = [];
    [['CSV', -56, true], ['TSV', -20, true], ['JSON', 16, false]].forEach(([name, y, on]) => {
      row(g, -68, y, 136, 28, z + 0.25, '#FBEBDC');
      tag(g, -56, y + 14, z + 0.8, name, hand(19, ink));
      const b = add(g, new THREE.BoxGeometry(1.25, 1.25, 0.8), on ? puffy(lit.orange) : soft('#FFF6EC'));
      b.position.set(wx(48), wy(y + 14), z + 0.7);
      boxes.push({ b, on });
    });
    const submit = pill(g, -50, 56, 100, 32, lit.orange, z + 0.25);
    tag(g, 0, 72, z + 1.4, 'Submit', hand(20, '#FFF6EC'), 'center');
    const json = boxes[2].b;
    const tickMat = puffy(lit.orange);
    const plain = json.material;
    anim.push((t) => {
      const on = t > 0.35 && t < 0.92;
      json.material = on ? tickMat : plain;
      json.scale.z = 1 - 0.5 * bump(t, 0.35, 0.025);
      submit.scale.z = 1 - 0.45 * bump(t, 0.7, 0.03);
    });
  }
  // 3. A new session.
  {
    const { g, z } = phones[2];
    tag(g, -70, -112, z + 0.4, 'New session', hand(24, ink));
    row(g, -76, -88, 152, 44, z);
    const folder = place(g, slab(-64, -77, 30, 22, 5, lit.orange, 0.8), puffy(lit.orange, { vertexColors: true }), z + 0.55);
    tag(g, -26, -66, z + 0.6, 'billing-api', hand(20, ink));
    row(g, -76, -34, 152, 44, z);
    tag(g, -64, -12, z + 0.6, 'model', hand(16, quiet, 500));
    tag(g, -14, -12, z + 0.6, 'Opus', hand(20, ink));
    tag(g, -70, 26, z + 0.4, 'the terminal opens', hand(16, quiet, 500));
    tag(g, -70, 46, z + 0.4, 'on the machine', hand(16, quiet, 500));
    const start = pill(g, -56, 70, 112, 34, lit.orange, z);
    tag(g, 0, 87, z + 1.2, 'Start', hand(22, '#FFF6EC'), 'center');
    anim.push((t) => { start.scale.z = 1 - 0.45 * bump(t, 0.5, 0.03); folder.rotation.z = 0.06 * Math.sin(tau * t); });
  }
  // 4. The board: Run on…, then Review.
  {
    const { g, z } = phones[3];
    tag(g, -70, -112, z + 0.4, 'Board', hand(24, ink));
    row(g, -76, -92, 152, 96, z, card, '#2B231D');
    tag(g, -62, -72, z + 0.6, 'Stream the', hand(19, ink));
    tag(g, -62, -50, z + 0.6, 'CSV export', hand(19, ink));
    const run = pill(g, -60, -34, 100, 26, lit.orange, z + 0.3);
    tag(g, -10, -21, z + 1.5, 'Run on…', hand(18, '#FFF6EC'), 'center');
    const review = row(g, -76, 38, 152, 62, z, card, '#2FA65A');
    tag(g, -62, 56, z + 0.6, 'Review', hand(19, green));
    tag(g, -62, 80, z + 0.6, 'Claude’s report', hand(17, ink, 500));
    const pkt = add(g, new THREE.CapsuleGeometry(0.5, 0.7, 6, 12), chrome('#FFD08A', 0.06));
    anim.push((t) => {
      run.scale.z = 1 - 0.45 * bump(t, 0.2, 0.03);
      const u = span(t, 0.25, 0.6);
      pkt.visible = u > 0 && u < 1;
      pkt.position.set(wx(0), wy(4 + 34 * u), z + 1.4);
      review.scale.setScalar(1 + 0.04 * bump(t, 0.64, 0.05));
    });
  }
  // 5. Stop, or be told.
  {
    const { g, z } = phones[4];
    const note = new THREE.Group();
    g.add(note);
    row(note, -80, -132, 160, 58, z + 0.4, card, lit.orange);
    const bellProf = [[0, 1.4], [0.5, 1.35], [0.8, 0.9], [0.95, -0.2], [1.25, -0.7], [0, -0.7]].map(([x, y]) => new THREE.Vector2(x, y));
    const bell = add(note, new THREE.LatheGeometry(bellProf, 24), puffy(C.amber));
    bell.material.side = THREE.DoubleSide;
    bell.position.set(wx(-60), wy(-103), z + 0.9);
    const l1 = tag(g, -42, -114, z + 1.2, 'api-docs', hand(18, accent));
    const l2 = tag(g, -42, -92, z + 1.2, 'Claude is done', hand(17, ink, 500));
    for (const [y, w] of [[-44, 130], [-20, 100], [4, 136], [28, 80]]) place(g, slab(-68, y, w, 8, 4, '#9E8676', 0.35), puffy('#9E8676', { vertexColors: true }), z - 0.1);
    const stop = row(g, -46, 62, 92, 36, z, card, lit.orange);
    const sq = add(g, new THREE.BoxGeometry(1.2, 1.2, 0.7), puffy(lit.orange));
    sq.position.set(wx(-24), wy(80), z + 0.6);
    tag(g, 10, 80, z + 1.0, 'Stop', hand(21, accent), 'center');
    anim.push((t) => {
      const inn = span(t, 0.1, 0.22) * (1 - span(t, 0.86, 0.97));
      note.position.y = (1 - inn) * 6;
      note.visible = inn > 0.02;
      l1.style.opacity = l2.style.opacity = String(inn > 0.9 ? 1 : 0);
      bell.rotation.z = 0.5 * bump(t, 0.3, 0.07) * Math.sin(tau * 6 * t);
      stop.scale.z = 1 - 0.4 * bump(t, 0.62, 0.03);
    });
  }

  // Captions.
  const caps = [
    ['Every session', 'working, needs you, done'],
    ['Answer cards', 'Allow, Approve a plan, Submit'],
    ['Start a session', 'any folder, any model'],
    ['Run tasks', 'Run on…, then Review'],
    ['Stop, or be told', 'a push when done or needed'],
  ];
  caps.forEach(([a, b], i) => {
    label(a, xs[i] - 104, 388, hand(32, theme.accent));
    label(b, xs[i] - 104, 422, hand(22, theme.quiet, 500));
  });

  k.finish();
  const frame = (i) => { const t = i / k.frames; for (const a of anim) a(t); k.render(i); };
  return { frames: k.frames, frame };
}
