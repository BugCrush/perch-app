// The 3D look shared by every README picture: drawings "inflated" into puffy forms,
// warm liquid chrome, soft cream neumorphic surfaces, and a hand-drawn ink line around
// everything (an edge pass whose line wobbles and "boils" like a pencil animation).
// Runs in the browser (headless Chrome, see render.mjs); three.js does the rendering.
import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';

export { THREE, RoundedBoxGeometry };

/// The app's palette (tool/readme/lib.mjs).
export const C = {
  orange: '#F7532B',
  cream: '#FCE6D1',
  ink: '#161310',
  ember: '#FF7A52',
  amber: '#E9A23B',
  green: '#3BE36B',
};

/// Base colours for lit surfaces: lighting adds white, which pulls the brand orange
/// towards pink; a yellower base lands on it.
export const lit = { orange: '#F7532B', cream: '#FCE6D1', ember: '#FF7A52' };

export const themes = {
  light: { name: 'light', bg: '#FFF8F0', line: '#2B231D', text: C.ink, quiet: '#7A685C', accent: '#D8431F', amber: '#C98316', panel: '#FBEBDC', ink: '#2B231D', shadow: 0.16, shadowRgb: '40,20,10' },
  dark: { name: 'dark', bg: C.ink, line: '#EADBCB', text: C.cream, quiet: '#A8968A', accent: C.ember, amber: C.amber, panel: '#211C18', ink: '#120F0D', shadow: 0.7, shadowRgb: '0,0,0' },
};

// ---------------------------------------------------------------------------------------
// Inflating a flat drawing.

/// Squared Euclidean distance transform (Felzenszwalb & Huttenlocher), in place on a
/// grid where 0 = a seed and 1e20 = anything else.
function edt2(f, W, H) {
  const n = Math.max(W, H);
  const d = new Float64Array(n), v = new Int32Array(n), z = new Float64Array(n + 1), g = new Float64Array(n);
  const dt = (len) => {
    let k = 0;
    v[0] = 0; z[0] = -1e30; z[1] = 1e30;
    for (let q = 1; q < len; q++) {
      let s = ((g[q] + q * q) - (g[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]);
      while (s <= z[k]) { k--; s = ((g[q] + q * q) - (g[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]); }
      k++; v[k] = q; z[k] = s; z[k + 1] = 1e30;
    }
    k = 0;
    for (let q = 0; q < len; q++) { while (z[k + 1] < q) k++; d[q] = (q - v[k]) * (q - v[k]) + g[v[k]]; }
  };
  for (let x = 0; x < W; x++) { for (let y = 0; y < H; y++) g[y] = f[y * W + x]; dt(H); for (let y = 0; y < H; y++) f[y * W + x] = d[y]; }
  for (let y = 0; y < H; y++) { for (let x = 0; x < W; x++) g[x] = f[y * W + x]; dt(W); for (let x = 0; x < W; x++) f[y * W + x] = d[x]; }
}

/// Signed distance (in cells) from an alpha mask: > 0 inside.
function signedDistance(alpha, W, H) {
  const inn = new Float64Array(W * H), out = new Float64Array(W * H);
  for (let i = 0; i < W * H; i++) {
    const on = alpha[i] >= 0.5;
    inn[i] = on ? 1e20 : 0;
    out[i] = on ? 0 : 1e20;
  }
  edt2(inn, W, H);
  edt2(out, W, H);
  const s = new Float32Array(W * H);
  for (let i = 0; i < W * H; i++) s[i] = alpha[i] >= 0.5 ? Math.sqrt(inn[i]) - 0.5 : -(Math.sqrt(out[i]) - 0.5);
  return s;
}

function blur(a, W, H, passes = 1) {
  let src = a, dst = new Float32Array(W * H);
  for (let p = 0; p < passes; p++) {
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      let sum = 0, n = 0;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const xx = x + dx, yy = y + dy;
        if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue;
        sum += src[yy * W + xx]; n++;
      }
      dst[y * W + x] = sum / n;
    }
    [src, dst] = [dst, src];
  }
  return src;
}

/// Rasterises [draw] (a function of a 2D context, in drawing units) over the box
/// [x0, y0, w, h] at [res] cells per unit, softened by [soften] units of blur.
function rasterise(draw, x0, y0, w, h, res, soften) {
  const W = Math.ceil(w * res) + 2, H = Math.ceil(h * res) + 2;
  const c = new OffscreenCanvas(W, H);
  const g = c.getContext('2d', { willReadFrequently: true });
  if (soften > 0) g.filter = `blur(${(soften * res).toFixed(2)}px)`;
  g.setTransform(res, 0, 0, res, (-x0 + 1 / res) * res, (-y0 + 1 / res) * res);
  g.fillStyle = '#fff';
  g.strokeStyle = '#fff';
  draw(g);
  const data = g.getImageData(0, 0, W, H).data;
  const a = new Float32Array(W * H);
  for (let i = 0; i < W * H; i++) a[i] = data[i * 4 + 3] / 255;
  return { a, W, H };
}

/// A puffy, balloon-like mesh made from a flat drawing.
///   base:     draw(ctx) for the silhouette (filled white)
///   patches:  [{ draw, color, puff, radius }] raised areas of another colour on the front
///   box:      [x0, y0, w, h] in drawing units; drawing y grows downwards, the mesh's up
///   scale:    scene units per drawing unit
///   radius:   how far in (drawing units) the edge rounds over
///   depth:    front-to-back thickness factor
export function inflate({ base, patches = [], box, res = 0.4, scale = 0.01, radius = 60, depth = 1, dome = 0.25, soften = 4, color = C.orange, smooth = 3, back = true }) {
  const [x0, y0, w, h] = box;
  const { a, W, H } = rasterise(base, x0, y0, w, h, res, soften);
  let sd = signedDistance(a, W, H);
  sd = blur(sd, W, H, 1);
  const R = radius * res;
  let maxD = 0;
  for (const v of sd) maxD = Math.max(maxD, v);
  const hgt = new Float32Array(W * H);
  for (let i = 0; i < W * H; i++) {
    const d = sd[i];
    if (d <= 0) continue;
    const dc = Math.min(d, R);
    hgt[i] = Math.sqrt(Math.max(0, dc * (2 * R - dc))) + dome * Math.max(0, d - R);
  }
  let hs = blur(hgt, W, H, smooth);
  // Keep the rim at zero after the blur.
  for (let i = 0; i < W * H; i++) if (sd[i] <= 0) hs[i] = 0; else hs[i] = Math.max(hs[i], hgt[i] * 0.85);

  // Patches: raised on the front, coloured.
  const base3 = new THREE.Color(color);
  const colors = new Float32Array(W * H * 3);
  for (let i = 0; i < W * H; i++) { colors[i * 3] = base3.r; colors[i * 3 + 1] = base3.g; colors[i * 3 + 2] = base3.b; }
  const ids = new Float32Array(W * H);
  const front = new Float32Array(hs);
  patches.forEach((p, k) => {
    const pr = rasterise(p.draw, x0, y0, w, h, res, p.soften ?? soften * 0.6);
    const psd = blur(signedDistance(pr.a, W, H), W, H, 1);
    const Rp = (p.radius ?? 18) * res;
    const pc = new THREE.Color(p.color);
    const ph = new Float32Array(W * H);
    for (let i = 0; i < W * H; i++) {
      const d = psd[i];
      if (d <= -1 || sd[i] <= 0) continue;
      const dc = Math.min(Math.max(d, 0), Rp);
      ph[i] = (p.puff ?? 0.5) * Math.sqrt(Math.max(0, dc * (2 * Rp - dc)));
      const t = Math.min(1, Math.max(0, d + 0.5));
      colors[i * 3] += (pc.r - colors[i * 3]) * t;
      colors[i * 3 + 1] += (pc.g - colors[i * 3 + 1]) * t;
      colors[i * 3 + 2] += (pc.b - colors[i * 3 + 2]) * t;
      if (d > 0) ids[i] = k + 1;
    }
    const phs = blur(ph, W, H, 1);
    for (let i = 0; i < W * H; i++) front[i] += phs[i];
  });

  // The grid, front and back sheets; outside corners of edge cells slide onto the contour.
  const px = new Float32Array(W * H), py = new Float32Array(W * H);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const i = y * W + x;
    let gx = x, gy = y;
    if (sd[i] < 0) {
      const sx = (sd[y * W + Math.min(W - 1, x + 1)] - sd[y * W + Math.max(0, x - 1)]) / 2;
      const sy = (sd[Math.min(H - 1, y + 1) * W + x] - sd[Math.max(0, y - 1) * W + x]) / 2;
      const l = Math.hypot(sx, sy) || 1;
      const m = Math.min(-sd[i], 1.5);
      gx += (sx / l) * m; gy += (sy / l) * m;
    }
    px[i] = (x0 - 1 / res + gx / res) * scale;
    py[i] = -(y0 - 1 / res + gy / res) * scale;
  }
  const zScale = (depth * scale) / res;
  const index = new Map();
  const pos = [], col = [], idv = [], tri = [];
  const vert = (i, side) => {
    const key = i * 2 + side;
    let v = index.get(key);
    if (v !== undefined) return v;
    v = pos.length / 3;
    index.set(key, v);
    const z = (side === 0 ? front[i] : -hs[i] * 0.85) * zScale;
    pos.push(px[i], py[i], z);
    col.push(colors[i * 3], colors[i * 3 + 1], colors[i * 3 + 2]);
    idv.push(side === 0 ? ids[i] : 0);
    return v;
  };
  for (let y = 0; y < H - 1; y++) for (let x = 0; x < W - 1; x++) {
    const a0 = y * W + x, b0 = a0 + 1, c0 = a0 + W, d0 = c0 + 1;
    if (sd[a0] <= 0 && sd[b0] <= 0 && sd[c0] <= 0 && sd[d0] <= 0) continue;
    const sides = back ? [0, 1] : [0];
    for (const s of sides) {
      const A = vert(a0, s), B = vert(b0, s), Cc = vert(c0, s), D = vert(d0, s);
      if (s === 0) tri.push(A, Cc, B, B, Cc, D);
      else tri.push(A, B, Cc, B, D, Cc);
    }
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  geo.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
  geo.setAttribute('inkId', new THREE.Float32BufferAttribute(idv, 1));
  geo.setIndex(tri);
  geo.computeVertexNormals();
  return geo;
}

/// A puffy tube along points (a twig, a leg, a glyph stroke).
export function tube(points, radius, { segments = 64, radial = 24, closed = false } = {}) {
  const curve = new THREE.CatmullRomCurve3(points.map((p) => new THREE.Vector3(...p)), closed, 'centripetal');
  const geo = new THREE.TubeGeometry(curve, segments, radius, radial, closed);
  return geo;
}

/// Round caps for an open tube.
export function capped(points, radius, mat, opts) {
  const g = new THREE.Group();
  g.add(new THREE.Mesh(tube(points, radius, opts), mat));
  for (const p of [points[0], points[points.length - 1]]) {
    const s = new THREE.Mesh(new THREE.SphereGeometry(radius, 24, 16), mat);
    s.position.set(...p);
    g.add(s);
  }
  return g;
}

// ---------------------------------------------------------------------------------------
// Materials.

/// A warm studio for reflections: cream sky, a hot orange horizon, soft boxes.
export function warmEnvironment(renderer, theme) {
  const env = new THREE.Scene();
  const sky = new THREE.Mesh(
    new THREE.SphereGeometry(50, 64, 32),
    new THREE.ShaderMaterial({
      side: THREE.BackSide,
      uniforms: { dark: { value: theme.name === 'dark' ? 1 : 0 } },
      vertexShader: 'varying vec3 vP; void main(){ vP = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.); }',
      fragmentShader: `varying vec3 vP; uniform float dark;
        void main(){
          float y = vP.y;
          vec3 top = mix(vec3(1.0,0.93,0.84), vec3(0.55,0.42,0.34), dark);
          vec3 hor = vec3(1.0,0.38,0.12);
          vec3 low = mix(vec3(0.30,0.12,0.06), vec3(0.06,0.03,0.02), dark);
          vec3 c = y > 0.0 ? mix(hor, top, smoothstep(0.0, 0.55, y)) : mix(hor, low, smoothstep(0.0, 0.35, -y));
          c += vec3(1.0,0.75,0.35) * 0.6 * exp(-pow((y-0.04)*14.0, 2.0));
          // Dark bands: chrome needs contrast to read as a mirror.
          c *= 1.0 - 0.75 * exp(-pow((y-0.32)*9.0, 2.0)) * (0.6 + 0.4 * sin(atan(vP.z, vP.x) * 3.0));
          c *= 1.0 - 0.6 * smoothstep(0.1, 0.5, -y);
          gl_FragColor = vec4(c, 1.0);
        }`,
    }),
  );
  env.add(sky);
  const box = (w, h, color, intensity, pos) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: new THREE.Color(color).multiplyScalar(intensity), side: THREE.DoubleSide }));
    m.position.set(...pos);
    m.lookAt(0, 0, 0);
    env.add(m);
  };
  box(18, 10, '#FFF4E8', 5.0, [-14, 18, 20]);
  box(6, 26, '#FFE2C4', 2.2, [26, 4, 8]);
  box(30, 4, '#FFB36B', 1.6, [0, 2, -30]);
  box(8, 8, '#FFFFFF', 6.0, [8, 30, 6]);
  box(3, 14, '#FFFFFF', 4.0, [-26, 6, -4]);
  const pm = new THREE.PMREMGenerator(renderer);
  const rt = pm.fromScene(env, 0.02);
  pm.dispose();
  return rt.texture;
}

/// Glossy, inflated vinyl.
export function puffy(color, { vertexColors = false } = {}) {
  return new THREE.MeshPhysicalMaterial({
    color: vertexColors ? '#ffffff' : color,
    vertexColors,
    roughness: 0.42,
    metalness: 0,
    clearcoat: 1,
    clearcoatRoughness: 0.18,
    sheen: 0.0,
    sheenRoughness: 0.6,
    sheenColor: new THREE.Color('#FFC9A0'),
    envMapIntensity: 0.7,
  });
}

/// Mirror-like metal, tinted warm.
export function chrome(color, roughness = 0.1) {
  return new THREE.MeshPhysicalMaterial({ color, metalness: 1, roughness, clearcoat: 0.6, clearcoatRoughness: 0.05, envMapIntensity: 1.35 });
}

/// Soft, matte cream (neumorphic).
export function soft(color, { roughness = 0.7, vertexColors = false } = {}) {
  return new THREE.MeshPhysicalMaterial({ color: vertexColors ? '#ffffff' : color, vertexColors, roughness, metalness: 0, sheen: 0.4, sheenRoughness: 0.8, sheenColor: new THREE.Color('#FFF1E4'), envMapIntensity: 0.5 });
}

/// The highest z of a geometry's vertices within [r] of (x, y): where to stand things on it.
export function frontZ(geo, x, y, r) {
  const pa = geo.getAttribute('position');
  let z = -Infinity;
  for (let i = 0; i < pa.count; i++) if (Math.hypot(pa.getX(i) - x, pa.getY(i) - y) < r) z = Math.max(z, pa.getZ(i));
  return z === -Infinity ? 0 : z;
}

/// A soft round shadow under something.
export function blobShadow(w, d, opacity, rgb = '40,20,10') {
  const c = document.createElement('canvas');
  c.width = c.height = 256;
  const g = c.getContext('2d');
  const grd = g.createRadialGradient(128, 128, 0, 128, 128, 128);
  grd.addColorStop(0, `rgba(${rgb},1)`);
  grd.addColorStop(0.45, `rgba(${rgb},0.55)`);
  grd.addColorStop(1, `rgba(${rgb},0)`);
  g.fillStyle = grd;
  g.fillRect(0, 0, 256, 256);
  const tex = new THREE.CanvasTexture(c);
  const m = new THREE.Mesh(new THREE.PlaneGeometry(w, d), new THREE.MeshBasicMaterial({ map: tex, transparent: true, opacity, depthWrite: false, toneMapped: false }));
  m.rotation.x = -Math.PI / 2;
  m.userData.noInk = true;
  return m;
}

// ---------------------------------------------------------------------------------------
// The renderer with its ink pass.

const idVertex = `
  attribute float inkId;
  varying vec3 vN;
  varying float vId;
  #include <common>
  #include <clipping_planes_pars_vertex>
  void main() {
    vN = normalize(normalMatrix * normal);
    #ifdef USE_INK_ID
      vId = inkId;
    #else
      vId = 0.0;
    #endif
    vec4 mvPosition = modelViewMatrix * vec4(position, 1.0);
    gl_Position = projectionMatrix * mvPosition;
    #include <clipping_planes_vertex>
  }`;
const idFragment = `
  #include <clipping_planes_pars_fragment>
  uniform float objectId;
  varying vec3 vN;
  varying float vId;
  void main() {
    #include <clipping_planes_fragment>
    gl_FragColor = vec4(normalize(vN) * 0.5 + 0.5, (objectId * 8.0 + floor(vId + 0.5)) / 255.0);
  }`;

const inkFragment = `
  uniform sampler2D tColor;
  uniform sampler2D tId;
  uniform sampler2D tDepth;
  uniform vec2 res;
  uniform vec3 ink;
  uniform float width;
  uniform float seed;
  uniform float jitter;
  uniform float near;
  uniform float far;
  uniform float ortho;
  varying vec2 vUv;

  float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
  }
  float lin(float d) { if (ortho > 0.5) return near + d * (far - near); float z = d * 2.0 - 1.0; return (2.0 * near * far) / (far + near - z * (far - near)); }

  float edgeAt(vec2 px, float w) {
    vec4 c0 = texture2D(tId, px / res);
    float d0 = lin(texture2D(tDepth, px / res).x);
    float e = 0.0;
    for (int k = 0; k < 8; k++) {
      float a = float(k) * 0.7853982;
      vec2 o = vec2(cos(a), sin(a)) * w;
      vec4 c1 = texture2D(tId, (px + o) / res);
      float d1 = lin(texture2D(tDepth, (px + o) / res).x);
      float idDiff = abs(c0.a - c1.a) * 255.0;
      e = max(e, step(0.5, idDiff));
      if (c0.a > 0.0 && c1.a > 0.0) {
        vec3 n0 = c0.rgb * 2.0 - 1.0, n1 = c1.rgb * 2.0 - 1.0;
        e = max(e, smoothstep(0.82, 0.55, dot(n0, n1)));
        e = max(e, smoothstep(0.035, 0.09, abs(d0 - d1) / min(d0, d1)));
      }
    }
    return e;
  }

  void main() {
    vec2 p = vUv * res;
    vec2 j = vec2(noise(p * 0.018 + seed * 7.13), noise(p * 0.018 + seed * 3.71 + 19.0)) - 0.5;
    vec2 q = p + j * jitter;
    float w = width * (0.7 + 0.6 * noise(p * 0.006 + seed * 1.3));
    float e = edgeAt(q, w);
    // A second, fainter pass slightly off: the pencil going over the line twice.
    vec2 j2 = vec2(noise(p * 0.03 + seed * 5.1 + 3.0), noise(p * 0.03 + seed * 2.3 + 41.0)) - 0.5;
    e = max(e, 0.4 * edgeAt(p + j2 * jitter * 1.6, w * 0.6));
    vec4 col = texture2D(tColor, vUv);
    vec3 rgb = col.rgb * (1.0 - e) + ink * e;
    float a = col.a * (1.0 - e) + e;
    gl_FragColor = vec4(rgb, a);
    #include <tonemapping_fragment>
    #include <colorspace_fragment>
  }`;

export class Stage {
  constructor(canvas, theme, { width, height, pixelRatio = 1, ink = true, inkWidth = 2.2, jitter = 3.2 }) {
    this.theme = theme;
    this.width = width * pixelRatio;
    this.height = height * pixelRatio;
    canvas.style.width = width + 'px';
    canvas.style.height = height + 'px';
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, alpha: true, preserveDrawingBuffer: true, premultipliedAlpha: true });
    renderer.setPixelRatio(1);
    renderer.setSize(this.width, this.height, false);
    renderer.setClearColor(0x000000, 0);
    renderer.localClippingEnabled = true;
    renderer.toneMapping = THREE.NeutralToneMapping;
    renderer.toneMappingExposure = theme.name === 'dark' ? 0.75 : 0.72;
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer = renderer;
    this.scene = new THREE.Scene();
    this.scene.environment = warmEnvironment(renderer, theme);
    this.ink = ink;
    this.inkWidth = inkWidth * pixelRatio;
    this.jitter = jitter * pixelRatio;

    this.colorRT = new THREE.WebGLRenderTarget(this.width, this.height, { type: THREE.HalfFloatType, samples: 8 });
    const depth = new THREE.DepthTexture(this.width, this.height);
    this.idRT = new THREE.WebGLRenderTarget(this.width, this.height, { depthTexture: depth, minFilter: THREE.NearestFilter, magFilter: THREE.NearestFilter });
    this.idMat = new THREE.ShaderMaterial({ uniforms: { objectId: { value: 0 } }, vertexShader: idVertex, fragmentShader: idFragment });
    this.idMatAttr = this.idMat.clone();
    this.idMatAttr.defines = { USE_INK_ID: 1 };
    this.inkMat = new THREE.ShaderMaterial({
      uniforms: {
        tColor: { value: this.colorRT.texture },
        tId: { value: this.idRT.texture },
        tDepth: { value: depth },
        res: { value: new THREE.Vector2(this.width, this.height) },
        // The same dark ink around 3D forms in both themes (the owner's choice).
        ink: { value: new THREE.Color(themes.light.line) },
        width: { value: this.inkWidth },
        seed: { value: 0 },
        jitter: { value: this.jitter },
        near: { value: 0.1 },
        far: { value: 100 },
        ortho: { value: 0 },
      },
      vertexShader: 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy, 0., 1.); }',
      fragmentShader: inkFragment,
      depthTest: false,
      depthWrite: false,
    });
    this.inkMat.toneMapped = true;
    this.quad = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.inkMat);
    this.quad.frustumCulled = false;
    this.quadScene = new THREE.Scene();
    this.quadScene.add(this.quad);
    this.quadCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  }

  lights({ key = 2.4, fill = 0.9, rim = 1.6 } = {}) {
    const s = this.scene;
    s.add(new THREE.HemisphereLight('#FFE4CC', this.theme.name === 'dark' ? '#2A1810' : '#B08A70', fill));
    const k = new THREE.DirectionalLight('#FFE9D4', key);
    k.position.set(-6, 10, 9);
    s.add(k);
    const r = new THREE.DirectionalLight('#FF9A5C', rim);
    r.position.set(8, 3, -8);
    s.add(r);
  }

  /// Inks every mesh with an id: a line is drawn where ids, normals or depth change.
  assignIds() {
    let n = 1;
    this.scene.traverse((o) => {
      if (!o.isMesh || o.userData.noInk) return;
      o.userData.inkId = o.userData.inkGroup ?? n++;
    });
  }

  render(camera, inkSeed = 0) {
    const r = this.renderer;
    this.inkMat.uniforms.near.value = camera.near;
    this.inkMat.uniforms.far.value = camera.far;
    this.inkMat.uniforms.ortho.value = camera.isOrthographicCamera ? 1 : 0;
    this.inkMat.uniforms.seed.value = inkSeed;
    r.setRenderTarget(this.colorRT);
    r.clear();
    r.render(this.scene, camera);

    // The id pass: normals and ids, without shadows and other un-inked things.
    const hidden = [];
    const swapped = [];
    this.scene.traverse((o) => {
      if (!o.isMesh) return;
      if (o.userData.noInk || !this.ink) { if (o.visible) { hidden.push(o); o.visible = false; } return; }
      const m = o.geometry.getAttribute('inkId') ? this.idMatAttr.clone() : this.idMat.clone();
      m.uniforms.objectId.value = o.userData.inkId ?? 1;
      m.clippingPlanes = o.material.clippingPlanes;
      m.side = o.material.side;
      swapped.push([o, o.material]);
      o.material = m;
    });
    const bg = this.scene.background;
    this.scene.background = null;
    r.setRenderTarget(this.idRT);
    r.setClearColor(0x000000, 0);
    r.clear();
    r.render(this.scene, camera);
    for (const [o, m] of swapped) { o.material.dispose(); o.material = m; }
    for (const o of hidden) o.visible = true;
    this.scene.background = bg;

    r.setRenderTarget(null);
    r.clear();
    r.render(this.quadScene, this.quadCam);
  }
}

/// Fonts and the page around the canvas: the hand-drawn layer (rough.js and the
/// README's fonts) is plain HTML/SVG over the 3D.
export async function fontsReady() {
  await document.fonts.ready;
  for (const f of ['700 20px Caveat', '500 20px Caveat', '500 20px Newsreader', '500 20px Manrope', '700 20px Manrope']) await document.fonts.load(f);
}
