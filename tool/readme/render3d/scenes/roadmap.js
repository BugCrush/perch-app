// Perch's flight path: the hand-torn map stays drawn, the landmarks on it are toys. The
// trail so far is a puffy orange rope, the road ahead a row of beads. The clock by the
// desk spins, the 1.0 flag waves, the camp fire flickers, the bird by it blinks, the globe
// turns and the compass needle settles.
import { setup, THREE, puffy, chrome, soft, frontZ, C, lit, S, wx, wy, tau, span, bump, capped, inflate } from '../kit.js';
import { makeBird } from '../logo.js';

const W = 1280, H = 830;

export async function build(card, q) {
  const k = await setup(card, q, W, H, { background: false, radius: 0 });
  const { theme, dark, hand, label, add, slab, place, group } = k;
  const t = {
    sheet: dark ? C.ink : '#F4E2C1',
    edge: dark ? '#5A4A3E' : '#B98F5A',
    line: dark ? '#EADBCB' : '#3A2A1C',
    text: dark ? C.cream : '#2A1E14',
    quiet: dark ? '#A8968A' : '#806A55',
    ahead: dark ? '#8C7B6E' : '#9A8166',
    panel: '#FBEBDC',
  };

  // ---- The sheet (drawn, under the 3D).
  let seed = 3;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const edge = [];
  const m = 10;
  const side = (x0, y0, x1, y1, n, nx, ny) => { for (let i = 0; i < n; i++) { const u = i / n, j = rnd() * 9; edge.push([x0 + (x1 - x0) * u + nx * j, y0 + (y1 - y0) * u + ny * j]); } };
  side(m, m, W - m, m, 40, 0, 1); side(W - m, m, W - m, H - m, 24, -1, 0); side(W - m, H - m, m, H - m, 40, 0, -1); side(m, H - m, m, m, 24, 1, 0);
  const sheetD = 'M' + edge.map(([x, y]) => `${x.toFixed(1)} ${y.toFixed(1)}`).join('L') + 'Z';
  const sheet = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  sheet.setAttribute('d', sheetD); sheet.setAttribute('fill', t.sheet);
  k.under.appendChild(sheet);
  k.under.appendChild(k.rcUnder.path(sheetD, { stroke: t.edge, strokeWidth: 2, roughness: 0.8 }));
  const faint = { stroke: t.quiet, strokeWidth: 1.6, roughness: 0.9 };
  for (const [x, y] of [[70, 724], [130, 744], [190, 722], [1040, 620], [1080, 636]]) k.under.appendChild(k.rcUnder.curve([[x, y], [x + 10, y - 7], [x + 20, y], [x + 30, y - 7], [x + 40, y]], faint));
  for (const [x, y] of [[560, 150], [610, 140]]) k.under.appendChild(k.rcUnder.linearPath([[x - 26, y + 20], [x, y - 8], [x + 26, y + 20]], faint));
  const palm = (px, py, s) => {
    k.under.appendChild(k.rcUnder.curve([[px, py], [px + 4 * s, py - 30 * s], [px + 2 * s, py - 60 * s]], { stroke: t.quiet, strokeWidth: 2, roughness: 0.8 }));
    for (const [dx, dy] of [[-30, 6], [-22, -10], [24, -8], [30, 8], [4, -22]]) k.under.appendChild(k.rcUnder.curve([[px + 2 * s, py - 60 * s], [px + 2 * s + dx * 0.5 * s, py - 60 * s + dy * s - 8 * s], [px + 2 * s + dx * s, py - 60 * s + dy * s + 6 * s]], { stroke: t.quiet, strokeWidth: 1.8, roughness: 0.8 }));
  };
  palm(1180, 700, 1); palm(1216, 712, 0.75);
  label('Perch’s flight path', 54, 62, hand(46, t.text));
  label('the road so far, and the road ahead', 56, 100, hand(24, t.quiet, 500));
  k.svg.appendChild(k.rc.line(58, 126, 110, 126, { stroke: C.orange, strokeWidth: 4, roughness: 0.6 }));
  label('done', 120, 127, hand(22, t.text, 500));
  for (let x = 192; x < 244; x += 11) { const d = document.createElementNS('http://www.w3.org/2000/svg', 'circle'); d.setAttribute('cx', x); d.setAttribute('cy', 126); d.setAttribute('r', 3); d.setAttribute('fill', t.ahead); k.svg.appendChild(d); }
  label('ahead', 252, 127, hand(22, t.text, 500));

  // ---- The trail: a puffy rope so far, beads ahead.
  const St = [[150, 270], [420, 270], [690, 270], [950, 270], [1020, 490], [740, 490], [500, 490], [250, 490], [330, 700], [860, 700]];
  const via = [St[0], [285, 300], St[1], [555, 240], St[2], [820, 300], St[3], [1110, 268], [1212, 330], [1214, 440], [1150, 492], St[4],
    [880, 520], St[5], [620, 460], St[6], [375, 520], St[7], [140, 560], [170, 660], St[8], [600, 730], St[9]];
  const cut = 11;
  const zT = -6;
  const curve = (pts) => new THREE.CatmullRomCurve3(pts.map(([x, y]) => new THREE.Vector3(wx(x), wy(y), zT)), false, 'centripetal');
  const done = curve(via.slice(0, cut + 1));
  add(k.scene, new THREE.TubeGeometry(done, 400, 0.42, 14), puffy(lit.orange));
  const ahead = curve(via.slice(cut));
  const beadMat = puffy(dark ? '#8C7B6E' : '#C9B08E');
  const len = ahead.getLength();
  const beads = new THREE.Group();
  k.scene.add(beads);
  const nBeads = Math.floor(len / 2.0);
  const beadList = [];
  for (let i = 1; i < nBeads; i++) {
    const b = new THREE.Mesh(new THREE.SphereGeometry(0.34, 12, 8), beadMat);
    b.userData.noInk = true;
    b.position.copy(ahead.getPointAt(i / nBeads));
    beads.add(b);
    beadList.push(b);
  }
  St.forEach(([x, y], i) => {
    if (i === 9) return;
    const s = add(k.scene, new THREE.SphereGeometry(i <= 4 ? 0.85 : 0.75, 20, 14), i <= 4 ? puffy(lit.orange) : soft(t.sheet === C.ink ? '#3A2E27' : '#FBEBDC'));
    s.position.set(wx(x), wy(y), zT + 0.3);
  });
  const stopLabel = ([x, y], lines, date) => {
    lines.forEach((l, j) => label(l, x, y + 36 + j * 26, hand(27, t.text), 'center'));
    if (date) label(date, x, y + 36 + lines.length * 26 - 2, hand(20, t.quiet, 500), 'center');
  };
  const miniPhone = (cx, cy, w, h) => {
    const g = group(cx, cy);
    const geo = slab(-w / 2, -h / 2, w, h, 10, '#2B231D', 0.9, { patches: [{ color: lit.cream, puff: -0.3, radius: 5, soften: 0.3, draw: (c) => { c.beginPath(); c.roundRect(-w / 2 + 5, -h / 2 + 8, w - 10, h - 16, 6); c.fill(); } }] });
    add(g, geo, puffy('#2B231D', { vertexColors: true }));
    return { g, z: frontZ(geo, 0, 0, 1) };
  };
  const anim = [];

  // 1. Waiting to get back to the desk: the desk, the empty chair, a terminal asking, a clock that spins.
  {
    const [x, y] = St[0];
    const desk = group(x - 11, y - 20);
    add(desk, new THREE.BoxGeometry(10.2, 0.9, 3), soft('#C9A27A'));
    for (const dx of [-4.3, 4.3]) add(desk, new THREE.CylinderGeometry(0.25, 0.25, 1.6, 10), soft('#C9A27A')).position.set(dx, -1.2, 0);
    const scr = group(x - 10, y - 53);
    place(scr, slab(-42, -25, 84, 50, 7, '#FBEBDC', 0.8), soft('#FBEBDC', { vertexColors: true }));
    add(scr, new THREE.CylinderGeometry(0.3, 0.3, 0.9, 10), soft('#FBEBDC')).position.set(0, wy(29), -0.3);
    k.label('Allow? y/n', x - 10, y - 53, hand(17, '#D8431F'), 'center');
    const chairMat = puffy('#C9A27A');
    const chair = group(x + 72, y - 4, 0);
    chair.add(k.ink(capped([[wx(-12), wy(-66), 0], [wx(-12), 0, 0]], 0.3, chairMat, { segments: 8, radial: 10 })));
    chair.add(k.ink(capped([[wx(-12), wy(-32), 0], [wx(14), wy(-32), 0], [wx(14), 0, 0]], 0.3, chairMat, { segments: 8, radial: 10 })));
    const clock = group(x - 78, y - 96, 0);
    clock.scale.setScalar(1.45);
    add(clock, new THREE.CylinderGeometry(1.35, 1.35, 0.5, 32), soft('#FFF6EC')).rotation.x = Math.PI / 2;
    add(clock, new THREE.TorusGeometry(1.4, 0.22, 10, 32), chrome(C.amber, 0.08));
    const hm = add(clock, new THREE.BoxGeometry(0.16, 0.9, 0.16), puffy('#2B231D'));
    const hh = add(clock, new THREE.BoxGeometry(0.18, 0.6, 0.18), puffy('#2B231D'));
    anim.push((tt) => { hm.rotation.z = -tau * 2 * tt; hm.position.set(0.45 * Math.sin(tau * 2 * tt), 0.45 * Math.cos(tau * 2 * tt), 0.4); hh.rotation.z = -tau * tt / 6; hh.position.set(0.3 * Math.sin(tau * tt / 6), 0.3 * Math.cos(tau * tt / 6), 0.4); });
    stopLabel(St[0], ['Waiting to get', 'back to the desk'], 'before Perch');
  }
  // 2. Perch is born: a phone talking to a computer.
  {
    const [x, y] = St[1];
    miniPhone(x - 47, y - 46, 34, 60);
    const mon = group(x + 34, y - 55);
    place(mon, slab(-32, -21, 64, 42, 6, '#FBEBDC', 0.8), soft('#FBEBDC', { vertexColors: true }));
    add(mon, new THREE.CylinderGeometry(0.3, 0.3, 1.6, 10), soft('#FBEBDC')).position.set(0, wy(30), -0.3);
    add(mon, new THREE.BoxGeometry(3.2, 0.3, 1.2), soft('#FBEBDC')).position.set(0, wy(37), -0.3);
    const zig = k.ink(capped([[wx(x - 24), wy(y - 52), 1], [wx(x - 14), wy(y - 60), 1], [wx(x - 8), wy(y - 46), 1], [wx(x - 2), wy(y - 56), 1]], 0.22, chrome(lit.orange, 0.08), { segments: 20, radial: 8 }));
    k.scene.add(zig);
    anim.push((tt) => { zig.scale.setScalar(1 + 0.08 * bump(tt, 0.5, 0.08)); });
    stopLabel(St[1], ['Perch is born'], 'Windows + Android · Nov 2026');
  }
  // 3. Perch on the Mac: a laptop.
  {
    const [x, y] = St[2];
    const lap = group(x, y - 20);
    const scr = place(lap, slab(-46, -62, 92, 58, 7, '#FBEBDC', 0.8), soft('#FBEBDC', { vertexColors: true }));
    scr.rotation.x = -0.12;
    add(lap, new THREE.BoxGeometry(12.6, 0.7, 2.6), chrome('#E8D2BC', 0.2)).position.set(0, wy(4), 0.6);
    k.label('macOS', x, y - 52, hand(22, '#D8431F'), 'center');
    stopLabel(St[2], ['Perch on the Mac'], 'Nov 2026');
  }
  // 4. Perch 1.0: a flag on a hill.
  let flag;
  {
    const [x, y] = St[3];
    const hill = inflate({ box: [x - 80, y - 80, 160, 80], res: 0.7, scale: S, radius: 40, depth: 0.8, dome: 0.1, soften: 0.5, smooth: 2, color: dark ? '#6B5A48' : '#E6CDA3', back: false,
      base: (c) => { c.beginPath(); c.moveTo(x - 72, y - 8); c.quadraticCurveTo(x, y - 74, x + 72, y - 8); c.closePath(); c.fill(); } });
    add(k.scene, hill, puffy('#E6CDA3', { vertexColors: true })).position.z = -2;
    add(k.scene, new THREE.CylinderGeometry(0.22, 0.22, 7.6, 12), chrome('#E8D2BC', 0.1)).position.set(wx(x), wy(y - 76), 0.5);
    const fg = new THREE.PlaneGeometry(5.8, 3.0, 16, 4);
    fg.translate(2.9, 0, 0);
    flag = add(k.scene, fg, puffy(lit.orange));
    flag.material.side = THREE.DoubleSide;
    flag.position.set(wx(x) + 0.1, wy(y - 98), 0.5);
    flag.userData.base = fg.attributes.position.array.slice();
    const fl = k.label('1.0', x + 26, y - 96, hand(20, C.ink), 'center');
    anim.push((tt) => {
      const p = fg.attributes.position;
      for (let i = 0; i < p.count; i++) {
        const bx = flag.userData.base[i * 3], by = flag.userData.base[i * 3 + 1];
        p.setZ(i, 0.45 * (bx / 5.8) * Math.sin(tau * (tt * 2) - bx * 1.1));
        p.setY(i, by * (1 - 0.25 * (bx / 5.8)));
      }
      p.needsUpdate = true;
      fg.computeVertexNormals();
    });
    stopLabel(St[3], ['Perch 1.0'], '26 Nov 2026');
  }
  // 5. Beta with friends: tents, a fire, the bird. You are here.
  {
    const [x, y] = St[4];
    for (const [tx, s] of [[x - 70, 0.85], [x - 20, 1]]) {
      const tent = add(k.scene, new THREE.ConeGeometry(3.4 * s, 5.8 * s, 4), puffy(dark ? '#D9BFA0' : '#F3DDC0'));
      tent.position.set(wx(tx), wy(y - 10) + 2.9 * s, 0);
      tent.rotation.y = Math.PI / 4;
    }
    const logs = k.ink(capped([[wx(x + 26), wy(y - 10), 0.5], [wx(x + 58), wy(y - 18), 0.5]], 0.32, puffy('#8A5A3A'), { segments: 4, radial: 10 }));
    const logs2 = k.ink(capped([[wx(x + 26), wy(y - 18), 0.2], [wx(x + 58), wy(y - 10), 0.2]], 0.32, puffy('#8A5A3A'), { segments: 4, radial: 10 }));
    k.scene.add(logs, logs2);
    const flames = [[0, 1.0, lit.orange], [-0.7, 0.7, C.amber], [0.7, 0.75, lit.ember]].map(([dx, s, col]) => {
      const f = add(k.scene, new THREE.ConeGeometry(0.9 * s, 3.2 * s, 16), puffy(col));
      f.position.set(wx(x + 42) + dx, wy(y - 14) + 1.6 * s, 1 + dx * 0.2);
      f.userData.s = s;
      return f;
    });
    const bird = await makeBird(0.0125, { theme });
    const bh = group(x + 104, y - 6, 0.5);
    bh.add(bird.group);
    bird.group.position.set(-555 * 0.0125, 612 * 0.0125, 0);
    bh.rotation.y = -0.25;
    anim.push((tt) => {
      flames.forEach((f, i) => { const s = f.userData.s * (1 + 0.14 * Math.sin(tau * (5 * tt + i * 0.37)) + 0.08 * Math.sin(tau * (9 * tt + i))); f.scale.set(1, s / f.userData.s, 1); });
      bird.eyeGroup.scale.y = 1 - 0.9 * bump(tt, 0.4, 0.015);
      bh.rotation.z = 0.04 * Math.sin(tau * tt);
    });
    const bx = x - 4, by = y - 178, bw = 168, bh2 = 52;
    k.svg.appendChild(k.rc.rectangle(bx, by, bw, bh2, { stroke: C.orange, strokeWidth: 2.4, fill: t.sheet, fillStyle: 'solid', roughness: 1 }));
    k.svg.appendChild(k.rc.linearPath([[bx + 116, by + bh2 - 2], [bx + 140, by + bh2 + 22], [bx + 140, by + bh2 - 2]], { stroke: C.orange, strokeWidth: 2.4, roughness: 0.8 }));
    label('you are here!', bx + bw / 2, by + 26, hand(28, theme.accent), 'center');
    stopLabel(St[4], ['Beta with friends'], 'now');
  }
  // 6. Google Play: a phone with a bag.
  {
    const [x, y] = St[5];
    const p = miniPhone(x, y - 55, 52, 86);
    const bag = slab(-13, -18, 26, 24, 5, lit.orange, 1.0);
    place(p.g, bag, puffy(lit.orange, { vertexColors: true }), p.z - 0.05);
    p.g.add(k.ink(capped([[wx(-6), wy(-17), p.z + 0.2], [wx(-6), wy(-28), p.z + 0.2], [wx(6), wy(-28), p.z + 0.2], [wx(6), wy(-17), p.z + 0.2]], 0.18, chrome(C.amber, 0.08), { segments: 16, radial: 8 })));
    k.tag(p.g, 0, 22, p.z + 0.3, 'store', hand(16, '#D8431F'), 'center');
    stopLabel(St[5], ['Google Play']);
  }
  // 7. Own domain & website: a signpost and a turning globe.
  {
    const [x, y] = St[6];
    add(k.scene, new THREE.CylinderGeometry(0.26, 0.26, 9.6, 12), chrome('#E8D2BC', 0.12)).position.set(wx(x - 20), wy(y - 58), 0);
    const sign = group(x - 30, y - 88, 0.4);
    place(sign, inflate({ box: [-40, -18, 80, 36], res: 1.2, scale: S, radius: 8, depth: 0.8, dome: 0.05, soften: 0.3, smooth: 1, color: lit.orange, back: false,
      base: (c) => { c.beginPath(); c.moveTo(-34, -12); c.lineTo(22, -12); c.lineTo(34, 0); c.lineTo(22, 12); c.lineTo(-34, 12); c.closePath(); c.fill(); } }), puffy(lit.orange, { vertexColors: true }));
    k.label('www', x - 34, y - 88, hand(19, '#FFF6EC'), 'center');
    const globe = group(x + 34, y - 40, 0);
    add(globe, new THREE.SphereGeometry(2.5, 32, 20), puffy(dark ? '#D9BFA0' : '#FBEBDC'));
    const spin = new THREE.Group();
    globe.add(spin);
    for (const r of [0, Math.PI / 3, -Math.PI / 3]) { const ring = add(spin, new THREE.TorusGeometry(2.55, 0.1, 8, 48), chrome(C.amber, 0.1)); ring.rotation.y = r; }
    add(globe, new THREE.TorusGeometry(2.55, 0.1, 8, 48), chrome(C.amber, 0.1)).rotation.x = Math.PI / 2;
    anim.push((tt) => { spin.rotation.y = tau * tt / 3; });
    stopLabel(St[6], ['Own domain', '& website']);
  }
  // 8. Linux host: a terminal.
  {
    const [x, y] = St[7];
    const term = k.terminal(x, y - 54, 104, 76);
    k.tag(term.g, -40, 12, term.z + 0.3, '&gt; Linux', hand(21, '#D8431F'));
    stopLabel(St[7], ['Linux host']);
  }
  // 9. iPhone app.
  {
    const [x, y] = St[8];
    const p = miniPhone(x, y - 56, 54, 88);
    add(p.g, new THREE.CapsuleGeometry(0.22, 1.2, 4, 8), puffy('#2B231D')).rotation.z = Math.PI / 2;
    p.g.children[p.g.children.length - 1].position.set(0, wy(-34), p.z + 0.1);
    k.tag(p.g, 0, 4, p.z + 0.3, 'iPhone', hand(15, '#D8431F'), 'center');
    stopLabel(St[8], ['iPhone app']);
  }
  // 10. X marks the spot, and the chest.
  {
    const [x, y] = St[9];
    for (const a of [Math.PI / 4, -Math.PI / 4]) {
      const c = add(k.scene, new THREE.CapsuleGeometry(0.5, 6.2, 8, 16), puffy(lit.orange));
      c.position.set(wx(x), wy(y - 2), 0);
      c.rotation.z = a;
    }
    const chest = group(x + 110, y - 22, 0);
    add(chest, new THREE.BoxGeometry(9.2, 5.0, 4.4), puffy(dark ? '#B07A45' : '#C98A4B'));
    const lid = add(chest, new THREE.CapsuleGeometry(1.6, 6.4, 8, 24), puffy(dark ? '#B07A45' : '#C98A4B'));
    lid.rotation.z = Math.PI / 2; lid.scale.set(1, 1.45, 1.4); lid.position.y = 2.6;
    for (const dx of [-3.6, 3.6]) add(chest, new THREE.BoxGeometry(0.5, 5.2, 4.6), chrome(C.amber, 0.12)).position.x = dx;
    add(chest, new THREE.BoxGeometry(1.2, 1.4, 0.6), chrome(C.amber, 0.08)).position.set(0, 1.6, 2.3);
    for (const [cx, cy, cz] of [[5.4, -2.2, 1.4], [6.2, -1.6, 0.4], [5.0, -1.2, 0.0]]) {
      const coin = add(chest, new THREE.CylinderGeometry(0.75, 0.75, 0.3, 24), chrome(C.amber, 0.06));
      coin.position.set(cx, cy, cz); coin.rotation.x = 1.2;
    }
    chest.rotation.y = -0.35;
    label('Public launch:', x + 112, y + 40, hand(28, theme.accent), 'center');
    label('Perch for everyone', x + 112, y + 68, hand(27, t.text), 'center');
    anim.push((tt) => { chest.position.y = wy(y - 22) + 0.15 * bump(tt, 0.75, 0.04); });
  }
  // The compass.
  {
    const comp = group(1180, 104, 0);
    add(comp, new THREE.TorusGeometry(4.0, 0.3, 12, 48), chrome('#E8D2BC', 0.08));
    add(comp, new THREE.CylinderGeometry(3.8, 3.8, 0.3, 40), soft(dark ? '#2A221C' : '#F8EBD2')).rotation.x = Math.PI / 2;
    const needle = new THREE.Group();
    comp.add(needle);
    const n = add(needle, new THREE.ConeGeometry(0.8, 4.4, 4), puffy(lit.orange)); n.position.y = 2.2; n.scale.z = 0.4;
    const s2 = add(needle, new THREE.ConeGeometry(0.8, 4.4, 4), puffy(dark ? '#D9BFA0' : '#FBEBDC')); s2.position.y = -2.2; s2.rotation.z = Math.PI; s2.scale.z = 0.4;
    needle.position.z = 0.6;
    add(comp, new THREE.SphereGeometry(0.6, 16, 12), chrome(C.amber, 0.06)).position.z = 1.0;
    label('N', 1180, 44, hand(24, t.text), 'center');
    anim.push((tt) => { needle.rotation.z = 0.22 * Math.sin(tau * tt) * (0.6 + 0.4 * Math.cos(tau * 2 * tt)); });
  }

  k.finish();
  const frame = (i) => { const tt = i / k.frames; for (const a of anim) a(tt); k.render(i); };
  return { frames: k.frames, frame };
}
