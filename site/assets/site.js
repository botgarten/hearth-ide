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

  /* ---------- field stones: smooth slabs with a rim of firelight ---------- */
  // One stone = soft shadow, a dark body, grain, a heat glow and a rim light. The light
  // comes from the fire: `light(st, dx, dy)` turns it to wherever the fire is now.
  let stoneId = 0;
  const rand = (seed, i) => ((Math.sin(seed * 91.7 + i * 37.3) * 43758.5453) % 1 + 1) % 1;
  function outline(w, h, seed) {
    const n = 10, pts = [];
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2;
      const j = 0.88 + 0.12 * rand(seed, i);
      const flat = Math.sin(a) > 0.3 ? 0.82 : 1;              // resting underside
      pts.push([Math.cos(a) * w / 2 * j, Math.sin(a) * h / 2 * j * flat]);
    }
    let d = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`;
    for (let i = 0; i < n; i++) {
      const p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n];
      d += ` C${(p1[0] + (p2[0] - p0[0]) / 6).toFixed(1)},${(p1[1] + (p2[1] - p0[1]) / 6).toFixed(1)} ${(p2[0] - (p3[0] - p1[0]) / 6).toFixed(1)},${(p2[1] - (p3[1] - p1[1]) / 6).toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`;
    }
    return d + "Z";
  }

  // Shared defs: a grain tile and the shadow blur, in one hidden svg for the whole page.
  const defs = document.createElementNS(NS, "svg");
  defs.setAttribute("width", "0"); defs.setAttribute("height", "0"); defs.setAttribute("aria-hidden", "true");
  defs.style.position = "absolute";
  defs.innerHTML = `<defs>
    <filter id="stoneGrainF" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="7" result="n"/>
      <feColorMatrix in="n" type="matrix" values="0 0 0 0 1  0 0 0 0 .9  0 0 0 0 .86  0 0 0 -1.1 .62"/>
    </filter>
    <pattern id="stoneGrain" patternUnits="userSpaceOnUse" width="160" height="160">
      <rect width="160" height="160" filter="url(#stoneGrainF)"/>
    </pattern>
    <filter id="stoneShadowF" x="-50%" y="-80%" width="200%" height="260%"><feGaussianBlur stdDeviation="9"/></filter>
  </defs>`;
  document.body.appendChild(defs);

  function stone(parent, { w, h, seed, label, font }) {
    const id = "st" + (stoneId++);
    const d = outline(w, h, seed);
    const g = document.createElementNS(NS, "g");
    g.setAttribute("class", "stone");
    g.innerHTML = `
      <defs>
        <linearGradient id="${id}body" gradientUnits="userSpaceOnUse" x1="0" y1="${-h / 2}" x2="0" y2="${h / 2}">
          <stop offset="0" stop-color="#6e5459"/><stop offset=".45" stop-color="#3a2b31"/><stop offset="1" stop-color="#17101a"/>
        </linearGradient>
        <linearGradient id="${id}rim" gradientUnits="userSpaceOnUse" x1="0" y1="${h / 2}" x2="0" y2="${-h / 2}">
          <stop offset="0" stop-color="#ffb04a" stop-opacity=".95"/><stop offset=".35" stop-color="#ff5a1f" stop-opacity=".35"/><stop offset=".7" stop-color="#ff5a1f" stop-opacity="0"/>
        </linearGradient>
        <radialGradient id="${id}heat" gradientUnits="userSpaceOnUse" cx="0" cy="${h / 2}" r="${(w * .62).toFixed(0)}">
          <stop offset="0" stop-color="#ff7a2a" stop-opacity=".55"/><stop offset=".65" stop-color="#ff5a1f" stop-opacity="0"/>
        </radialGradient>
        <clipPath id="${id}clip"><path d="${d}"/></clipPath>
      </defs>
      <ellipse class="shadow" cy="${(h * .38).toFixed(1)}" rx="${(w * .5).toFixed(0)}" ry="${(h * .2).toFixed(0)}" fill="#030204" opacity=".9" filter="url(#stoneShadowF)"/>
      <ellipse class="wave" rx="${(w * .53).toFixed(0)}" ry="${(h * .6).toFixed(0)}" fill="none" stroke="#ff8a3a" stroke-width="2"/>
      <path class="rock" d="${d}" fill="url(#${id}body)"/>
      <g clip-path="url(#${id}clip)">
        <rect x="${-w}" y="${-h}" width="${w * 2}" height="${h * 2}" fill="url(#stoneGrain)" opacity=".16"/>
        <rect class="heat" x="${-w}" y="${-h}" width="${w * 2}" height="${h * 2}" fill="url(#${id}heat)"/>
        <path d="${d}" transform="translate(0 ${(-h * .1).toFixed(1)})" fill="none" stroke="#fff" stroke-opacity=".07" stroke-width="${(h * .12).toFixed(1)}"/>
      </g>
      <path class="rim" d="${d}" fill="none" stroke="url(#${id}rim)" stroke-width="2.4"/>
      <g class="cut" font-size="${font.toFixed(1)}" text-anchor="middle">
        <text class="recess" y="${(font * .36 + 1.2).toFixed(1)}">${label}</text>
        <text class="lip" y="${(font * .36).toFixed(1)}">${label}</text>
      </g>`;
    parent.appendChild(g);
    const grads = { rim: g.querySelector(`#${id}rim`), heat: g.querySelector(`#${id}heat`), body: g.querySelector(`#${id}body`) };
    return { g, grads, w, h };
  }

  // Turns a stone's light towards (dx, dy): the fire relative to the stone's centre.
  function light(st, dx, dy) {
    const len = Math.hypot(dx, dy) || 1, ux = dx / len, uy = dy / len, { w, h, grads } = st;
    grads.rim.setAttribute("x1", (ux * w * .5).toFixed(1)); grads.rim.setAttribute("y1", (uy * h * .5).toFixed(1));
    grads.rim.setAttribute("x2", (-ux * w * .5).toFixed(1)); grads.rim.setAttribute("y2", (-uy * h * .5).toFixed(1));
    grads.heat.setAttribute("cx", (ux * w * .42).toFixed(1)); grads.heat.setAttribute("cy", (uy * h * .5).toFixed(1));
    grads.body.setAttribute("x1", (ux * w * .3).toFixed(1)); grads.body.setAttribute("y1", (uy * h * .5).toFixed(1));
    grads.body.setAttribute("x2", (-ux * w * .3).toFixed(1)); grads.body.setAttribute("y2", (-uy * h * .5).toFixed(1));
  }

  /* ---------- the stones that stay outside (below the hero) ---------- */
  document.querySelectorAll("[data-arc] li").forEach((li, i, all) => {
    const label = li.dataset.stone;
    const font = 26;
    const w = Math.min(300, label.length * font * .62 + 64), h = 86;
    const v = document.createElementNS(NS, "svg");
    v.setAttribute("viewBox", "-160 -60 320 125");
    v.setAttribute("aria-hidden", "true");
    // the fire sits above the middle of the arc: light falls in from that side
    const mid = (all.length - 1) / 2, off = (i - mid) / mid;
    light(stone(v, { w, h, seed: i + 21, label, font }), -off * 260, -220);
    li.prepend(v);
    li.querySelector("p").insertAdjacentHTML("afterbegin", `<span class="sr-only">${label}: </span>`);
  });

  /* ---------- the hero: a real 3D campfire when WebGL is there, else the 2D ring ---------- */
  const heroRing = document.querySelector("[data-ring]");
  function webgl() {
    try { const c = document.createElement("canvas"); return !!(c.getContext("webgl2") || c.getContext("webgl")); } catch { return false; }
  }
  if (heroRing && webgl()) {
    heroRing.classList.add("is-3d");
    import("./hero3d.js")
      .then((m) => m.start(heroRing, { stones: T.stones, reduce, lang: LANG }))
      .catch((e) => { console.warn("3D hero failed, using 2D", e); heroRing.classList.remove("is-3d"); start2D(); });
  } else if (heroRing) {
    start2D();
  }

  function start2D() {
    /* ---------- the ring (real sandbox rules), slowly circling the fire ---------- */
    const STONES = T.stones;
    const ring = document.querySelector("[data-ring]");
    const svg = document.querySelector("[data-stones]");
    const svgBack = document.querySelector("[data-stones-back]");
    const tip = document.querySelector("[data-tip]");
    const rules = document.querySelector("[data-rules]");
    const cx = 500, cy = 420, rx = 410, ry = 270, fireX = 500, fireY = 470;
    const ORBIT = 80000;            // ms per turn
    let pinned = null, orbit = 0;

    const ringStones = STONES.map(([label, rule, line], i) => {
      const font = 30;
      const w = label.length * font * .62 + 84, h = 96 + rand(i + 3, 2) * 12;
      const holder = document.createElementNS(NS, "g");
      holder.setAttribute("data-stone-holder", "");
      const st = { holder, label, rule, line, i, x: 0, y: 0, depth: 0, ...stone(holder, { w, h, seed: i + 2, label, font }) };
      st.g = st.g;
      const hold = () => { pinned = st; st.g.classList.add("hit"); showTip(st, true); };
      const release = () => { if (pinned === st) pinned = null; st.g.classList.remove("hit"); hideTip(); };
      holder.addEventListener("mouseenter", hold);
      holder.addEventListener("mouseleave", release);
      rules?.insertAdjacentHTML("beforeend", `<li>${label}: ${line}</li>`);
      return st;
    });

    function placeStones() {
      ringStones.forEach((st) => {
        const a = -Math.PI / 2 + (st.i + .5) / ringStones.length * Math.PI * 2 + orbit;
        st.x = cx + Math.cos(a) * rx; st.y = cy + Math.sin(a) * ry;
        st.depth = (Math.sin(a) + 1) / 2;
        const s = .66 + st.depth * .46;
        st.holder.setAttribute("transform", `translate(${st.x.toFixed(1)} ${st.y.toFixed(1)}) scale(${s.toFixed(3)})`);
        st.holder.style.opacity = (.55 + st.depth * .45).toFixed(2);
        light(st, (fireX - st.x) / s, (fireY - st.y) / s);
      });
      // Far stones sit behind the flames, near ones in front; each layer drawn back to front.
      const sorted = ringStones.slice().sort((a, b) => a.depth - b.depth);
      sorted.forEach((st) => {
        const layer = st.depth < .42 ? svgBack : svg;
        if (st.holder.parentNode !== layer || layer.lastChild !== st.holder) layer.appendChild(st.holder);
      });
    }
    placeStones();

    let tipTimer;
    function showTip(st, sticky) {
      tip.innerHTML = `<b>${st.rule}</b>${st.line}`;
      tip.classList.add("show");
      clearTimeout(tipTimer);
      if (!sticky) tipTimer = setTimeout(hideTip, 3600);
    }
    function hideTip() { tip.classList.remove("show"); }

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

    const FLAME = 1.4;   // flame size relative to the logs' original scale
    function spawnFlame() {
      // tongues: particles born on a few wandering columns; hotter in the middle
      const column = (Math.random() * 7 | 0) - 3;
      const centre = 1 - Math.abs(column) / 4;
      const F = FLAME;
      flames.push({ x: fx() + (column * W * .012 + (Math.random() - .5) * W * .014) * F, y: fy() - H * .005,
        vx: (-column * .05 + (Math.random() - .5) * .2) * F, vy: -(1.3 + Math.random() * 1.6) * (.8 + centre * .4) * F, life: 0,
        max: 30 + Math.random() * 36 * (.6 + centre * .6), r: W * (0.009 + Math.random() * 0.014) * (.8 + centre * .4) * F,
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
      if (!pinned) orbit += Math.PI * 2 / (ORBIT / (1000 / 60));
      flick += ((0.75 + Math.random() * .5) - flick) * .14;
      for (let i = 0; i < 10; i++) spawnFlame();
      if (step % 4 === 0) smoke.push({ x: fx() + (Math.random() - .5) * W * .04, y: fy() - H * .22, vx: (Math.random() - .5) * .3, vy: -(.45 + Math.random() * .45), life: 0, max: 170, r: W * .03 });
      if (step % 10 === 0) spawnSpark(null);
      if (simTime > nextHit) {
        nextHit = simTime + 5000 + Math.random() * 2000;
        const visibleStones = ringStones.filter((st) => st.depth > .45);
        if (!pinned && visibleStones.length) spawnSpark(visibleStones[(Math.random() * visibleStones.length) | 0]);
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
          if (dx * dx + dy * dy < (34 * k) ** 2 || s.life > 120) {
            dead = true;
            const tg = s.target.g;
            tg.classList.remove("hit"); void tg.getBBox(); tg.classList.add("hit");
            setTimeout(() => { if (pinned?.g !== tg) tg.classList.remove("hit"); }, 900);
            if (!pinned) showTip(s.target, false);
            // blocked: the spark breaks on the stone and bounces back towards the fire
            const bx = fx() - s.x, by = fy() - s.y, bl = Math.hypot(bx, by) || 1;
            for (let j = 0; j < 9; j++) {
              const sp = .8 + Math.random() * 1.8;
              sparks.push({ x: s.x, y: s.y, vx: bx / bl * sp + (Math.random() - .5) * 1.6, vy: by / bl * sp - Math.random() * 1.2,
                            g: .05, life: 0, max: 20 + Math.random() * 16, target: null, ember: true });
            }
          }
        }
        if (dead) sparks.splice(i, 1);
      }
    }

    function render() {
      if (!reduce) placeStones();
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

      // the fire itself is drawn larger around its base point
      const LS = 1.2;
      ctx.save();
      ctx.translate(fx(), fy()); ctx.scale(LS, LS); ctx.translate(-fx(), -fy());
      drawBed(simTime);
      drawLogs(simTime);
      ctx.restore();
      ctx.save();

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
      const core = bctx.createRadialGradient(fx(), fy() - H * .04, 0, fx(), fy() - H * .04, W * .07);
      core.addColorStop(0, `rgba(255,226,170,${(.13 * flick).toFixed(3)})`); core.addColorStop(1, "rgba(255,170,60,0)");
      bctx.fillStyle = core; bctx.beginPath(); bctx.ellipse(fx(), fy() - H * .04, W * .07, W * .1, 0, 0, Math.PI * 2); bctx.fill();
      bctx.globalCompositeOperation = "source-over";

      ctx.globalCompositeOperation = "lighter";
      ctx.save();
      ctx.filter = `blur(${Math.max(4, W * .014).toFixed(1)}px)`;
      ctx.globalAlpha = .7; ctx.drawImage(buf, 0, 0, W, H);
      ctx.filter = "none"; ctx.globalAlpha = 1; ctx.drawImage(buf, 0, 0, W, H);
      ctx.restore();
      ctx.restore();
      ctx.globalCompositeOperation = "lighter";

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

  }

  /* ---------- three strokes ignite in order ---------- */
  const strokes = [...document.querySelectorAll("[data-strokes] li")];
  if (reduce) strokes.forEach((li) => li.classList.add("on"));
  else new IntersectionObserver((entries, obs) => {
    if (!entries.some((e) => e.isIntersecting)) return;
    strokes.forEach((li, i) => setTimeout(() => li.classList.add("on"), 250 + i * 750));
    obs.disconnect();
  }, { threshold: .4 }).observe(document.querySelector("[data-strokes]"));

  /* ---------- sections rise into view ---------- */
  if (!reduce && "IntersectionObserver" in window) {
    root.classList.add("js-reveal");
    const items = document.querySelectorAll("main section > :not(.ember-light):not(.firelight):not(.spec-duo), .spec-duo > .shot");
    const io = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    }), { rootMargin: "0px 0px -8% 0px" });
    items.forEach((el) => { if (!el.closest(".hero")) { el.classList.add("reveal"); io.observe(el); } });
  }

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
