// The hero: a campfire at night in real 3D. The fire's flickering point light is the only
// warm light; it lights the ground and the ring of stones (one per sandbox rule) and throws
// their shadows outwards. Drag to walk around the fire, hover or focus a stone to read its
// rule, click it to send a spark that breaks on the stone.
import * as THREE from "./lib/three.module.min.js";

const TEXT = {
  en: { hint: "Drag to look around · click a stone to test it", blocked: "blocked", test: "Send a spark at" },
  de: { hint: "Ziehen zum Umsehen · Stein anklicken zum Testen", blocked: "geblockt", test: "Einen Funken senden an" },
};

// ---------- small helpers ----------
const rand = (seed, i) => ((Math.sin(seed * 91.7 + i * 37.3) * 43758.5453) % 1 + 1) % 1;
function hash3(x, y, z) { return ((Math.sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453) % 1 + 1) % 1; }
function noise3(x, y, z) {
  const xi = Math.floor(x), yi = Math.floor(y), zi = Math.floor(z);
  const xf = x - xi, yf = y - yi, zf = z - zi;
  const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf), w = zf * zf * (3 - 2 * zf);
  const l = (a, b, t) => a + (b - a) * t;
  const c = (dx, dy, dz) => hash3(xi + dx, yi + dy, zi + dz);
  return l(l(l(c(0, 0, 0), c(1, 0, 0), u), l(c(0, 1, 0), c(1, 1, 0), u), v),
           l(l(c(0, 0, 1), c(1, 0, 1), u), l(c(0, 1, 1), c(1, 1, 1), u), v), w);
}
function fbm3(x, y, z) { let v = 0, a = .5; for (let i = 0; i < 4; i++) { v += a * noise3(x, y, z); x *= 2.03; y *= 2.03; z *= 2.03; a *= .5; } return v; }

function canvasTexture(size, draw, color = true) {
  const c = document.createElement("canvas");
  c.width = c.height = size;
  draw(c.getContext("2d"), size);
  const t = new THREE.CanvasTexture(c);
  if (color) t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 4;
  return t;
}
// Glow sprites: uploaded premultiplied, so nearly transparent texels carry no stray colour.
const softDot = (inner, outer) => {
  const t = canvasTexture(128, (g, s) => {
    const r = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
    r.addColorStop(0, inner); r.addColorStop(.35, outer); r.addColorStop(1, "rgba(0,0,0,0)");
    g.fillStyle = r; g.fillRect(0, 0, s, s);
  });
  t.premultiplyAlpha = true;
  return t;
};

// ---------- flames: noise-driven shader on camera-facing planes ----------
const flameVertex = `
  varying vec2 vUv;
  void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`;
const flameFragment = `
  uniform float uTime; uniform float uSeed; uniform float uPower;
  varying vec2 vUv;
  float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
  }
  float fbm(vec2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { v += a * noise(p); p *= 2.03; a *= 0.5; } return v; }
  void main() {
    vec2 uv = vUv;
    float x = (uv.x - 0.5) * 2.0;
    float n1 = fbm(vec2(x * 1.7 + uSeed, uv.y * 2.4 - uTime * 1.7));
    float n2 = fbm(vec2(x * 3.3 - uSeed * 1.3, uv.y * 4.6 - uTime * 2.9));
    float sway = (n1 - 0.5) * 0.7 * uv.y + (n2 - 0.5) * 0.22;
    float width = mix(0.7, 0.03, pow(uv.y, 0.85));
    float shape = 1.0 - smoothstep(width * 0.45, width, abs(x + sway));
    float h = uv.y + (n1 - 0.5) * 0.45 + (n2 - 0.5) * 0.2;
    float body = shape * (1.0 - smoothstep(0.25, 0.95, h)) * smoothstep(0.0, 0.07, uv.y);
    float heat = clamp(body * (1.3 - uv.y * 1.05) * uPower, 0.0, 1.0);
    vec3 col = mix(vec3(0.45, 0.03, 0.02), vec3(1.0, 0.3, 0.04), smoothstep(0.04, 0.38, heat));
    col = mix(col, vec3(1.0, 0.66, 0.2), smoothstep(0.38, 0.7, heat));
    col = mix(col, vec3(1.0, 0.94, 0.78), smoothstep(0.78, 1.0, heat));
    gl_FragColor = vec4(col * (0.9 + heat * 1.6) * body, 0.0);
  }`;

// Pure additive light: adds colour, leaves the canvas alpha alone, so glow over the
// transparent page reads as light instead of a dark box.
function glow(mat) {
  mat.blending = THREE.CustomBlending;
  mat.blendEquation = THREE.AddEquation;
  mat.blendSrc = THREE.OneFactor; mat.blendDst = THREE.OneFactor;
  mat.blendSrcAlpha = THREE.ZeroFactor; mat.blendDstAlpha = THREE.OneFactor;
  mat.transparent = true; mat.depthWrite = false;
  return mat;
}

export function start(ring, { stones, reduce, lang }) {
  const L = TEXT[lang] || TEXT.en;
  const tip = ring.querySelector("[data-tip]");
  const agentEl = ring.querySelector("[data-agent]");
  const insideEl = ring.querySelector(".inside-label");
  const rulesList = ring.querySelector("[data-rules]");

  // ---------- renderer, scene, camera ----------
  const canvas = document.createElement("canvas");
  canvas.className = "hero3d";
  canvas.setAttribute("aria-hidden", "true");
  ring.prepend(canvas);
  const labels = document.createElement("div");
  labels.className = "hero3d-labels";
  ring.appendChild(labels);
  const hint = document.createElement("div");
  hint.className = "hero3d-hint";
  hint.textContent = L.hint;
  ring.appendChild(hint);

  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: "high-performance" });
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 1.75));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.15;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(30, 1, .1, 60);
  const target = new THREE.Vector3(0, .05, 0);
  const view = { yaw: 0, pitch: .52, dist: 9.8, vYaw: 0, vPitch: 0 };

  // ---------- light: one fire, a little moon ----------
  scene.add(new THREE.HemisphereLight(0x4a4266, 0x140c10, .7));
  const moon = new THREE.DirectionalLight(0x8090c0, .35);
  moon.position.set(-6, 8, -5);
  scene.add(moon);
  const fireLight = new THREE.PointLight(0xff8a40, 26, 14, 1.7);
  fireLight.position.set(0, .95, 0);
  fireLight.castShadow = true;
  fireLight.shadow.mapSize.set(1024, 1024);
  fireLight.shadow.bias = -.004;
  fireLight.shadow.radius = 4;
  fireLight.shadow.camera.near = .2;
  scene.add(fireLight);
  const bounce = new THREE.PointLight(0xff5a1f, 6, 6, 2);   // low warm bounce off the embers
  bounce.position.set(0, .15, 0);
  scene.add(bounce);

  // ---------- ground: dark earth, an ash pit, fading into the page ----------
  const groundSize = 22;
  const earth = canvasTexture(1024, (g, s) => {
    g.fillStyle = "#2a2025"; g.fillRect(0, 0, s, s);
    for (let i = 0; i < 9000; i++) {
      const x = Math.random() * s, y = Math.random() * s, r = Math.random() * 2.2;
      g.fillStyle = `rgba(${Math.random() < .5 ? "12,8,10" : "70,58,62"},${(Math.random() * .35).toFixed(2)})`;
      g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fill();
    }
    // the ash pit
    const pit = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s * .075);
    pit.addColorStop(0, "#0b0809"); pit.addColorStop(.7, "#18121a"); pit.addColorStop(1, "rgba(42,32,37,0)");
    g.fillStyle = pit; g.beginPath(); g.arc(s / 2, s / 2, s * .075, 0, Math.PI * 2); g.fill();
    for (let i = 0; i < 700; i++) {
      const a = Math.random() * Math.PI * 2, d = Math.random() * s * .06;
      g.fillStyle = `rgba(150,140,145,${(Math.random() * .18).toFixed(2)})`;
      g.fillRect(s / 2 + Math.cos(a) * d, s / 2 + Math.sin(a) * d, 1.5, 1.5);
    }
  });
  const embersMap = canvasTexture(1024, (g, s) => {
    g.fillStyle = "#000"; g.fillRect(0, 0, s, s);
    for (let i = 0; i < 260; i++) {
      const a = Math.random() * Math.PI * 2, d = Math.pow(Math.random(), 2.2) * s * .04, r = .4 + Math.random() * 1.4;
      const x = s / 2 + Math.cos(a) * d, y = s / 2 + Math.sin(a) * d;
      const gr = g.createRadialGradient(x, y, 0, x, y, r * 2);
      gr.addColorStop(0, "#ffb050"); gr.addColorStop(.5, "#c43010"); gr.addColorStop(1, "rgba(0,0,0,0)");
      g.fillStyle = gr; g.beginPath(); g.arc(x, y, r * 2, 0, Math.PI * 2); g.fill();
    }
  });
  const fade = canvasTexture(256, (g, s) => {
    const r = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
    r.addColorStop(0, "#fff"); r.addColorStop(.3, "#fff"); r.addColorStop(.72, "#444"); r.addColorStop(1, "#000");
    g.fillStyle = r; g.fillRect(0, 0, s, s);
  }, false);
  const groundMat = new THREE.MeshStandardMaterial({
    map: earth, roughness: 1, metalness: 0, alphaMap: fade, transparent: true,
    emissive: 0xffffff, emissiveMap: embersMap, emissiveIntensity: 1.2,
  });
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(groundSize, groundSize), groundMat);
  ground.rotation.x = -Math.PI / 2;
  ground.receiveShadow = true;
  scene.add(ground);

  // ---------- logs: a small teepee with glowing cracks ----------
  const crackMap = canvasTexture(256, (g, s) => {
    g.fillStyle = "#000"; g.fillRect(0, 0, s, s);
    g.strokeStyle = "#ff7a2a"; g.lineCap = "round";
    for (let i = 0; i < 26; i++) {
      g.lineWidth = 1 + Math.random() * 2.5;
      g.globalAlpha = .4 + Math.random() * .6;
      let x = Math.random() * s, y = Math.random() * s;
      g.beginPath(); g.moveTo(x, y);
      for (let k = 0; k < 4; k++) { x += (Math.random() - .5) * 40; y += Math.random() * 30; g.lineTo(x, y); }
      g.stroke();
    }
  });
  const bark = canvasTexture(256, (g, s) => {
    g.fillStyle = "#2a1711"; g.fillRect(0, 0, s, s);
    for (let i = 0; i < 60; i++) {
      g.fillStyle = `rgba(${Math.random() < .5 ? "10,5,4" : "80,48,32"},${(.2 + Math.random() * .4).toFixed(2)})`;
      g.fillRect(Math.random() * s, 0, 1 + Math.random() * 3, s);
    }
  });
  const logMat = new THREE.MeshStandardMaterial({ map: bark, color: 0x8a6a5a, roughness: .9, emissive: 0xffffff, emissiveMap: crackMap, emissiveIntensity: 1.2 });
  const logs = new THREE.Group();
  const up = new THREE.Vector3(0, 1, 0);
  const addLog = (from, to, r) => {
    const dir = new THREE.Vector3().subVectors(to, from);
    const m = new THREE.Mesh(new THREE.CylinderGeometry(r * .85, r, dir.length(), 12, 1), logMat);
    m.position.copy(from).addScaledVector(dir, .5);
    m.quaternion.setFromUnitVectors(up, dir.normalize());
    m.castShadow = true;
    logs.add(m);
  };
  for (let k = 0; k < 6; k++) {
    const a = k / 6 * Math.PI * 2 + .3;
    addLog(new THREE.Vector3(Math.cos(a) * .42, .02, Math.sin(a) * .42), new THREE.Vector3(Math.cos(a) * .04, .66, Math.sin(a) * .04), .042 + rand(k, 1) * .014);
  }
  addLog(new THREE.Vector3(-.55, .05, -.18), new THREE.Vector3(.55, .05, .22), .055);
  addLog(new THREE.Vector3(-.26, .05, .52), new THREE.Vector3(.22, .05, -.52), .05);
  scene.add(logs);

  // ---------- fire ----------
  const flames = [];
  const fireGroup = new THREE.Group();
  [[1.4, 2.3, 0, 0, 1.3], [1.15, 1.95, .12, 3.1, 1.15], [1.05, 1.65, -.14, 6.7, 1.1], [.8, 1.25, .02, 9.2, 1.4], [1.25, 1.5, -.05, 12.4, .9]].forEach(([w, h, dx, seed, power]) => {
    const mat = glow(new THREE.ShaderMaterial({
      uniforms: { uTime: { value: 0 }, uSeed: { value: seed }, uPower: { value: power } },
      vertexShader: flameVertex, fragmentShader: flameFragment, side: THREE.DoubleSide,
    }));
    const geo = new THREE.PlaneGeometry(w, h);
    geo.translate(dx, h / 2, 0);
    const m = new THREE.Mesh(geo, mat);
    m.position.y = .05;
    m.renderOrder = 10;
    fireGroup.add(m);
    flames.push(m);
  });
  scene.add(fireGroup);
  const halo = new THREE.Sprite(glow(new THREE.SpriteMaterial({ map: softDot("rgba(255,160,70,.7)", "rgba(255,80,20,.2)") })));
  halo.scale.set(4.4, 4.4, 1); halo.position.set(0, .95, 0); halo.renderOrder = 9;
  scene.add(halo);
  const pool = new THREE.Mesh(new THREE.PlaneGeometry(5, 5), glow(new THREE.MeshBasicMaterial({
    map: softDot("rgba(255,120,45,.6)", "rgba(196,40,20,.16)"),
  })));
  pool.rotation.x = -Math.PI / 2; pool.position.y = .015;
  scene.add(pool);

  // ---------- embers and smoke ----------
  const EMBERS = 220;
  const ePos = new Float32Array(EMBERS * 3), eCol = new Float32Array(EMBERS * 3);
  const embers = Array.from({ length: EMBERS }, () => ({ life: 1, max: 1, x: 0, y: -10, z: 0, vx: 0, vy: 0, vz: 0, g: 0, heat: 1 }));
  const eGeo = new THREE.BufferGeometry();
  eGeo.setAttribute("position", new THREE.BufferAttribute(ePos, 3));
  eGeo.setAttribute("color", new THREE.BufferAttribute(eCol, 3));
  const emberPoints = new THREE.Points(eGeo, glow(new THREE.PointsMaterial({
    size: .055, map: softDot("rgba(255,230,180,1)", "rgba(255,120,40,.6)"), vertexColors: true, sizeAttenuation: true,
  })));
  emberPoints.renderOrder = 11;
  scene.add(emberPoints);
  let emberCursor = 0;
  function emit(x, y, z, vx, vy, vz, g, max, heat = 1) {
    const e = embers[emberCursor]; emberCursor = (emberCursor + 1) % EMBERS;
    Object.assign(e, { x, y, z, vx, vy, vz, g, life: 0, max, heat });
  }
  const smokeMat = () => new THREE.SpriteMaterial({ map: softDot("rgba(120,100,105,.55)", "rgba(80,66,70,.2)"), transparent: true, depthWrite: false, opacity: 0 });
  const smoke = Array.from({ length: 14 }, (_, i) => {
    const s = new THREE.Sprite(smokeMat());
    s.userData = { life: i / 14, speed: .1 + Math.random() * .06, drift: Math.random() * 6 };
    scene.add(s);
    return s;
  });

  // ---------- the ring of stones: one per sandbox rule ----------
  const R = 2.25;
  // fine grain on the stone surface (a bump map, so it catches the firelight)
  const stoneBump = canvasTexture(256, (g, s) => {
    const img = g.createImageData(s, s);
    for (let y = 0; y < s; y++) for (let x = 0; x < s; x++) {
      const v = 128 + (fbm3(x * .06, y * .06, 3) - .5) * 160 + (Math.random() - .5) * 40;
      const o = (y * s + x) * 4; img.data[o] = img.data[o + 1] = img.data[o + 2] = v; img.data[o + 3] = 255;
    }
    g.putImageData(img, 0, 0);
  }, false);
  const stoneObjs = stones.map(([label, rule, line], i) => {
    const geo = new THREE.SphereGeometry(1, 96, 64);   // indexed: smooth normals
    const pos = geo.attributes.position, v = new THREE.Vector3();
    const colors = new Float32Array(pos.count * 3);
    const sx = .36 + rand(i, 1) * .1, sy = .2 + rand(i, 2) * .06, sz = .27 + rand(i, 3) * .07;
    for (let k = 0; k < pos.count; k++) {
      v.fromBufferAttribute(pos, k);
      const n = fbm3(v.x * 1.3 + i * 7, v.y * 1.3, v.z * 1.3);
      const bump = .8 + n * .42 + (fbm3(v.x * 5 + i, v.y * 5, v.z * 5) - .5) * .05;
      v.multiplyScalar(bump);
      if (v.y < -.35) v.y = -.35 + (v.y + .35) * .25;   // flat underside, resting on the ground
      pos.setXYZ(k, v.x * sx, v.y * sy, v.z * sz);
      const tone = .26 + fbm3(v.x * 2.2 + i, v.y * 2.2, v.z * 2.2) * .26;
      colors.set([tone * 1.0, tone * .92, tone * .93], k * 3);
    }
    geo.setAttribute("color", new THREE.BufferAttribute(colors, 3));
    geo.computeVertexNormals();
    const mat = new THREE.MeshStandardMaterial({ vertexColors: true, roughness: .82, metalness: 0, emissive: 0xff5a1f, emissiveIntensity: 0, bumpMap: stoneBump, bumpScale: 1.2 });
    const mesh = new THREE.Mesh(geo, mat);
    const a = (i + .5) / stones.length * Math.PI * 2;
    mesh.position.set(Math.cos(a) * R, sy * .35 - .02, Math.sin(a) * R);
    mesh.rotation.y = -a + Math.PI / 2 + (rand(i, 5) - .5) * .5;
    mesh.castShadow = true; mesh.receiveShadow = true;
    mesh.userData.index = i;
    scene.add(mesh);

    const el = document.createElement("button");
    el.type = "button";
    el.className = "stone-label";
    el.innerHTML = `<b>${label}</b><span class="rule">${rule}</span><span class="line">${line}</span><span class="blocked">${L.blocked}</span>`;
    el.setAttribute("aria-label", `${L.test} ${label}: ${rule}. ${line}`);
    labels.appendChild(el);
    rulesList?.insertAdjacentHTML("beforeend", `<li>${label}: ${line}</li>`);
    const top = new THREE.Vector3(mesh.position.x, mesh.position.y + sy + .2, mesh.position.z);
    const st = { mesh, mat, el, label, rule, line, top, flash: 0, hover: false };
    el.addEventListener("pointerenter", () => setHover(st, true));
    el.addEventListener("pointerleave", () => setHover(st, false));
    el.addEventListener("focus", () => setHover(st, true));
    el.addEventListener("blur", () => setHover(st, false));
    el.addEventListener("click", () => { interacted(); fireAt(st); });
    return st;
  });

  let hovered = null;
  function setHover(st, on) {
    if (on) { if (hovered && hovered !== st) hovered.hover = false; hovered = st; st.hover = true; interacted(); }
    else if (hovered === st) { st.hover = false; hovered = null; }
    stoneObjs.forEach((s) => s.el.classList.toggle("open", s.hover));
    canvas.style.cursor = hovered ? "pointer" : "grab";
  }

  // ---------- sparks that break on a stone ----------
  const sparkTex = softDot("rgba(255,240,200,1)", "rgba(255,140,40,.7)");
  const flights = [], waves = [];
  function fireAt(st) {
    const s = new THREE.Sprite(glow(new THREE.SpriteMaterial({ map: sparkTex })));
    s.scale.set(.32, .32, 1);
    scene.add(s);
    const from = new THREE.Vector3(0, 1.25, 0), to = st.mesh.position.clone().setY(st.top.y - .25);
    flights.push({ s, from, to, t: 0, st });
  }
  function impact(st) {
    st.flash = 1;
    st.el.classList.remove("hit"); void st.el.offsetWidth; st.el.classList.add("hit");
    clearTimeout(st.hitTimer);
    st.hitTimer = setTimeout(() => st.el.classList.remove("hit"), 1600);
    const p = st.mesh.position;
    const back = new THREE.Vector3(-p.x, 0, -p.z).normalize();
    for (let k = 0; k < 34; k++) {
      const sp = .6 + Math.random() * 1.6;
      emit(p.x + back.x * .3, st.top.y - .3, p.z + back.z * .3,
           back.x * sp + (Math.random() - .5) * 1.4, .6 + Math.random() * 1.8, back.z * sp + (Math.random() - .5) * 1.4,
           -4.5, .5 + Math.random() * .5, 1);
    }
    const wave = new THREE.Mesh(new THREE.RingGeometry(.32, .37, 64), glow(new THREE.MeshBasicMaterial({
      color: 0xff8a3a, side: THREE.DoubleSide,
    })));
    wave.rotation.x = -Math.PI / 2;
    wave.position.set(p.x, .03, p.z);
    scene.add(wave);
    waves.push({ m: wave, t: 0 });
    shake = .06;
  }

  // ---------- interaction: drag to orbit, with inertia ----------
  let dragging = false, lastX = 0, lastY = 0, lastInteraction = -1e9, shake = 0, hintGone = false;
  function interacted() {
    lastInteraction = performance.now();
    if (!hintGone) { hintGone = true; hint.classList.add("gone"); }
    wake();
  }
  canvas.style.cursor = "grab";
  canvas.addEventListener("pointerdown", (e) => {
    dragging = true; lastX = e.clientX; lastY = e.clientY;
    canvas.setPointerCapture(e.pointerId);
    canvas.style.cursor = "grabbing";
    view.vYaw = view.vPitch = 0;
    downAt = { x: e.clientX, y: e.clientY };
    interacted();
  });
  let downAt = null;
  canvas.addEventListener("pointermove", (e) => {
    if (dragging) {
      const dx = e.clientX - lastX, dy = e.clientY - lastY;
      lastX = e.clientX; lastY = e.clientY;
      view.vYaw = -dx * .006; view.vPitch = dy * .004;
      view.yaw += view.vYaw; view.pitch = Math.min(.95, Math.max(.16, view.pitch + view.vPitch));
      interacted();
    } else {
      pick(e);
    }
  });
  const endDrag = (e) => {
    if (!dragging) return;
    dragging = false;
    canvas.style.cursor = hovered ? "pointer" : "grab";
    // a click without dragging on a stone tests it
    if (downAt && Math.hypot(e.clientX - downAt.x, e.clientY - downAt.y) < 5) {
      const st = pick(e);
      if (st) fireAt(st);
    }
    downAt = null;
  };
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", () => { dragging = false; });
  canvas.addEventListener("pointerleave", () => { if (!dragging && hovered) setHover(hovered, false); });

  const raycaster = new THREE.Raycaster(), ndc = new THREE.Vector2();
  function pick(e) {
    const r = canvas.getBoundingClientRect();
    ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    raycaster.setFromCamera(ndc, camera);
    const hit = raycaster.intersectObjects(stoneObjs.map((s) => s.mesh))[0];
    const st = hit ? stoneObjs[hit.object.userData.index] : null;
    if (st !== hovered) { if (hovered) setHover(hovered, false); if (st) setHover(st, true); }
    return st;
  }

  // ---------- layout ----------
  let W = 1, H = 1, offX = 0, offY = 0;
  function resize() {
    // the canvas (and the label layer) reach a bit beyond the ring box
    const r = canvas.getBoundingClientRect(), rr = ring.getBoundingClientRect();
    W = Math.max(1, r.width); H = Math.max(1, r.height);
    offX = r.left - rr.left; offY = r.top - rr.top;
    renderer.setSize(W, H, false);
    camera.aspect = W / H;
    // narrow screens: step back so the whole ring fits
    const narrow = W < 560;
    view.dist = narrow ? 10.4 : W / H < 1.05 ? 10.8 : 9.8;
    target.y = narrow ? .8 : .05;
    camera.updateProjectionMatrix();
    wake();
  }
  new ResizeObserver(resize).observe(canvas);

  // ---------- agent names above the fire ----------
  const AGENTS = ["claude", "codex", "copilot", "opencode", "gemini"];
  let ai = 0;
  if (!reduce && agentEl) setInterval(() => {
    agentEl.classList.add("swap");
    setTimeout(() => { ai = (ai + 1) % AGENTS.length; agentEl.textContent = AGENTS[ai]; agentEl.classList.remove("swap"); }, 400);
  }, 4200);

  // ---------- the loop ----------
  const tmp = new THREE.Vector3(), camDir = new THREE.Vector3();
  let time = 2, last = 0, raf = 0, visible = true, nextAuto = 4, emberAcc = 0;
  function project(v) {
    tmp.copy(v).project(camera);
    return { x: (tmp.x * .5 + .5) * W, y: (-tmp.y * .5 + .5) * H, z: tmp.z };
  }

  function frame(now) {
    raf = 0;
    const dt = last ? Math.min(.05, (now - last) / 1000) : 1 / 60;
    last = now;
    if (!reduce) time += dt;

    // camera: drift slowly when left alone, glide out of a drag
    if (!dragging) {
      view.yaw += view.vYaw; view.pitch = Math.min(.95, Math.max(.16, view.pitch + view.vPitch));
      view.vYaw *= .94; view.vPitch *= .9;
      const idle = now - lastInteraction > 4000;
      if (!reduce && idle && !hovered) view.yaw += dt * .09;
    }
    shake *= .85;
    camera.position.set(
      Math.sin(view.yaw) * Math.cos(view.pitch) * view.dist + (Math.random() - .5) * shake,
      Math.sin(view.pitch) * view.dist + .4 + (Math.random() - .5) * shake,
      Math.cos(view.yaw) * Math.cos(view.pitch) * view.dist);
    camera.lookAt(target);

    // fire: flicker the light, animate the flames, face them to the camera
    const flick = .82 + .12 * Math.sin(time * 11.3) + .08 * Math.sin(time * 23.7 + 1.3) + .06 * (noise3(time * 3, 0, 0) - .5) * 2;
    fireLight.intensity = 26 * flick;
    fireLight.position.set(Math.sin(time * 5.1) * .05, .95 + Math.sin(time * 7.3) * .04, Math.cos(time * 4.3) * .05);
    bounce.intensity = 6 * (.8 + .2 * flick);
    groundMat.emissiveIntensity = .9 + .5 * Math.sin(time * 1.7) * flick;
    logMat.emissiveIntensity = 1 + .5 * flick;
    halo.material.opacity = .75 + .25 * flick;
    pool.material.opacity = .7 + .3 * flick;
    const faceYaw = Math.atan2(camera.position.x, camera.position.z);
    flames.forEach((m, k) => { m.material.uniforms.uTime.value = time + k * .37; m.rotation.y = faceYaw + (k - 2) * .3; });

    // embers rise from the fire
    if (!reduce) {
      emberAcc += dt * 70;
      while (emberAcc > 1) {
        emberAcc--;
        const a = Math.random() * Math.PI * 2, d = Math.random() * .35;
        emit(Math.cos(a) * d, .5 + Math.random() * .6, Math.sin(a) * d,
             (Math.random() - .5) * .3, 1.1 + Math.random() * 1.3, (Math.random() - .5) * .3, .35, 1.6 + Math.random() * 1.8, .7 + Math.random() * .3);
      }
    }
    for (let k = 0; k < EMBERS; k++) {
      const e = embers[k];
      if (e.life < e.max && !reduce) {
        e.life += dt;
        e.vy += e.g * dt;
        e.vx += Math.sin(time * 2 + k) * .4 * dt; e.vz += Math.cos(time * 1.7 + k) * .4 * dt;
        e.x += e.vx * dt; e.y += e.vy * dt; e.z += e.vz * dt;
        if (e.y < .02 && e.g < 0) { e.y = .02; e.vy *= -.3; e.vx *= .5; e.vz *= .5; }
      }
      const t = e.life / e.max, alive = e.life < e.max ? 1 : 0;
      const b = alive * Math.max(0, 1 - t) * e.heat * (.6 + .4 * Math.sin(time * 20 + k));
      ePos[k * 3] = e.x; ePos[k * 3 + 1] = alive ? e.y : -10; ePos[k * 3 + 2] = e.z;
      eCol[k * 3] = b; eCol[k * 3 + 1] = b * (.45 + .4 * (1 - t)); eCol[k * 3 + 2] = b * .15;
    }
    eGeo.attributes.position.needsUpdate = true;
    eGeo.attributes.color.needsUpdate = true;

    smoke.forEach((s, k) => {
      const u = s.userData;
      if (!reduce) u.life += dt * u.speed;
      if (u.life > 1) u.life -= 1;
      const t = u.life;
      s.position.set(Math.sin(t * 4 + u.drift) * .35 * t, 1.6 + t * 3.2, Math.cos(t * 3 + u.drift) * .3 * t);
      const sc = .6 + t * 2.6;
      s.scale.set(sc, sc, 1);
      s.material.opacity = Math.sin(t * Math.PI) * .16;
    });

    // automatic sparks now and then, at a stone in front
    if (!reduce && time > nextAuto && now - lastInteraction > 6000) {
      nextAuto = time + 6 + Math.random() * 3;
      camDir.set(camera.position.x, 0, camera.position.z).normalize();
      const front = stoneObjs.filter((s) => s.mesh.position.clone().normalize().dot(camDir) > .25);
      if (front.length) fireAt(front[(Math.random() * front.length) | 0]);
    }
    for (let k = flights.length - 1; k >= 0; k--) {
      const f = flights[k];
      f.t += dt / .75;
      const t = Math.min(1, f.t);
      f.s.position.lerpVectors(f.from, f.to, t).y += Math.sin(t * Math.PI) * 1.1;
      if (Math.random() < .8) emit(f.s.position.x, f.s.position.y, f.s.position.z, (Math.random() - .5) * .3, -.2, (Math.random() - .5) * .3, -1.5, .35, .8);
      if (f.t >= 1) { scene.remove(f.s); f.s.material.dispose(); flights.splice(k, 1); impact(f.st); }
    }
    for (let k = waves.length - 1; k >= 0; k--) {
      const w = waves[k];
      w.t += dt / 1.1;
      const s = 1 + w.t * 2.4;
      w.m.scale.set(s, s, s);
      w.m.material.opacity = Math.max(0, 1 - w.t) * .9;
      if (w.t >= 1) { scene.remove(w.m); w.m.geometry.dispose(); w.m.material.dispose(); waves.splice(k, 1); }
    }

    // stones: glow on hover and on impact
    stoneObjs.forEach((st) => {
      st.flash *= .93;
      const glow = Math.max(st.flash * 1.4, st.hover ? .28 + .08 * Math.sin(time * 6) : 0);
      st.mat.emissiveIntensity += (glow - st.mat.emissiveIntensity) * .25;
    });

    renderer.render(scene, camera);

    // labels follow their stones; far ones fade
    camDir.copy(camera.position).setY(0).normalize();
    stoneObjs.forEach((st) => {
      const p = project(st.top);
      const facing = st.mesh.position.clone().normalize().dot(camDir);   // 1 = in front, -1 = behind the fire
      st.el.style.transform = `translate(${p.x.toFixed(1)}px, ${p.y.toFixed(1)}px) translate(-50%, -100%)`;
      st.el.style.opacity = st.hover ? 1 : (.55 + .45 * (facing * .5 + .5)).toFixed(2);
      st.el.style.zIndex = st.hover ? 50 : Math.round(20 + facing * 10);
    });
    if (agentEl) {
      const p = project(new THREE.Vector3(0, 2.55, 0));
      // keep the name inside the scene (narrow screens put the fire's top near the edge)
      const ax = p.x + offX, ay = Math.max(p.y + offY, 22);
      agentEl.style.transform = `translate(${ax.toFixed(1)}px, ${ay.toFixed(1)}px) translate(-50%, -50%)`;
      if (insideEl) insideEl.style.transform = `translate(${ax.toFixed(1)}px, ${(ay + 24).toFixed(1)}px) translate(-50%, 0)`;
    }

    const busy = !reduce || dragging || Math.abs(view.vYaw) > 1e-4 || Math.abs(view.vPitch) > 1e-4 || flights.length || waves.length
      || stoneObjs.some((s) => s.flash > .01 || Math.abs(s.mat.emissiveIntensity - (s.hover ? .3 : 0)) > .01);
    if (visible && busy) raf = requestAnimationFrame(frame);
  }
  function wake() { if (!raf && visible) { last = 0; raf = requestAnimationFrame(frame); } }

  new IntersectionObserver(([e]) => { visible = e.isIntersecting; if (visible) wake(); }).observe(ring);
  document.addEventListener("visibilitychange", () => { visible = !document.hidden; if (visible) wake(); });
  resize();
  wake();
}
