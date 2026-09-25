// Scenes of the omajot video. render(t) is pure: the same t gives the same
// frame. Cut and caption times come from window.CUT (video/tracks/*.json);
// footage frame counts, the QR text and the measured numbers from window.DATA.
const C = window.CUT, S = C.scenes, D = window.DATA
const $ = (sel, root = document) => root.querySelector(sel)
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x))
const ease = (x) => 1 - Math.pow(1 - clamp(x), 3)
const pending = []

function setSrc(img, src) {
  if (img.dataset.src === src) return
  img.dataset.src = src
  img.src = src
  pending.push(img.decode().catch(() => {}))
}
// Last index i with times[i] <= t (or -1).
const hit = (times, t) => { let i = -1; times.forEach((x, k) => { if (t >= x) i = k }); return i }
function pop(el, t, t0, dur = 0.28, dy = 26) {
  const k = ease((t - t0) / dur)
  el.style.opacity = t < t0 ? 0 : k
  el.style.transform = `translateY(${(1 - k) * dy}px)`
}
function caption(el, times, texts, t) {
  const i = Math.min(hit(times, t), texts.length - 1)
  if (i < 0) { el.style.opacity = 0; return }
  const [big, small] = [].concat(texts[i])
  const html = big + (small ? `<small>${small}</small>` : '')
  if (el.innerHTML !== html) el.innerHTML = html
  pop(el, t, times[i], 0.25, 18)
}
function sceneScale(el, t, t0) {
  const k = ease((t - t0) / 0.35)
  el.style.transform = `scale(${1.025 - 0.025 * k})`
}

// --- scene ranges ------------------------------------------------------------
const phoneEnd = S.private.start
const ranges = [
  ['hook', 0, S.web.start], ['web', S.web.start, S.omarchy.start], ['omarchy', S.omarchy.start, S.phone.start],
  ['qr', S.phone.qr, S.phone.iphone], ['iphone', S.phone.iphone, phoneEnd], ['private', S.private.start, S.cli.start],
  ['cli', S.cli.start, S.nerdcard.start], ['nerdcard', S.nerdcard.start, S.nerd.start], ['nerd', S.nerd.start, S.outro.start],
  ['outro', S.outro.start, C.duration + 1],
]

// --- scenes ------------------------------------------------------------------
const draw = {
  hook(t, t0) {
    const el = $('#hook')
    const logo = $('.logo', el), k = ease((t - 0.3) / 0.9)
    logo.style.opacity = k; logo.style.transform = `scale(${0.85 + 0.15 * k})`
    pop($('.word', el), t, 0.9, 0.5)
    pop($('.title', el), t, S.hook.title, 0.3, 40)
    pop($('.sub', el), t, S.hook.sub, 0.3, 40)
  },
  web(t, t0, t1) {
    const el = $('#web'), w = $('.window', el)
    const idx = Math.min(D.webFrames - 1, Math.floor((t - t0) / (t1 - t0) * D.webFrames))
    setSrc($('img', w), `cache/web/${String(idx).padStart(5, '0')}.jpg`)
    w.style.transform = `scale(${1 + 0.025 * ((t - t0) / (t1 - t0))})`
    caption($('.cap', el), S.web.captions, [
      'A markdown notes app.', 'Pictures, tables and checklists.', 'Type a note. It syncs.', ['Tags come from your text.', 'Type #lisbon, and the tag is there.'],
    ], t)
  },
  omarchy(t, t0, t1) {
    const el = $('#omarchy'), w = $('.window', el)
    const second = t >= S.omarchy.captions[1]
    setSrc($('img', w), `../site/assets/shots/${second ? 'plugin-window' : 'plugin-dropdown'}-dark.webp`)
    const s0 = second ? S.omarchy.captions[1] : t0, s1 = second ? t1 : S.omarchy.captions[1]
    w.style.transform = `scale(${1 + 0.04 * clamp((t - s0) / (s1 - s0))})`
    caption($('.cap', el), S.omarchy.captions, [['In your Omarchy bar.', 'Click the note icon. Your notes open at once.'], ['Or in its own window.', 'The same notes. The same keys.']], t)
  },
  qr(t, t0, t1) {
    const el = $('#qr'), w = $('.window', el), img = $('img', w)
    const k = ease((t - t0 - 0.3) / Math.max(0.5, t1 - t0 - 0.5))
    // Zoom from the whole web app into its QR code (centre of the overlay).
    img.style.transformOrigin = `${D.qrFocus[0]}% ${D.qrFocus[1]}%`
    img.style.transform = `scale(${1 + 0.9 * k})`
    caption($('.cap', el), [S.phone.qr], [['Your phone? Scan the code.', 'No typing. No account.']], t)
  },
  iphone(t, t0, t1) {
    const el = $('#iphone'), segs = S.phone.segments
    let i = hit(segs.map((s) => s[0]), t); if (i < 0) i = 0
    const [s0, a, b] = segs[i], s1 = i + 1 < segs.length ? segs[i + 1][0] : t1
    const idx = Math.min(D.iosFrames - 1, Math.round(a + clamp((t - s0) / (s1 - s0)) * (b - a)))
    setSrc($('.phone img', el), `cache/ios/${String(idx + 1).padStart(5, '0')}.jpg`)
    const texts = [['Add it to your home screen.', 'It installs like an app.'], ['Your notes, also offline.', 'Pictures, tables and checklists.'], ['Pull down to sync.', 'Changes arrive in a second.']]
    const [big, small] = texts[i]
    const side = $('.side', el)
    if ($('.big', side).textContent !== big) { $('.big', side).textContent = big; $('.small', side).textContent = small }
    pop(side, t, s0, 0.25, 22)
    const phone = $('.phone', el), k = ease((t - t0) / 0.45)
    phone.style.transform = `translateY(${(1 - k) * 80}px)`; phone.style.opacity = k
  },
  private(t, t0, t1) {
    const el = $('#private'), svg = $('svg', el)
    if (!svg.dataset.built) { svg.innerHTML = privateSvg(); svg.dataset.built = 1 }
    const caps = S.private.captions
    const c1 = caps[1] ?? t0 + 2, c2 = caps[2] ?? t0 + 4
    svg.querySelectorAll('.dev').forEach((g, i) => { g.style.opacity = ease((t - t0 - 0.1 * i) / 0.4) })
    $('.hub', svg).style.opacity = ease((t - t0 - 0.2) / 0.4)
    svg.querySelectorAll('.link').forEach((p, i) => {
      const k = ease((t - c1 - 0.08 * i) / 0.5)
      p.style.strokeDashoffset = 700 * (1 - k)
      p.style.opacity = k > 0 ? 1 : 0
    })
    svg.querySelectorAll('.packet').forEach((c, i) => {
      const on = t >= c1 + 0.5
      c.style.opacity = on ? 1 : 0
      if (on) { const u = ((t - c1) * 0.9 + i * 0.25) % 1; c.setAttribute('cx', c.dataset.x0 * (1 - u) + c.dataset.x1 * u); c.setAttribute('cy', c.dataset.y0 * (1 - u) + c.dataset.y1 * u) }
    })
    $('.tunnel', svg).style.opacity = ease((t - c1 - 0.3) / 0.4)
    $('.nocloud', svg).style.opacity = ease((t - c2) / 0.3)
    caption($('.cap', el), caps, [['Private by design.', 'Your notes stay on your own devices.'], ['Your own hub. Your own tailnet.', 'Devices talk over Tailscale (WireGuard).'], ['No cloud. No account.', 'Tailscale is free for personal use.']], t)
  },
  cli(t, t0, t1) {
    const el = $('#cli'), body = $('.term .body', el)
    const cmd = 'omajot qr', typeStart = S.cli.type + 0.35, per = C.beat_s / 4
    const n = clamp(Math.floor((t - typeStart) / per), 0, cmd.length)
    const printed = t >= S.cli.print
    const blink = Math.floor(t / (C.beat_s)) % 2 === 0
    let html = `<span class="prompt">~ $ </span><span class="cmd">${cmd.slice(0, n)}</span>`
    if (!printed) html += blink || n < cmd.length ? '<span class="cursor"></span>' : ''
    else {
      const rows = D.qr.length, shown = Math.min(rows, Math.floor((t - S.cli.print) / 0.3 * rows))
      html += `\n\n<span class="out">Open omajot on your phone:</span>\n  ${D.url}\n\n`
      html += `<div class="qr">${D.qr.slice(0, shown).join('\n')}</div>`
      if (shown === rows) html += `<span class="out">${D.footer}</span>\n\n<span class="prompt">~ $ </span>` + (blink ? '<span class="cursor"></span>' : '')
    }
    if (body.innerHTML !== html) body.innerHTML = html
    const caps = S.cli.captions
    const texts = [['And a CLI.', 'omajot runs in any terminal.'], ['omajot qr', 'Your hub URL as a QR code.'], ['The hub prints it, too.', 'Scan it right from the terminal.']]
    const i = Math.min(hit(caps, t), texts.length - 1)
    const side = $('.side', el)
    if (i >= 0) {
      if ($('.big', side).textContent !== texts[i][0]) { $('.big', side).textContent = texts[i][0]; $('.small', side).textContent = texts[i][1] }
      pop(side, t, caps[i], 0.25, 22)
    }
  },
  nerdcard(t, t0) {
    const h = $('#nerdcard .h')
    // A neon tube coming on: a few flickers, then steady.
    const d = t - t0
    const on = d > 0.34 || [0.02, 0.07, 0.15, 0.19, 0.27].some((x) => d >= x && d < x + 0.035)
    h.style.opacity = on ? 1 : 0.12
    h.style.transform = `scale(${1.04 - 0.04 * ease(d / 0.5)})`
  },
  nerd(t, t0) {
    const items = S.nerd.items, i = Math.max(0, hit(items, t))
    const cards = [
      ['100% Zig', 'Hub, daemon, CRDT sync and QR codes: all Zig.', []],
      ['baz + bounded/http', 'A Zig web framework on a Zig HTTP engine.', ['io_uring', 'kqueue', 'IOCP']],
      ['Allocates at startup.<br>Never grows under load.', 'Backpressure, not out-of-memory.',
        [`${D.hub.connections} connections`, `${D.hub.workers} workers`, `${D.hub.maxBody} per request`, `${D.hub.budget} memory budget`]],
      ['Zig → wasm', 'The same core runs in your browser and on your phone.', [`core.wasm: ${D.wasmKB} KB`]],
      ['One static binary.<br>No libc.', `~${D.binMin}–${D.binMax} MB`, ['Linux', 'macOS', 'Windows']],
      ['Conflict-free sync', 'CRDT: every device gets the same result, in any order.', [D.tests]],
    ]
    const [h, s, chips] = cards[Math.min(i, cards.length - 1)]
    const card = $('#nerd .card')
    const hh = $('.h', card)
    if (hh.innerHTML !== h) {
      hh.innerHTML = h; hh.classList.toggle('long', h.includes('<br>'))
      $('.s', card).textContent = s
      $('.chips', card).innerHTML = chips.map((c) => `<span class="mono">${c}</span>`).join('')
    }
    const k = ease((t - items[Math.min(i, items.length - 1)]) / 0.22)
    card.style.opacity = k; card.style.transform = `scale(${0.95 + 0.05 * k})`
  },
  outro(t, t0) {
    const el = $('#outro'), b = C.beat_s
    pop($('.logo', el), t, t0, 0.3, 30)
    pop($('.word', el), t, t0 + 0.1, 0.3, 30)
    pop($('.tag', el), t, t0 + b * 2, 0.3)
    pop($('.urls', el), t, t0 + b * 4, 0.3)
  },
}

function privateSvg() {
  const hub = [960, 470]
  const devs = [['laptop', 360, 260, 'Omarchy laptop'], ['browser', 360, 700, 'Any browser'], ['phone', 1560, 260, 'iPhone'], ['tablet', 1560, 700, 'iPad']]
  const icon = (kind, x, y) => ({
    laptop: `<rect x="${x - 70}" y="${y - 50}" width="140" height="90" rx="8"/><path d="M${x - 95} ${y + 52}h190"/>`,
    browser: `<rect x="${x - 80}" y="${y - 55}" width="160" height="110" rx="10"/><path d="M${x - 80} ${y - 30}h160"/><circle cx="${x - 64}" cy="${y - 43}" r="4"/>`,
    phone: `<rect x="${x - 34}" y="${y - 62}" width="68" height="124" rx="14"/><path d="M${x - 10} ${y - 50}h20"/>`,
    tablet: `<rect x="${x - 62}" y="${y - 70}" width="124" height="140" rx="12"/>`,
  })[kind]
  let s = `<g fill="none" stroke="#35e1ff" stroke-width="4" style="filter: drop-shadow(0 0 10px rgba(53,225,255,.7))">`
  const links = [], packets = []
  for (const [kind, x, y, label] of devs) {
    s += `<g class="dev" style="opacity:0">${icon(kind, x, y)}<text class="label" x="${x}" y="${y + 115}" text-anchor="middle" stroke="none">${label}</text></g>`
    const x0 = x < hub[0] ? x + 100 : x - 100, x1 = x < hub[0] ? hub[0] - 190 : hub[0] + 190
    links.push(`<path class="link" d="M${x0} ${y} L${x1} ${hub[1]}" stroke="#ffd60a" stroke-dasharray="700" stroke-dashoffset="700" style="opacity:0"/>`)
    packets.push(`<circle class="packet" r="7" fill="#ffd60a" stroke="none" data-x0="${x0}" data-y0="${y}" data-x1="${x1}" data-y1="${hub[1]}" style="opacity:0"/>`)
  }
  s += links.join('') + packets.join('')
  s += `<g class="hub" style="opacity:0"><rect x="${hub[0] - 190}" y="${hub[1] - 95}" width="380" height="190" rx="22" stroke="#ffd60a" style="filter: drop-shadow(0 0 16px rgba(255,214,10,.8))"/>
    <text class="label" x="${hub[0]}" y="${hub[1] - 12}" text-anchor="middle" stroke="none" style="font-size:44px;font-weight:900">Your hub</text>
    <text class="note" x="${hub[0]}" y="${hub[1] + 38}" text-anchor="middle" stroke="none">Mac · Linux · VPS</text></g>`
  s += `<g class="tunnel" style="opacity:0"><text class="note" x="${hub[0]}" y="190" text-anchor="middle" stroke="none" style="font-size:30px;fill:#35e1ff">🔒 Tailscale · WireGuard</text></g>`
  s += `<g class="nocloud" style="opacity:0"><text x="${hub[0]}" y="120" text-anchor="middle" stroke="none" style="font:900 56px 'Noto Sans';fill:#ff3fa4">✕ cloud</text></g>`
  return s + '</g>'
}

window.render = async function (t) {
  pending.length = 0
  for (const [name, t0, t1] of ranges) {
    const el = document.getElementById(name), on = t >= t0 && t < t1
    el.classList.toggle('on', on)
    if (on) { sceneScale(el, t, t0); draw[name](t, t0, t1) }
  }
  const fade = $('#fade')
  fade.style.opacity = clamp((t - S.outro.fade) / Math.max(0.1, C.duration - S.outro.fade))
  await Promise.all(pending)
}
