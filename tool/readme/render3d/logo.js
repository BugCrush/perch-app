// The logo (assets/branding/perch-logo.svg) as Path2D objects, and the 3D bird made
// from it: the bird's silhouette inflated, its cream wing and breast raised on it,
// a glossy eye and chrome legs.
import { THREE, inflate, puffy, chrome, capped, C, lit } from './core.js';

export async function logoPaths() {
  const svg = await (await fetch('../../../assets/branding/perch-logo.svg')).text();
  const ds = [...svg.matchAll(/<path d="([^"]+)"/g)].map((m) => m[1]);
  // The cream path's parts: the eye, the breast and the wing (the one reaching furthest left).
  const parts = ds[1].split(/(?=M)/).filter((x) => x.trim());
  const minX = (d) => Math.min(...d.match(/-?\d*\.?\d+/g).map(Number).filter((_, i) => i % 2 === 0));
  const wingD = parts.reduce((a, b) => (minX(b) < minX(a) ? b : a));
  return { orange: new Path2D(ds[0]), cream: new Path2D(ds[1]), wing: new Path2D(wingD), notWing: new Path2D(parts.filter((x) => x !== wingD).join('')) };
}

/// The bird alone (tools/readme/lib.mjs `birdClip`, without the legs).
const birdOnly = [[0, -60], [1100, -60], [1100, 548], [232, 548], [232, 495], [0, 495]];

function clipTo(g, poly) {
  g.beginPath();
  poly.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y)));
  g.closePath();
  g.clip();
}

/// The eye in logo units.
export const eye = { x: 740, y: 139, r: 29 };

/// A group whose origin is the logo's (0, 0); one logo unit = [s] scene units, y up.
/// Returns { group, body, eyeGroup } so a scene can animate them.
export async function makeBird(s = 0.01, { theme, wings = false }) {
  const p = await logoPaths();
  const body = inflate({
    box: [200, 10, 700, 560],
    res: 0.42,
    scale: s,
    radius: 85,
    depth: 1.2,
    dome: 0.18,
    soften: 8,
    smooth: 3,
    color: lit.orange,
    base: (g) => {
      clipTo(g, birdOnly);
      g.fill(p.orange, 'evenodd');
      g.fill(p.cream);
      // Close the gap the eye leaves in the head.
      g.beginPath(); g.arc(eye.x, eye.y, eye.r + 6, 0, Math.PI * 2); g.fill();
    },
    patches: [{
      color: lit.cream,
      puff: 0.55,
      radius: 22,
      soften: 3,
      draw: (g) => {
        clipTo(g, birdOnly);
        g.fill(wings ? p.notWing : p.cream);
        // Not the eye: it is a bead of its own.
        g.globalCompositeOperation = 'destination-out';
        g.beginPath(); g.arc(eye.x, eye.y, eye.r + 12, 0, Math.PI * 2); g.fill();
        g.globalCompositeOperation = 'source-over';
      },
    }],
  });
  const group = new THREE.Group();
  const mesh = new THREE.Mesh(body, puffy(lit.orange, { vertexColors: true }));
  mesh.userData.inkGroup = 1;
  group.add(mesh);

  // The eye: a cream bead with a dark glossy pupil and a chrome rim.
  const eyeGroup = new THREE.Group();
  const ex = eye.x * s, ey = -eye.y * s;
  // Sit the eye on the body's front surface.
  let zFront = 0;
  const pa = body.getAttribute('position');
  for (let i = 0; i < pa.count; i++) {
    if (Math.hypot(pa.getX(i) - eye.x * s, pa.getY(i) + eye.y * s) < eye.r * s * 1.4) zFront = Math.max(zFront, pa.getZ(i));
  }
  zFront -= eye.r * s * 0.25;
  eyeGroup.position.set(ex, ey, zFront);
  const white = new THREE.Mesh(new THREE.SphereGeometry(eye.r * s * 1.05, 32, 24), puffy(lit.cream));
  white.scale.z = 0.55;
  eyeGroup.add(white);
  const pupil = new THREE.Mesh(new THREE.SphereGeometry(eye.r * s * 0.55, 32, 24), new THREE.MeshPhysicalMaterial({ color: '#1a0f0a', roughness: 0.15, clearcoat: 1, clearcoatRoughness: 0.03 }));
  pupil.position.set(eye.r * s * 0.22, -eye.r * s * 0.05, eye.r * s * 0.3);
  pupil.scale.z = 0.6;
  eyeGroup.add(pupil);
  group.add(eyeGroup);

  // Legs: two short chrome stalks with little toes, from the belly to the perch.
  const legMat = chrome(C.amber, 0.14);
  for (const [x, lean] of [[520, -14], [590, 12]]) {
    const top = [x * s, -520 * s, 0.05];
    const foot = [(x + lean) * s, -622 * s, 0.05];
    const leg = capped([top, [(x + lean * 0.5) * s, -575 * s, 0.06], foot], 0.075, legMat, { segments: 16, radial: 16 });
    leg.traverse((o) => { if (o.isMesh) o.userData.inkGroup = 9; });
    group.add(leg);
    for (const dx of [-26, 0, 26]) {
      const toe = capped([foot, [foot[0] + dx * s * 0.9, foot[1] - 0.04, foot[2] + 0.22]], 0.05, legMat, { segments: 6, radial: 12 });
      toe.traverse((o) => { if (o.isMesh) o.userData.inkGroup = 9; });
      group.add(toe);
    }
  }
  // Wings that can open: the logo's wing as its own puffy piece (cream, orange rim), hinged
  // along its top edge at the shoulder; a mirrored one behind the body.
  let wingPivots = [];
  let wingAxis = null;
  if (wings) {
    const wgeo = inflate({
      box: [290, 255, 370, 290], res: 0.5, scale: s, radius: 30, depth: 0.7, dome: 0.1, soften: 3, smooth: 2, color: lit.orange,
      base: (g) => { g.lineWidth = 18; g.lineJoin = 'round'; g.fill(p.wing); g.stroke(p.wing); },
      patches: [{ color: lit.cream, puff: 0.45, radius: 14, soften: 2, draw: (g) => g.fill(p.wing) }],
    });
    const shoulder = [628, 284];
    wingAxis = new THREE.Vector3(-1, -0.6, 0).normalize();
    let zb = 0, zk = 0;
    const pa = body.getAttribute('position');
    for (let i = 0; i < pa.count; i++) {
      if (Math.hypot(pa.getX(i) - 480 * s, pa.getY(i) + 400 * s) < 40 * s) { zb = Math.max(zb, pa.getZ(i)); zk = Math.min(zk, pa.getZ(i)); }
    }
    for (const side of [1, -1]) {
      const pivot = new THREE.Group();
      pivot.position.set(shoulder[0] * s, -shoulder[1] * s, side > 0 ? zb - 0.05 : zk + 0.05);
      const w = new THREE.Mesh(wgeo, puffy(lit.orange, { vertexColors: true }));
      w.position.set(-shoulder[0] * s, shoulder[1] * s, 0);
      if (side < 0) { w.scale.z = -1; w.material.side = THREE.DoubleSide; }
      w.userData.inkGroup = side > 0 ? 7 : 8;
      pivot.add(w);
      pivot.userData.side = side;
      group.add(pivot);
      wingPivots.push(pivot);
    }
  }
  /// Opens the wings by [a] radians (0 = folded on the body).
  // A wing swings up in the body's plane (as a drawn bird's would) and turns out of it a little.
  const zAxis = new THREE.Vector3(0, 0, 1);
  const qz = new THREE.Quaternion(), qo = new THREE.Quaternion();
  const spread = (a, back = a) => {
    for (const pv of wingPivots) {
      const k = pv.userData.side > 0 ? a : back;
      qz.setFromAxisAngle(zAxis, -k);
      qo.setFromAxisAngle(wingAxis, pv.userData.side * 0.35 * Math.min(k, 1.2));
      pv.quaternion.copy(qz).multiply(qo);
    }
  };
  return { group, mesh, eyeGroup, pupil, spread, wingPivots };
}
