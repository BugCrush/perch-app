// The banner: Perch's bird, inflated, perched on a puffy terminal with chrome details,
// beside the name and tagline. A seamless loop: the bird breathes, sways, blinks and
// hops; the camera drifts so the chrome catches the light; the ink line boils.
import { THREE, Stage, themes, inflate, puffy, chrome, soft, capped, blobShadow, fontsReady, C, lit } from '../core.js';
import { makeBird } from '../logo.js';
import rough from 'roughjs';

const W = 1280, H = 500;
const GL = { x: 0, y: 0, w: 600, h: 500 };

export async function build(card, q) {
  const theme = themes[q.get('theme') ?? 'light'];
  const frames = Number(q.get('frames') ?? 80);
  const ratio = Number(q.get('ratio') ?? 1);
  card.style.width = W + 'px';
  card.style.height = H + 'px';
  card.style.background = theme.bg;
  card.style.borderRadius = '22px';
  await fontsReady();

  // ---- The words, drawn as HTML and rough.js over the card.
  const text = document.createElement('div');
  text.style.cssText = `left:600px;top:0;width:640px;height:${H}px;`;
  text.innerHTML = `
    <div style="position:absolute;left:0;top:70px;font:500 172px/1 Newsreader;color:${C.orange};letter-spacing:-1px">Perch</div>
    <div style="position:absolute;left:4px;top:290px;font:500 33px/1.32 Manrope;color:${theme.text}">Watch and steer your Claude Code<br>sessions from your phone.</div>
    <div style="position:absolute;left:4px;top:410px;font:500 25px/1 Caveat;color:${theme.quiet};white-space:nowrap">Android · Windows · macOS · a Claude Code plugin</div>`;
  card.appendChild(text);
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('width', W);
  svg.setAttribute('height', H);
  svg.style.cssText = 'left:0;top:0;pointer-events:none';
  const rc = rough.svg(svg, { options: { seed: 11 } });
  // The underline, and a faint glint that slides along it.
  const underPts = [[606, 214], [730, 206], [880, 210], [1000, 200]];
  const under = rc.curve(underPts, { stroke: theme.amber, strokeWidth: 4.5, roughness: 1.6 });
  svg.appendChild(under);
  const glint = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  glint.setAttribute('d', 'M606 214 C 680 206, 760 206, 840 209 S 960 204, 1000 200');
  glint.setAttribute('fill', 'none');
  glint.setAttribute('stroke', theme.name === 'dark' ? '#FFE0A6' : '#FFF3D6');
  glint.setAttribute('stroke-width', '2.2');
  glint.setAttribute('stroke-linecap', 'round');
  glint.setAttribute('stroke-dasharray', '46 2000');
  svg.appendChild(glint);
  // A margin note pointing at the bird.
  const note = document.createElementNS('http://www.w3.org/2000/svg', 'text');
  note.setAttribute('x', 36); note.setAttribute('y', 92);
  note.setAttribute('style', `font:700 26px Caveat;fill:${theme.accent}`);
  note.setAttribute('transform', 'rotate(-7 36 92)');
  note.textContent = 'keeps watch';
  svg.appendChild(note);
  const note2 = note.cloneNode();
  note2.setAttribute('y', 120); note2.setAttribute('transform', 'rotate(-7 36 120)');
  note2.textContent = 'while you’re away';
  svg.appendChild(note2);
  svg.appendChild(rc.curve([[92, 136], [104, 176], [140, 206], [186, 214]], { stroke: theme.accent, strokeWidth: 2.2, roughness: 1.2 }));
  svg.appendChild(rc.linearPath([[170, 202], [188, 214], [172, 226]], { stroke: theme.accent, strokeWidth: 2.2, roughness: 1 }));

  // ---- The 3D.
  const canvas = document.createElement('canvas');
  canvas.style.left = GL.x + 'px';
  canvas.style.top = GL.y + 'px';
  card.appendChild(canvas);
  card.appendChild(svg);
  const stage = new Stage(canvas, theme, { width: GL.w, height: GL.h, pixelRatio: ratio, inkWidth: 2.1, jitter: 2.6 });
  stage.lights({ key: 3.0, fill: 0.55, rim: 2.0 });
  const scene = stage.scene;
  const s = 0.01;

  // The terminal: one puffy orange slab with a pressed-in cream screen.
  const term = inflate({
    box: [120, 560, 820, 400],
    res: 0.36,
    scale: s,
    radius: 90,
    depth: 1.5,
    dome: 0.1,
    soften: 2,
    smooth: 3,
    color: lit.orange,
    base: (g) => { g.beginPath(); g.roundRect(150, 598, 760, 330, 70); g.fill(); },
    patches: [{ color: lit.cream, puff: -0.55, radius: 26, soften: 1, draw: (g) => { g.beginPath(); g.roundRect(200, 688, 660, 200, 34); g.fill(); } }],
  });
  const termMesh = new THREE.Mesh(term, puffy(lit.orange, { vertexColors: true }));
  termMesh.userData.inkGroup = 2;
  scene.add(termMesh);
  // The three title-bar dots: chrome beads.
  const dotMat = chrome('#FFD8A8', 0.08);
  for (const [i, x] of [735, 790, 845].entries()) {
    const d = new THREE.Mesh(new THREE.SphereGeometry(0.19, 32, 24), dotMat);
    d.position.set(x * s, -642 * s, 1.12);
    d.scale.z = 0.7;
    d.userData.inkGroup = 20 + i;
    scene.add(d);
  }
  // The prompt: a chrome "›" and a blinking cursor, standing on the screen.
  const promptMat = chrome(C.orange, 0.12);
  const zS = 1.24;
  const chevron = capped([[300 * s, -730 * s, zS], [370 * s, -785 * s, zS + 0.05], [300 * s, -840 * s, zS]], 0.11, promptMat, { segments: 40, radial: 20 });
  chevron.traverse((o) => { if (o.isMesh) o.userData.inkGroup = 30; });
  scene.add(chevron);
  const cursor = capped([[410 * s, -840 * s, zS], [520 * s, -840 * s, zS]], 0.11, promptMat, { segments: 8, radial: 20 });
  cursor.traverse((o) => { if (o.isMesh) o.userData.inkGroup = 31; });
  scene.add(cursor);

  // The twig and its leaf, in front at the lower left, like the logo.
  const twigMat = chrome(C.amber, 0.16);
  const twig = capped([[380 * s, -540 * s, 0.1], [290 * s, -640 * s, 0.6], [180 * s, -760 * s, 1.1], [80 * s, -870 * s, 1.3]], 0.15, puffy(lit.orange), { segments: 64, radial: 20 });
  twig.traverse((o) => { if (o.isMesh) o.userData.inkGroup = 40; });
  scene.add(twig);
  const leaf = inflate({
    box: [40, 470, 240, 170],
    res: 0.5,
    scale: s,
    radius: 40,
    depth: 1.5,
    soften: 1,
    color: lit.ember,
    base: (g) => {
      g.beginPath();
      g.moveTo(255, 612);
      g.bezierCurveTo(200, 520, 120, 500, 62, 528);
      g.bezierCurveTo(95, 600, 170, 640, 255, 612);
      g.fill();
    },
  });
  const leafMesh = new THREE.Mesh(leaf, puffy(lit.ember, { vertexColors: true }));
  leafMesh.position.z = 1.05;
  leafMesh.userData.inkGroup = 41;
  scene.add(leafMesh);
  const vein = capped([[245 * s, -608 * s, 1.42], [160 * s, -575 * s, 1.5], [85 * s, -535 * s, 1.36]], 0.035, twigMat, { segments: 24, radial: 10 });
  vein.traverse((o) => { if (o.isMesh) o.userData.inkGroup = 42; });
  scene.add(vein);

  // The bird, pivoting at its feet.
  const bird = await makeBird(s, { theme, wings: true });
  const pivot = new THREE.Group();
  const feet = new THREE.Vector3(555 * s, -612 * s, 0);
  pivot.position.copy(feet);
  bird.group.position.set(-feet.x, -feet.y, 0);
  pivot.add(bird.group);
  scene.add(pivot);

  // Shadows: under the terminal, and the bird's on the terminal top.
  const shadow = blobShadow(10.5, 4.2, theme.shadow * 1.6, theme.shadowRgb);
  shadow.position.set(530 * s, -935 * s, 0.1);
  scene.add(shadow);

  stage.assignIds();

  const camera = new THREE.PerspectiveCamera(27, GL.w / GL.h, 0.5, 100);
  const target = new THREE.Vector3(5.15, -4.75, 0.2);

  const tau = Math.PI * 2;
  const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };

  function frame(i) {
    const t = i / frames;
    // Camera: a slow figure-eight so reflections slide over the chrome.
    const yaw = 0.16 * Math.sin(tau * t) + 0.28;
    const pitch = 0.2 + 0.03 * Math.sin(tau * 2 * t);
    const dist = 26;
    camera.position.set(target.x + dist * Math.sin(yaw) * Math.cos(pitch), target.y + dist * Math.sin(pitch), target.z + dist * Math.cos(yaw) * Math.cos(pitch));
    camera.lookAt(target);

    // The bird: perched (breathing, a sway), then a short flight: crouch, lift off with
    // wing beats, a glide with wings held up, a few beats down, and a soft landing.
    const base = 0.84;
    const breathe = 0.012 * Math.sin(tau * 4 * t);
    const crouch = Math.exp(-Math.pow((t - 0.3) / 0.018, 2));
    const land = Math.exp(-Math.pow((t - 0.8) / 0.02, 2));
    const air = smooth(0.31, 0.42, t) * (1 - smooth(0.68, 0.79, t));
    const drift = Math.sin(Math.PI * Math.min(1, Math.max(0, (t - 0.31) / 0.48)));
    pivot.position.set(feet.x + 0.35 * drift, feet.y + 1.25 * air + 0.12 * Math.sin(tau * 6 * t) * air, 0);
    pivot.rotation.z = 0.03 * Math.sin(tau * t) * (1 - air) + 0.1 * air * Math.sin(tau * 2 * (t - 0.31) / 0.96);
    pivot.rotation.y = 0.1 * Math.sin(tau * t + 1);
    const sq = 0.08 * (land + crouch);
    pivot.scale.set(base * (1 + sq * 0.6 - breathe * 0.4), base * (1 - sq + breathe), base * (1 + sq * 0.6));
    // Wings: beats while climbing and coming down, held up (gliding) in between.
    const flying = smooth(0.29, 0.33, t) * (1 - smooth(0.78, 0.82, t));
    const glide = smooth(0.46, 0.5, t) * (1 - smooth(0.6, 0.64, t));
    const beat = 0.5 - 0.5 * Math.cos(tau * 10 * t);
    const open = flying * ((1 - glide) * (0.25 + 1.35 * beat) + glide * 1.05);
    bird.spread(open, open * 1.08);
    glint.setAttribute('stroke-dashoffset', String(-((t * 1.4) % 1.4) * 520 + 60));
    glint.setAttribute('opacity', String(0.75 * Math.sin(Math.PI * Math.min(1, (t * 1.4) % 1.4))));
    // A blink at about a quarter through.
    const blink = Math.exp(-Math.pow((t - 0.14) / 0.01, 2)) + Math.exp(-Math.pow((t - 0.92) / 0.01, 2));
    bird.eyeGroup.scale.y = 1 - 0.9 * blink;
    // The cursor blinks twice per loop.
    cursor.visible = (t * 4) % 2 < 1.2;
    stage.render(camera, Math.floor(i / 3) * 1.37);
  }
  return { frames, frame };
}
