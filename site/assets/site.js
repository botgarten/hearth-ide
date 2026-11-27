(() => {
  /* ---------- texts per page language (index.html: English, de/index.html: German) ---------- */
  const LANG = document.documentElement.lang.startsWith("de") ? "de" : "en";
  const T = {
    en: {
      copy: "Copy", copied: "Copied",
      copiedHint: "Paste it into Terminal and press Return.",
      copyFailed: "Copying is not possible – the command is selected, copy it with ⌘C.",
      stones: [
        ["~/.ssh", "filesystem deny: ~/.ssh", "Your SSH keys stay outside."],
        ["~/.zshrc", "filesystem deny: shell configs", "Your shell configuration stays outside."],
        ["Browser data", "filesystem deny: browser profiles", "Cookies, passwords and sessions stay outside."],
        ["~/.aws", "filesystem deny: credentials", "Your cloud credentials stay outside."],
        ["example.com", "network: allowlist only", "Hosts you haven’t allowed stay out of reach."],
        ["~/Documents", "no read or write access", "The rest of your home folder stays outside."],
        ["~/.gnupg", "filesystem deny: keys", "Your GPG keys stay outside."],
        ["Port 22", "network: only through the proxy", "Direct connections are blocked."],
      ],
    },
    de: {
      copy: "Kopieren", copied: "Kopiert",
      copiedHint: "Im Terminal einfügen und Enter drücken.",
      copyFailed: "Kopieren nicht möglich – der Befehl ist markiert, mit ⌘C kopieren.",
      stones: [
        ["~/.ssh", "filesystem deny: ~/.ssh", "Deine SSH-Schlüssel bleiben draußen."],
        ["~/.zshrc", "filesystem deny: Shell-Configs", "Deine Shell-Konfiguration bleibt draußen."],
        ["Browserdaten", "filesystem deny: Browser-Profile", "Cookies, Passwörter und Sitzungen bleiben draußen."],
        ["~/.aws", "filesystem deny: Credentials", "Deine Cloud-Zugangsdaten bleiben draußen."],
        ["example.com", "network: nur Allowlist", "Nicht freigegebene Hosts bleiben unerreichbar."],
        ["~/Documents", "kein Lese- oder Schreibrecht", "Der Rest deines Home bleibt draußen."],
        ["~/.gnupg", "filesystem deny: Schlüssel", "Deine GPG-Schlüssel bleiben draußen."],
        ["Port 22", "network: nur über den Proxy", "Direkte Verbindungen sind gesperrt."],
      ],
    },
  }[LANG];

  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const NS = "http://www.w3.org/2000/svg";
  const root = document.documentElement;

  /* ---------- copy install command ---------- */
  document.querySelectorAll("[data-install]").forEach((box) => {
    const btn = box.querySelector("[data-copy]");
    const cmd = box.querySelector("[data-cmd]");
    const text = cmd.textContent;
    const status = box.querySelector(".copy-status");
    const label = btn.querySelector(".copy-text");
    btn.addEventListener("click", async () => {
      let ok = false;
      try { await navigator.clipboard.writeText(text); ok = true; }
      catch {
        const range = document.createRange(); range.selectNodeContents(cmd);
        const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range);
        try { ok = document.execCommand("copy"); } catch { ok = false; }
      }
      btn.dataset.state = ok ? "done" : "";
      const embers = box.closest(".close")?.querySelector(".embers");
      if (ok && embers && !reduce) { embers.classList.remove("flare"); void embers.offsetWidth; embers.classList.add("flare"); }
      label.textContent = ok ? T.copied : T.copy;
      status.textContent = ok ? T.copiedHint : T.copyFailed;
      clearTimeout(btn._t);
      btn._t = setTimeout(() => { btn.dataset.state = ""; label.textContent = T.copy; status.textContent = ""; }, 3200);
    });
  });

  /* ---------- field stones: a noise surface lit only by the fire ---------- */
  let stoneId = 0;
  const rand = (seed, i) => ((Math.sin(seed * 91.7 + i * 37.3) * 43758.5453) % 1 + 1) % 1;
  function outline(w, h, seed) {
    const n = 12, pts = [];
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2;
      const j = 0.74 + 0.26 * rand(seed, i);
      const flat = Math.sin(a) > 0.25 ? 0.7 : 1;            // flat resting underside
      pts.push([Math.cos(a) * w / 2 * j, Math.sin(a) * h / 2 * j * flat]);
    }
    let d = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`;
    for (let i = 0; i < n; i++) {
      const p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n];
      d += ` C${(p1[0] + (p2[0] - p0[0]) / 6).toFixed(1)},${(p1[1] + (p2[1] - p0[1]) / 6).toFixed(1)} ${(p2[0] - (p3[0] - p1[0]) / 6).toFixed(1)},${(p2[1] - (p3[1] - p1[1]) / 6).toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`;
    }
    return d + "Z";
  }
  // (lx, ly): the fire's position relative to the stone's centre
  function stone(parent, { w, h, seed, label, lx, ly, font }) {
    const id = "st" + (stoneId++);
    const d = outline(w, h, seed);
    const len = Math.hypot(lx, ly) || 1, ux = lx / len, uy = ly / len;
    const relief = (h * (.42 + rand(seed, 5) * .08)).toFixed(1);
    const light = `<fePointLight x="${lx.toFixed(0)}" y="${ly.toFixed(0)}" z="${(h * 1.25).toFixed(0)}"/>`;
    const g = document.createElementNS(NS, "g");
    g.setAttribute("class", "stone");
    g.innerHTML = `
      <defs>
        <filter id="${id}f" x="-15%" y="-25%" width="130%" height="150%" primitiveUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
          <!-- height map: a rounded body (blurred outline) roughened by noise -->
          <feGaussianBlur in="SourceAlpha" stdDeviation="${(h * .22).toFixed(1)}" result="body"/>
          <feTurbulence type="fractalNoise" baseFrequency="${(0.028 + rand(seed, 3) * .014).toFixed(3)}" numOctaves="4" seed="${seed}" result="rough"/>
          <feComposite in="body" in2="rough" operator="arithmetic" k2="1" k3=".09" k4="-.045" result="height"/>
          <!-- colour: mottled stone with fine dark grains -->
          <feTurbulence type="fractalNoise" baseFrequency="${(0.011 + rand(seed, 7) * .006).toFixed(3)}" numOctaves="3" seed="${seed + 40}" result="mott"/>
          <feColorMatrix in="mott" type="matrix" values=".42 0 0 0 .26  .36 0 0 0 .22  .36 0 0 0 .24  0 0 0 0 1" result="tone"/>
          <feTurbulence type="fractalNoise" baseFrequency=".42" numOctaves="1" seed="${seed + 90}" result="grain"/>
          <feComponentTransfer in="grain" result="specks"><feFuncR type="discrete" tableValues=".5 1 1 1 1 1 1 .78"/><feFuncG type="discrete" tableValues=".5 1 1 1 1 1 1 .78"/><feFuncB type="discrete" tableValues=".5 1 1 1 1 1 1 .78"/><feFuncA type="linear" slope="0" intercept="1"/></feComponentTransfer>
          <feComposite in="tone" in2="specks" operator="arithmetic" k1="1" result="albedo"/>
          <!-- firelight: diffuse plus a soft sheen on the side facing the flames -->
          <feDiffuseLighting in="height" surfaceScale="${relief}" diffuseConstant="1" lighting-color="#ffd8b4" result="diff">${light}</feDiffuseLighting>
          <feSpecularLighting in="height" surfaceScale="${relief}" specularConstant=".32" specularExponent="18" lighting-color="#ffae70" result="spec">${light}</feSpecularLighting>
          <feComposite in="albedo" in2="diff" operator="arithmetic" k1="1.12" k2=".17" result="lit"/>
          <feComposite in="spec" in2="lit" operator="arithmetic" k2=".38" k3="1" result="sheen"/>
          <feComposite in="sheen" in2="SourceAlpha" operator="in"/>
        </filter>
        <linearGradient id="${id}shade" gradientUnits="userSpaceOnUse" x1="${(ux * w * .5).toFixed(0)}" y1="${(uy * h * .5).toFixed(0)}" x2="${(-ux * w * .5).toFixed(0)}" y2="${(-uy * h * .5).toFixed(0)}">
          <stop offset="0" stop-color="#0e0a12" stop-opacity="0"/><stop offset=".6" stop-color="#0e0a12" stop-opacity=".15"/><stop offset="1" stop-color="#0e0a12" stop-opacity=".55"/>
        </linearGradient>
        <radialGradient id="${id}heat" gradientUnits="userSpaceOnUse" cx="${(ux * w * .45).toFixed(0)}" cy="${(uy * h * .45).toFixed(0)}" r="${(w * .55).toFixed(0)}">
          <stop offset="0" stop-color="#ff7a2a" stop-opacity=".34"/><stop offset=".7" stop-color="#ff5a1f" stop-opacity="0"/>
        </radialGradient>
        <radialGradient id="${id}hit"><stop offset="0" stop-color="#ffa62b" stop-opacity=".9"/><stop offset=".6" stop-color="#ff5a1f" stop-opacity=".3"/><stop offset="1" stop-color="#c4161c" stop-opacity="0"/></radialGradient>
        <filter id="${id}blur"><feGaussianBlur stdDeviation="${(h * .12).toFixed(1)}"/></filter>
        <filter id="${id}soft" x="-30%" y="-60%" width="160%" height="220%"><feGaussianBlur stdDeviation="${(font * .45).toFixed(1)}"/></filter>
        <clipPath id="${id}clip"><path d="${d}"/></clipPath>
      </defs>
      <ellipse class="hitglow" rx="${(w * .72).toFixed(0)}" ry="${(h * .9).toFixed(0)}" fill="url(#${id}hit)"/>
      <ellipse cx="${(-ux * h * .35).toFixed(1)}" cy="${(h * .3).toFixed(1)}" rx="${(w * .52).toFixed(0)}" ry="${(h * .26).toFixed(0)}" fill="#050307" opacity=".85" filter="url(#${id}blur)"/>
      <path class="rock" d="${d}" fill="#7a6470" filter="url(#${id}f)"/>
      <g clip-path="url(#${id}clip)">
        <rect x="${-w}" y="${-h}" width="${w * 2}" height="${h * 2}" fill="url(#${id}shade)"/>
        <rect class="heat" x="${-w}" y="${-h}" width="${w * 2}" height="${h * 2}" fill="url(#${id}heat)"/>
      </g>
      <ellipse clip-path="url(#${id}clip)" rx="${(label.length * font * .36 + font).toFixed(1)}" ry="${(font * .85).toFixed(1)}" fill="#3f3439" opacity=".78" filter="url(#${id}soft)"/>
      <g class="cut" font-size="${font.toFixed(1)}" text-anchor="middle">
        <text class="recess" y="${(font * .36 - 1.4).toFixed(1)}">${label}</text>
        <text class="lip" y="${(font * .36).toFixed(1)}">${label}</text>
      </g>`;
    parent.appendChild(g);
    return g;
  }

  /* ---------- the ring (real sandbox rules) ---------- */
  const STONES = T.stones;
  const ring = document.querySelector("[data-ring]");
  const svg = document.querySelector("[data-stones]");
  const tip = document.querySelector("[data-tip]");
  const cx = 500, cy = 450, rx = 375, ry = 255, fireX = 500, fireY = 450 + 860 * .05;
  let pinned = null;

  const ringStones = STONES.map(([label, rule, line], i) => {
    const a = -Math.PI / 2 + (i + .5) / STONES.length * Math.PI * 2;
    const x = cx + Math.cos(a) * rx, y = cy + Math.sin(a) * ry;
    const depth = (Math.sin(a) + 1) / 2;
    const s = (0.84 + depth * 0.3) * (0.92 + rand(i + 11, 1) * .16);
    const w = Math.max(210, label.length * 18.5 + 104) * s, h = (100 + rand(i + 3, 2) * 18) * s;
    const holder = document.createElementNS(NS, "g");
    holder.setAttribute("transform", `translate(${x.toFixed(1)} ${y.toFixed(1)})`);
    holder.setAttribute("tabindex", "0");
    holder.setAttribute("role", "listitem");
    holder.setAttribute("aria-label", `${label}: ${line}`);
    holder.setAttribute("data-stone-holder", "");
    const g = stone(holder, { w, h, seed: i + 2, label, lx: fireX - x, ly: fireY - y, font: 25 * s });
    const st = { holder, g, x, y, w, h, label, rule, line, depth };
    // While a stone is hovered or focused it owns the tip; sparks leave the ring alone.
    const hold = () => { pinned = st; g.classList.add("hit"); showTip(st, true); };
    const release = () => { if (pinned === st) pinned = null; g.classList.remove("hit"); hideTip(); };
    holder.addEventListener("mouseenter", hold);
    holder.addEventListener("focus", hold);
    holder.addEventListener("mouseleave", release);
    holder.addEventListener("blur", release);
    return st;
  });
  ringStones.slice().sort((a, b) => a.depth - b.depth).forEach((s) => svg.appendChild(s.holder));

  let tipTimer;
  function showTip(st, sticky) {
    tip.innerHTML = `<b>${st.rule}</b>${st.line}`;
    tip.classList.add("show");
    clearTimeout(tipTimer);
    if (!sticky) tipTimer = setTimeout(hideTip, 4000);
  }
  function hideTip() { tip.classList.remove("show"); }

  /* ---------- the stones that stay outside (below the hero) ---------- */
  document.querySelectorAll("[data-arc] li").forEach((li, i, all) => {
    const label = li.dataset.stone;
    const w = Math.min(312, Math.max(250, label.length * 19 + 92)), h = 118;
    const v = document.createElementNS(NS, "svg");
    v.setAttribute("viewBox", "-160 -66 320 138");
    v.setAttribute("aria-hidden", "true");
    // the fire sits above the middle of the arc: light falls in from that side
    const mid = (all.length - 1) / 2, off = (i - mid) / mid;
    stone(v, { w, h, seed: i + 21, label, lx: -off * 260, ly: -220, font: 30 });
    li.prepend(v);
    li.querySelector("p").insertAdjacentHTML("afterbegin", `<span class="sr-only">${label}: </span>`);
  });

  /* ---------- agent names in the fire ---------- */
  const agentEl = document.querySelector("[data-agent]");
  const AGENTS = ["claude", "codex", "copilot", "opencode", "gemini"];
  let ai = 0;
  if (!reduce) setInterval(() => {
    agentEl.classList.add("swap");
    setTimeout(() => { ai = (ai + 1) % AGENTS.length; agentEl.textContent = AGENTS[ai]; agentEl.classList.remove("swap"); }, 400);
  }, 4200);

  /* ---------- fire, smoke and sparks ---------- */
  // The simulation runs in fixed 60 Hz steps, so it burns at the same pace on 60 and 120 Hz screens.
  const canvas = document.querySelector("[data-fire]");
  const ctx = canvas.getContext("2d");
  const buf = document.createElement("canvas"), bctx = buf.getContext("2d");   // flames are summed here first
  let W = 0, H = 0, visible = true, raf = 0;
  function resize() {
    const r = canvas.getBoundingClientRect(), dpr = Math.min(devicePixelRatio || 1, 2);
    W = r.width; H = r.height; canvas.width = W * dpr; canvas.height = H * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    buf.width = Math.max(1, Math.round(W * dpr)); buf.height = Math.max(1, Math.round(H * dpr));
    bctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (reduce) drawStatic();
  }

  const flames = [], sparks = [], smoke = [];
  const fx = () => W * 0.5, fy = () => H * (fireY / 860);

  // Logs and coals keep their shape; only their glow moves.
  const R = (i) => rand(77, i);
  const LOGS = [[-0.3, -1, .95], [0.28, 1, 1], [0.04, 0, .82]].map(([rot, side, len], k) => ({
    rot, side, len,
    cracks: Array.from({ length: 4 }, (_, i) => ({ at: -.36 + i * .2 + R(k * 9 + i) * .1, w: .05 + R(k * 9 + i + 4) * .05, ph: R(k * 9 + i + 7) * 6 })),
  }));
  const COALS = Array.from({ length: 18 }, (_, i) => ({ x: (R(i + 40) - .5) * .2, y: R(i + 60) * .028, r: .007 + R(i + 80) * .009, ph: R(i + 100) * 6 }));

  function heatColor(h, a) {
    // h: 1 = white-hot base, 0 = dark red tip
    const stops = [[0, 120, 16, 24], [.3, 214, 52, 22], [.55, 255, 112, 26], [.8, 255, 170, 58], [1, 255, 222, 150]];
    let i = 1; while (i < stops.length - 1 && h > stops[i][0]) i++;
    const [p0, r0, g0, b0] = stops[i - 1], [p1, r1, g1, b1] = stops[i], t = Math.min(1, Math.max(0, (h - p0) / (p1 - p0)));
    return `rgba(${(r0 + (r1 - r0) * t) | 0},${(g0 + (g1 - g0) * t) | 0},${(b0 + (b1 - b0) * t) | 0},${a.toFixed(3)})`;
  }

  function drawBed(time) {
    const x = fx(), y = fy() + H * .025;
    ctx.globalCompositeOperation = "lighter";
    COALS.forEach((c) => {
      const glow = .45 + .35 * Math.sin(time * .0021 + c.ph) * flick;
      const r = c.r * W;
      const g = ctx.createRadialGradient(x + c.x * W, y + c.y * W, 0, x + c.x * W, y + c.y * W, r * 2.2);
      g.addColorStop(0, heatColor(.55 + glow * .3, .9 * glow)); g.addColorStop(.45, heatColor(.3, .45 * glow)); g.addColorStop(1, "rgba(120,16,24,0)");
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x + c.x * W, y + c.y * W, r * 2.2, 0, Math.PI * 2); ctx.fill();
    });
    ctx.globalCompositeOperation = "source-over";
  }

  function drawLogs(time) {
    const x = fx(), y = fy() + H * .02, T = W * .024;
    LOGS.forEach((log) => {
      const L = W * .18 * log.len;
      ctx.save(); ctx.translate(x + log.side * W * .016, y); ctx.rotate(log.rot);
      // bark: lit from the flames above, charred underneath
      const g = ctx.createLinearGradient(0, -T / 2, 0, T / 2);
      g.addColorStop(0, "#6a3524"); g.addColorStop(.25, "#3b1c15"); g.addColorStop(.7, "#1a0d0d"); g.addColorStop(1, "#0b0608");
      ctx.fillStyle = g; ctx.beginPath(); ctx.roundRect(-L / 2, -T / 2, L, T, T * .42); ctx.fill();
      // bark grain
      ctx.strokeStyle = "rgba(0,0,0,.35)"; ctx.lineWidth = Math.max(.6, T * .06);
      for (let i = 0; i < 3; i++) {
        const yy = -T * .25 + i * T * .22;
        ctx.beginPath(); ctx.moveTo(-L * .46, yy); ctx.bezierCurveTo(-L * .15, yy - T * .08, L * .15, yy + T * .08, L * .46, yy); ctx.stroke();
      }
      // sawn ends with rings
      [-1, 1].forEach((e) => {
        ctx.fillStyle = "#4a2a1e"; ctx.beginPath(); ctx.ellipse(e * L / 2, 0, T * .2, T * .48, 0, 0, Math.PI * 2); ctx.fill();
        ctx.strokeStyle = "rgba(20,8,8,.6)"; ctx.lineWidth = .7; ctx.beginPath(); ctx.ellipse(e * L / 2, 0, T * .1, T * .26, 0, 0, Math.PI * 2); ctx.stroke();
      });
      // glowing cracks in the charcoal
      ctx.globalCompositeOperation = "lighter";
      log.cracks.forEach((c) => {
        const a = (.35 + .4 * Math.sin(time * .0017 + c.ph)) * flick;
        const cx0 = c.at * L, cw = c.w * L;
        const cg = ctx.createLinearGradient(cx0 - cw, 0, cx0 + cw, 0);
        cg.addColorStop(0, "rgba(255,90,31,0)"); cg.addColorStop(.5, heatColor(.62, Math.max(0, a))); cg.addColorStop(1, "rgba(255,90,31,0)");
        ctx.strokeStyle = cg; ctx.lineWidth = Math.max(1, T * .12);
        ctx.beginPath(); ctx.moveTo(cx0 - cw, -T * .3); ctx.lineTo(cx0 - cw * .3, -T * .12); ctx.lineTo(cx0 + cw * .2, -T * .28); ctx.lineTo(cx0 + cw, -T * .1); ctx.stroke();
      });
      ctx.globalCompositeOperation = "source-over";
      ctx.restore();
    });
  }

  function spawnFlame() {
    // tongues: particles born on a few wandering columns; hotter in the middle
    const column = (Math.random() * 7 | 0) - 3;
    const centre = 1 - Math.abs(column) / 4;
    flames.push({ x: fx() + column * W * .012 + (Math.random() - .5) * W * .014, y: fy() - H * .005,
      vx: -column * .05 + (Math.random() - .5) * .2, vy: -(1.3 + Math.random() * 1.6) * (.8 + centre * .4), life: 0,
      max: 30 + Math.random() * 36 * (.6 + centre * .6), r: W * (0.009 + Math.random() * 0.014) * (.8 + centre * .4),
      heat: .62 + centre * .3 + Math.random() * .08, col: column, wob: Math.random() * 6 });
  }
  function spawnSpark(target) {
    const s = { x: fx() + (Math.random() - .5) * W * .05, y: fy() - H * .08, life: 0, max: 140 + Math.random() * 80, target: null };
    if (target) {
      s.target = target;
      const k = W / 1000, dx = target.x * k - s.x, dy = target.y * k - s.y, t = 60 + Math.random() * 30;
      s.vx = dx / t; s.vy = dy / t - 1.2; s.g = 2.4 / t;
    } else { s.vx = (Math.random() - .5) * 1.2; s.vy = -(1.5 + Math.random() * 1.8); s.g = 0; }
    sparks.push(s);
  }

  let step = 0, flick = 1, nextHit = 1500, simTime = 0;
  // one 60 Hz simulation step
  function simulate() {
    step++; simTime += 1000 / 60;
    flick += ((0.75 + Math.random() * .5) - flick) * .14;
    for (let i = 0; i < 10; i++) spawnFlame();
    if (step % 4 === 0) smoke.push({ x: fx() + (Math.random() - .5) * W * .04, y: fy() - H * .22, vx: (Math.random() - .5) * .3, vy: -(.45 + Math.random() * .45), life: 0, max: 170, r: W * .03 });
    if (step % 10 === 0) spawnSpark(null);
    if (simTime > nextHit) {
      nextHit = simTime + 5000 + Math.random() * 2000;
      if (!pinned) spawnSpark(ringStones[(Math.random() * ringStones.length) | 0]);
    }
    const t0 = simTime * .004;
    for (let i = flames.length - 1; i >= 0; i--) {
      const p = flames[i];
      p.life++;
      // a shared draught bends whole tongues, not single particles
      const age = p.life / p.max;
      const draught = (Math.sin(p.y * .03 + t0 + p.col * 1.9) * .5 + Math.sin(t0 * .7 + p.wob) * .15) * (1 + age * 1.6);
      p.x += p.vx + draught; p.y += p.vy; p.vy *= 1.008;
      p.vx += (fx() - p.x) * .0018;
      if (p.life >= p.max) flames.splice(i, 1);
    }
    for (let i = smoke.length - 1; i >= 0; i--) {
      const p = smoke[i]; p.life++; p.x += p.vx + Math.sin(p.life * .03) * .25; p.y += p.vy; p.r += .25;
      if (p.life >= p.max) smoke.splice(i, 1);
    }
    for (let i = sparks.length - 1; i >= 0; i--) {
      const s = sparks[i];
      s.life++; s.vy += s.g; s.x += s.vx + (s.target ? 0 : Math.sin(s.life * .08) * .4); s.y += s.vy;
      let dead = s.life > s.max;
      if (s.target) {
        const k = W / 1000, dx = s.target.x * k - s.x, dy = s.target.y * k - s.y;
        if (dx * dx + dy * dy < (22 * k) ** 2 || s.life > 120) {
          dead = true;
          const tg = s.target.g;
          tg.classList.add("hit"); setTimeout(() => { if (pinned?.g !== tg) tg.classList.remove("hit"); }, 700);
          if (!pinned) showTip(s.target, false);
          for (let j = 0; j < 7; j++) sparks.push({ x: s.x, y: s.y, vx: (Math.random() - .5) * 2.4, vy: -Math.random() * 1.6, g: .06, life: 0, max: 22 + Math.random() * 12, target: null, ember: true });
        }
      }
      if (dead) sparks.splice(i, 1);
    }
  }

  function render() {
    ctx.clearRect(0, 0, W, H);
    root.style.setProperty("--flicker", flick.toFixed(2));
    const floor = ctx.createRadialGradient(fx(), fy() + H * .02, 0, fx(), fy() + H * .02, W * .38);
    floor.addColorStop(0, `rgba(255,90,31,${(.24 * flick).toFixed(3)})`); floor.addColorStop(.5, `rgba(196,22,28,${(.08 * flick).toFixed(3)})`); floor.addColorStop(1, "rgba(196,22,28,0)");
    ctx.fillStyle = floor; ctx.beginPath(); ctx.ellipse(fx(), fy() + H * .02, W * .38, H * .22, 0, 0, Math.PI * 2); ctx.fill();

    // smoke drifts up and fades into the night
    smoke.forEach((p) => {
      const t = p.life / p.max;
      const g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, p.r);
      const fade = Math.min(1, Math.max(0, (p.y - H * .12) / (H * .25)));
      g.addColorStop(0, `rgba(96,68,72,${(.11 * Math.sin(t * Math.PI) * fade).toFixed(3)})`); g.addColorStop(1, "rgba(96,68,72,0)");
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2); ctx.fill();
    });

    drawBed(simTime);
    drawLogs(simTime);

    // flames: stretched tongues summed into a buffer, then laid on twice:
    // blurred for the glow, sharp for the licks
    bctx.clearRect(0, 0, W, H);
    bctx.globalCompositeOperation = "lighter";
    flames.forEach((p) => {
      const t = p.life / p.max;
      const rad = p.r * (1 - t * .75);
      const stretch = 1.9 + t * 2.6;
      const heat = Math.max(0, p.heat * (1 - t * 1.05));
      const a = Math.sin(Math.min(1, t * 6) * Math.PI / 2) * (1 - t) * .15;
      bctx.save(); bctx.translate(p.x, p.y); bctx.scale(1, stretch);
      const g = bctx.createRadialGradient(0, 0, 0, 0, 0, rad);
      g.addColorStop(0, heatColor(heat, a)); g.addColorStop(.6, heatColor(heat * .8, a * .45)); g.addColorStop(1, heatColor(heat * .6, 0));
      bctx.fillStyle = g; bctx.beginPath(); bctx.arc(0, 0, rad, 0, Math.PI * 2); bctx.fill();
      bctx.restore();
    });
    // white-hot heart at the base
    const core = bctx.createRadialGradient(fx(), fy() - H * .03, 0, fx(), fy() - H * .03, W * .05);
    core.addColorStop(0, `rgba(255,226,170,${(.13 * flick).toFixed(3)})`); core.addColorStop(1, "rgba(255,170,60,0)");
    bctx.fillStyle = core; bctx.beginPath(); bctx.ellipse(fx(), fy() - H * .03, W * .05, W * .07, 0, 0, Math.PI * 2); bctx.fill();
    bctx.globalCompositeOperation = "source-over";

    ctx.globalCompositeOperation = "lighter";
    ctx.save();
    ctx.filter = `blur(${Math.max(4, W * .014).toFixed(1)}px)`;
    ctx.globalAlpha = .7; ctx.drawImage(buf, 0, 0, W, H);
    ctx.filter = "none"; ctx.globalAlpha = 1; ctx.drawImage(buf, 0, 0, W, H);
    ctx.restore();

    sparks.forEach((s) => {
      const t = s.life / s.max;
      const a = s.target ? .95 : (1 - t) * .9;
      ctx.strokeStyle = `rgba(255,${s.ember ? 120 : 196},${s.ember ? 40 : 96},${a.toFixed(3)})`;
      ctx.lineWidth = s.target ? 2.2 : 1.3; ctx.lineCap = "round";
      // a short tail along the flight path: a glowing spark, not a dot
      ctx.beginPath(); ctx.moveTo(s.x, s.y); ctx.lineTo(s.x - s.vx * .9, s.y - s.vy * .9); ctx.stroke();
    });
    ctx.globalCompositeOperation = "source-over";
  }

  function drawStatic() {
    flames.length = sparks.length = smoke.length = 0; step = 0; simTime = 0;
    for (let i = 0; i < 120; i++) simulate();
    sparks.length = 0;
    render();
  }

  let last = 0, acc = 0;
  function tick(now) {
    raf = 0;
    if (!visible) { last = 0; return; }
    acc += last ? Math.min(now - last, 100) : 1000 / 60; last = now;
    let n = 0;
    while (acc >= 1000 / 60 && n < 4) { simulate(); acc -= 1000 / 60; n++; }
    if (n === 4) acc = 0;
    render();
    raf = requestAnimationFrame(tick);
  }

  resize();
  addEventListener("resize", resize);
  if (!reduce) {
    new IntersectionObserver(([e]) => { visible = e.isIntersecting; if (visible && !raf) raf = requestAnimationFrame(tick); }).observe(ring);
    document.addEventListener("visibilitychange", () => { visible = !document.hidden; if (visible && !raf) raf = requestAnimationFrame(tick); });
    raf = requestAnimationFrame(tick);
  }

  /* ---------- three strokes ignite in order ---------- */
  const strokes = [...document.querySelectorAll("[data-strokes] li")];
  if (reduce) strokes.forEach((li) => li.classList.add("on"));
  else new IntersectionObserver((entries, obs) => {
    if (!entries.some((e) => e.isIntersecting)) return;
    strokes.forEach((li, i) => setTimeout(() => li.classList.add("on"), 250 + i * 750));
    obs.disconnect();
  }, { threshold: .4 }).observe(document.querySelector("[data-strokes]"));

  /* ---------- spec phases light up one after another ---------- */
  const phases = [...document.querySelectorAll("[data-phases] li")];
  const phaseList = document.querySelector("[data-phases]");
  if (phaseList) {
    if (reduce) phases.forEach((li) => li.classList.add("on"));
    else new IntersectionObserver((entries, obs) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      phases.forEach((li, i) => setTimeout(() => li.classList.add("on"), 250 + i * 600));
      obs.disconnect();
    }, { threshold: .35 }).observe(phaseList);
  }
})();
