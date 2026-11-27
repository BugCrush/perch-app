// "How it works" as a little 3D world: the phone (with the bird on it), the relay as a
// liquid-chrome cloud with a lock, Firebase's bell, and the computer running the host.
// Hand-drawn arrows and handwritten labels sit on top; sealed chrome "packets" travel
// the routes in a seamless loop. Orthographic camera: 1 world unit = 10 CSS pixels, so
// the overlay lines up with the 3D without projection maths for most labels.
import { THREE, Stage, themes, inflate, puffy, chrome, soft, capped, blobShadow, frontZ, fontsReady, C, lit } from '../core.js';
import { makeBird } from '../logo.js';
import rough from 'roughjs';

const W = 1280, H = 760;
const S = 0.1; // world units per CSS pixel
const wx = (x) => x * S, wy = (y) => -y * S;

export async function build(card, q) {
  const theme = themes[q.get('theme') ?? 'light'];
  const frames = Number(q.get('frames') ?? 64);
  const ratio = Number(q.get('ratio') ?? 1);
  const dark = theme.name === 'dark';
  card.style.width = W + 'px';
  card.style.height = H + 'px';
  card.style.background = theme.bg;
  card.style.borderRadius = '22px';
  await fontsReady();

  const canvas = document.createElement('canvas');
  canvas.style.left = '0px';
  canvas.style.top = '0px';
  card.appendChild(canvas);
  const stage = new Stage(canvas, theme, { width: W, height: H, pixelRatio: ratio, inkWidth: 1.9, jitter: 2.4 });
  stage.lights({ key: 3.0, fill: 0.6, rim: 1.8 });
  const scene = stage.scene;
  const camera = new THREE.OrthographicCamera(0, W * S, 0, -H * S, 1, 200);
  camera.position.set(0, 0, 100);
  camera.lookAt(0, 0, 0);
  camera.updateMatrixWorld();

  const ink = (o, id) => { o.traverse((m) => { if (m.isMesh) m.userData.inkGroup = id; }); return o; };
  let nextId = 100;
  const add = (parent, geo, mat) => { const m = new THREE.Mesh(geo, mat); m.userData.inkGroup = nextId++; parent.add(m); return m; };

  // ---------------------------------------------------------------- The phone.
  const phone = new THREE.Group();
  const pc = { x: 185, y: 435 };
  phone.position.set(wx(pc.x), wy(pc.y), 0);
  scene.add(phone);
  const local = (f) => (g) => { g.translate(-pc.x, -pc.y); f(g); };
  const phoneBody = inflate({
    box: [-110, -200, 220, 400], res: 0.8, scale: S, radius: 30, depth: 1.2, dome: 0.05, soften: 0.5, smooth: 2,
    color: dark ? '#3A302A' : '#2B231D',
    base: (g) => { g.beginPath(); g.roundRect(-95, -185, 190, 370, 34); g.fill(); },
    patches: [{ color: lit.cream, puff: -0.35, radius: 10, soften: 0.3, draw: (g) => { g.beginPath(); g.roundRect(-82, -165, 164, 330, 22); g.fill(); } }],
  });
  add(phone, phoneBody, puffy('#2B231D', { vertexColors: true }));
  const pz = frontZ(phoneBody, 0, 0, 3);
  const slab = (x, y, w, h, r, color, depth = 0.6, mat) => {
    const geo = inflate({ box: [x - 6, y - 6, w + 12, h + 12], res: 1.2, scale: S, radius: Math.min(r, h / 2), depth, dome: 0.04, soften: 0.3, smooth: 1, color, back: false,
      base: (g) => { g.beginPath(); g.roundRect(x, y, w, h, r); g.fill(); } });
    return { geo, mat: mat ?? puffy(color, { vertexColors: true }) };
  };
  // Screen content: three lines, the card, Deny / Allow, the composer.
  for (const [i, w] of [120, 90, 130].entries()) {
    const b = slab(-68, -140 + i * 26, w, 10, 5, dark ? '#B9A391' : '#9E8676', 0.35);
    add(phone, b.geo, b.mat).position.z = pz - 0.1;
  }
  const cardS = slab(-72, -42, 144, 132, 16, '#FFF6EC', 0.7);
  add(phone, cardS.geo, soft('#FFF6EC', { vertexColors: true })).position.z = pz - 0.1;
  const cz = pz + frontZ(cardS.geo, 0, -wy(30), 2) - 0.1;
  const deny = slab(-60, 42, 56, 30, 15, lit.cream, 0.8);
  add(phone, deny.geo, deny.mat).position.z = cz - 0.05;
  const allow = slab(6, 42, 56, 30, 15, lit.orange, 0.8);
  const allowMesh = add(phone, allow.geo, allow.mat);
  allowMesh.position.z = cz - 0.05;
  const comp = slab(-72, 112, 144, 30, 15, '#FFF6EC', 0.5);
  add(phone, comp.geo, soft('#FFF6EC', { vertexColors: true })).position.z = pz - 0.1;
  phone.rotation.y = 0.14;
  phone.rotation.x = -0.05;
  // The bird on the phone's top edge.
  const bird = await makeBird(0.0185, { theme });
  const birdHolder = new THREE.Group();
  birdHolder.add(bird.group);
  bird.group.position.set(-555 * 0.0185, 612 * 0.0185, 0);
  birdHolder.position.set(wx(pc.x - 4), wy(250) + 0.1, 0.2);
  birdHolder.rotation.y = 0.35;
  scene.add(birdHolder);
  ink(bird.group, 50);
  bird.group.traverse((m) => { if (m.isMesh && m.userData.inkGroup === 50) m.userData.inkGroup = 50; });

  // ---------------------------------------------------------------- The relay: a chrome cloud.
  const cloud = new THREE.Group();
  const cc = { x: 610, y: 245 };
  cloud.position.set(wx(cc.x), wy(cc.y), -2);
  scene.add(cloud);
  const cloudGeo = inflate({
    box: [-170, -110, 340, 210], res: 0.7, scale: S, radius: 60, depth: 1.0, dome: 0.15, soften: 2, smooth: 3, color: '#ffffff',
    base: (g) => {
      for (const [x, y, r] of [[-82, 20, 58], [-18, -28, 74], [58, -10, 62], [108, 30, 46]]) { g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fill(); }
      g.beginPath(); g.roundRect(-140, 10, 280, 70, 35); g.fill();
    },
  });
  const cloudMesh = add(cloud, cloudGeo, chrome(dark ? '#FFC79A' : '#FFD2AA', 0.1));
  cloudMesh.material.vertexColors = false;
  const lockZ = frontZ(cloudGeo, 0, wy(25), 3) + 0.4;
  const lockBody = slab(-30, 0, 60, 48, 14, lit.orange, 1.6);
  const lock = new THREE.Group();
  lock.position.set(0, 0, lockZ);
  add(lock, lockBody.geo, lockBody.mat);
  const shackle = capped(Array.from({ length: 13 }, (_, i) => { const a = Math.PI * (i / 12); return [wx(-18 * Math.cos(a)), wy(-20 * Math.sin(a)) - 0.0, 0.2]; }).map(([x, y, z], i, arr) => [x, y, z]), 0.38, chrome(C.amber, 0.08), { segments: 40, radial: 16 });
  shackle.position.y = 0;
  lock.add(ink(shackle, 60));
  const keyhole = new THREE.Mesh(new THREE.SphereGeometry(0.55, 20, 14), new THREE.MeshPhysicalMaterial({ color: '#1a0f0a', roughness: 0.2, clearcoat: 1 }));
  keyhole.position.set(0, wy(22), frontZ(lockBody.geo, 0, wy(24), 1) + 0.1);
  keyhole.scale.z = 0.4;
  lock.add(ink(keyhole, 61));
  cloud.add(lock);
  cloud.rotation.y = -0.12;

  // ---------------------------------------------------------------- Firebase's bell.
  const bell = new THREE.Group();
  const bc = { x: 330, y: 112 };
  bell.position.set(wx(bc.x), wy(bc.y), 2);
  scene.add(bell);
  const prof = [[0, 3.2], [0.9, 3.1], [1.6, 2.6], [1.9, 1.4], [2.2, -0.4], [2.9, -1.4], [3.1, -1.9], [0, -1.9]].map(([x, y]) => new THREE.Vector2(x, y));
  const bellBody = add(bell, new THREE.LatheGeometry(prof, 48), puffy(C.amber));
  bellBody.material.side = THREE.DoubleSide;
  const clapper = add(bell, new THREE.SphereGeometry(0.75, 20, 14), chrome(lit.orange, 0.1));
  clapper.position.y = -2.3;
  const knob = add(bell, new THREE.SphereGeometry(0.6, 20, 14), chrome(C.amber, 0.1));
  knob.position.y = 3.5;
  bell.rotation.x = 0.25;

  // ---------------------------------------------------------------- The computer.
  const mon = new THREE.Group();
  const mc = { x: 1025, y: 345 };
  mon.position.set(wx(mc.x), wy(mc.y), 0);
  scene.add(mon);
  const monGeo = inflate({
    box: [-220, -195, 440, 390], res: 0.6, scale: S, radius: 34, depth: 1.1, dome: 0.03, soften: 0.5, smooth: 2, color: dark ? '#E9D3BE' : '#F6E2CF',
    base: (g) => { g.beginPath(); g.roundRect(-200, -175, 400, 345, 34); g.fill(); },
    patches: [{ color: '#2B231D', puff: -0.35, radius: 10, soften: 0.3, draw: (g) => { g.beginPath(); g.roundRect(-180, -155, 360, 290, 18); g.fill(); } }],
  });
  add(mon, monGeo, soft('#F6E2CF', { vertexColors: true, roughness: 0.55 }));
  const mz = frontZ(monGeo, 0, 0, 3);
  // Neck and foot.
  const neck = add(mon, new THREE.CylinderGeometry(2.2, 2.8, 6.5, 32), soft(dark ? '#E9D3BE' : '#F6E2CF'));
  neck.position.set(0, wy(205), -1.4);
  const foot = add(mon, new THREE.CylinderGeometry(9, 10, 1.6, 48), soft(dark ? '#E9D3BE' : '#F6E2CF'));
  foot.position.set(0, wy(240), -1.4);
  // On the screen: the Perch host badge, a plugin chip, two Claude Code windows.
  const badge = slab(-160, -135, 200, 70, 18, lit.orange, 1.0);
  add(mon, badge.geo, badge.mat).position.z = mz - 0.1;
  const chip = slab(70, -128, 92, 56, 16, C.amber, 0.9);
  add(mon, chip.geo, chrome(C.amber, 0.12)).position.z = mz - 0.1;
  const winA = slab(-140, -10, 290, 120, 14, '#FBEBDC', 0.6);
  add(mon, winA.geo, soft('#FBEBDC', { vertexColors: true })).position.z = mz - 0.25;
  const winB = slab(-160, 10, 290, 118, 14, '#FFF6EC', 0.6);
  add(mon, winB.geo, soft('#FFF6EC', { vertexColors: true })).position.z = mz + 0.25;
  const wz = mz + 0.25 + frontZ(winB.geo, wx(-15), wy(-70), 3);
  for (const [i, x] of [-140, -126, -112].entries()) {
    const d = add(mon, new THREE.SphereGeometry(0.42, 16, 12), chrome(lit.orange, 0.1));
    d.position.set(wx(x), wy(26), wz - 0.1);
  }
  mon.rotation.y = -0.26;
  mon.rotation.x = -0.04;

  // Shadows.
  for (const [x, y, w, d, o] of [[pc.x, 625, 26, 6, 1.4], [mc.x, 588, 36, 7, 1.4], [cc.x, 345, 30, 6, 0.6]]) {
    const sh = blobShadow(w, d, theme.shadow * o, theme.shadowRgb);
    sh.position.set(wx(x), wy(y), -8);
    sh.rotation.x = 0;
    scene.add(sh);
  }

  // ---------------------------------------------------------------- Packets on the routes.
  const bez = (p0, p1, p2) => (t) => [(1 - t) * (1 - t) * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0], (1 - t) * (1 - t) * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]];
  const routes = {
    phoneRelay: bez([300, 345], [360, 225], [452, 252]),
    relayHost: bez([772, 250], [820, 240], [848, 300]),
    direct: bez([302, 578], [560, 600], [818, 578]),
    relayBell: bez([600, 152], [520, 112], [374, 116]),
    bellPhone: bez([298, 140], [266, 160], [242, 196]),
  };
  const packetMat = chrome('#FFD08A', 0.06);
  const packet = () => {
    const g = new THREE.Group();
    const m = new THREE.Mesh(new THREE.CapsuleGeometry(0.7, 1.0, 8, 16), packetMat);
    m.rotation.z = Math.PI / 2;
    m.userData.inkGroup = nextId++;
    g.add(m);
    scene.add(g);
    return g;
  };
  // Each packet: a list of [route, start, end, reverse] legs over the loop.
  const plan = [
    { legs: [['phoneRelay', 0.0, 0.18, false], ['relayHost', 0.2, 0.34, false]] },
    { legs: [['relayHost', 0.5, 0.64, true], ['phoneRelay', 0.66, 0.84, true]] },
    { legs: [['direct', 0.1, 0.42, false]] },
    { legs: [['direct', 0.58, 0.9, true]] },
    { legs: [['relayBell', 0.36, 0.52, false], ['bellPhone', 0.56, 0.66, false]] },
  ].map((p) => ({ ...p, mesh: packet() }));

  // ---------------------------------------------------------------- The hand-drawn layer.
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('width', W);
  svg.setAttribute('height', H);
  svg.style.cssText = 'left:0;top:0;pointer-events:none';
  const rc = rough.svg(svg, { options: { seed: 5 } });
  const line = theme.line;
  const arrowHead = (x1, y1, x2, y2, o) => {
    const a = Math.atan2(y2 - y1, x2 - x1), len = 15;
    const p = (da) => [x2 - len * Math.cos(a + da), y2 - len * Math.sin(a + da)];
    svg.appendChild(rc.linearPath([p(0.45), [x2, y2], p(-0.45)], o));
  };
  const route = (r, o, { both = true } = {}) => {
    const pts = Array.from({ length: 12 }, (_, i) => r(i / 11));
    svg.appendChild(rc.curve(pts, o));
    const [a, b] = [r(0.92), r(1)];
    arrowHead(a[0], a[1], b[0], b[1], o);
    if (both) { const [c, d] = [r(0.08), r(0)]; arrowHead(c[0], c[1], d[0], d[1], o); }
  };
  const solid = { stroke: line, strokeWidth: 2.4, roughness: 1.1 };
  route(routes.phoneRelay, solid);
  route(routes.relayHost, solid);
  route(routes.direct, { stroke: theme.amber, strokeWidth: 3.2, roughness: 1, strokeLineDash: [10, 9] });
  route(routes.relayBell, { stroke: theme.accent, strokeWidth: 2.4, roughness: 1, strokeLineDash: [8, 8] }, { both: false });
  route(routes.bellPhone, { stroke: theme.accent, strokeWidth: 2.4, roughness: 1, strokeLineDash: [8, 8] }, { both: false });
  // Inside the computer: the host reads sessions and types answers.
  const screenLine = dark ? '#EADBCB' : '#FCE6D1';
  route((t) => [985 - 8 * t, 282 + 50 * t], { stroke: screenLine, strokeWidth: 2.2, roughness: 0.8 });
  card.appendChild(svg);

  // Words: positioned in CSS pixels; for words on a turned object, projected.
  const proj = (obj, x, y, z) => {
    obj.updateMatrixWorld(true);
    const v = new THREE.Vector3(x, y, z).applyMatrix4(obj.matrixWorld).project(camera);
    return [(v.x + 1) / 2 * W, (1 - v.y) / 2 * H];
  };
  const label = (html, x, y, style, anchor = 'left') => {
    const d = document.createElement('div');
    d.innerHTML = html;
    const tx = anchor === 'center' ? '-50%' : anchor === 'right' ? '-100%' : '0';
    d.style.cssText = `left:${x}px;top:${y}px;transform:translate(${tx},-50%);white-space:nowrap;${style}`;
    card.appendChild(d);
    return d;
  };
  const hand = (size, color, w = 700) => `font:${w} ${size}px/1.1 Caveat;color:${color};`;
  label('Perch app', 185, 672, hand(40, theme.text), 'center');
  label('on your Android phone', 185, 706, hand(25, theme.quiet, 500), 'center');
  // On the phone's card.
  {
    const [x, y] = proj(phone, wx(-58), wy(-18), cz + 0.6);
    label('Allow Bash?', x, y, hand(25, C.ink), 'left');
    const [dx, dy] = proj(phone, wx(-32), wy(57), cz + 1.2);
    label('Deny', dx, dy, hand(19, C.ink), 'center');
    const [ax, ay] = proj(phone, wx(34), wy(57), cz + 1.2);
    label('Allow', ax, ay, hand(19, '#FFF6EC'), 'center');
  }
  label('relay', 610, 372, hand(38, theme.text), 'center');
  label('sealed messages only: it cannot read them', 610, 404, hand(24, theme.text, 500), 'center');
  label('away from home · a Cloudflare Worker', 610, 434, hand(22, theme.quiet, 500), 'center');
  label('Firebase push', 372, 50, hand(28, theme.text), 'left');
  label('Google’s push service', 372, 78, hand(21, theme.quiet, 500), 'left');
  label('push, sealed per device:', 640, 48, hand(26, theme.accent), 'left');
  label('Google carries text it cannot read', 640, 76, hand(23, theme.text, 500), 'left');
  label('your computer', 1025, 140, hand(34, theme.text), 'center');
  {
    const [x, y] = proj(mon, wx(-60), wy(-100), mz + 1.2);
    label('Perch host', x, y, hand(30, '#FFF6EC'), 'center');
    const [px2, py2] = proj(mon, wx(116), wy(-100), mz + 1.2);
    label('plugin', px2, py2, hand(21, C.ink), 'center');
    const [sx, sy] = proj(mon, wx(-140), wy(52), wz + 0.4);
    label('&gt; claude', sx, sy, hand(25, '#D8431F'), 'left');
    const [tx, ty] = proj(mon, wx(-140), wy(86), wz + 0.4);
    label('Claude Code sessions', tx, ty, hand(20, '#7A685C', 500), 'left');
  }
  label('Windows or macOS', 1025, 640, hand(24, theme.quiet, 500), 'center');
  label('the host reads sessions and transcripts and types your answers;', 1240, 676, hand(21, theme.text, 500), 'right');
  label('the plugin’s hooks send it instant updates', 1240, 704, hand(21, theme.text, 500), 'right');
  label('at home, on the same Wi-Fi: direct', 560, 548, hand(28, theme.amber), 'center');
  label('end-to-end encrypted, keys made at pairing', 560, 622, hand(23, theme.text, 500), 'center');
  label('pairing: scan the QR code from /perch,', 545, 664, hand(22, theme.quiet, 500), 'center');
  label('then Allow the phone at the computer', 545, 692, hand(22, theme.quiet, 500), 'center');

  stage.assignIds();

  const tau = Math.PI * 2;
  function frame(i) {
    const t = i / frames;
    for (const p of plan) {
      p.mesh.visible = false;
      for (const [name, a, b, rev] of p.legs) {
        if (t < a || t > b) continue;
        let u = (t - a) / (b - a);
        u = u * u * (3 - 2 * u);
        if (rev) u = 1 - u;
        const [x, y] = routes[name](u);
        const [x2, y2] = routes[name](Math.min(1, u + 0.01));
        p.mesh.visible = true;
        p.mesh.position.set(wx(x), wy(y), 12);
        p.mesh.rotation.z = Math.atan2(-(y2 - y), x2 - x);
        const pop = Math.min(1, Math.min(u, 1 - u) * 8 + 0.3);
        p.mesh.scale.setScalar(pop);
      }
    }
    // The bell rings when a push passes through it.
    const ring = Math.exp(-Math.pow((t - 0.54) / 0.03, 2));
    bell.rotation.z = 0.35 * ring * Math.sin(t * tau * 18);
    // The relay cloud floats; the bird blinks and bobs.
    cloud.position.y = wy(cc.y) + 0.25 * Math.sin(tau * t);
    cloud.rotation.y = -0.12 + 0.06 * Math.sin(tau * t + 1);
    const blink = Math.exp(-Math.pow((t - 0.8) / 0.012, 2));
    bird.eyeGroup.scale.y = 1 - 0.9 * blink;
    birdHolder.rotation.z = 0.04 * Math.sin(tau * 2 * t);
    // "Allow" presses itself when the answer leaves the phone.
    const press = Math.exp(-Math.pow((t - 0.0) / 0.03, 2)) + Math.exp(-Math.pow((t - 1.0) / 0.03, 2));
    allowMesh.scale.z = 1 - 0.6 * press;
    stage.render(camera, Math.floor(i / 3) * 1.37);
  }
  return { frames, frame };
}
