// The default soundtrack: dark synthwave / neon noir, synthesized in code
// (no samples, no downloads). 120 BPM (1 beat = 0.5 s, 1 bar = 2 s),
// 23 bars = 46 s, 48 kHz stereo 16-bit WAV.
//
//   node video/synth.mjs [out.wav]
//
// A minor, i–VI–III–VII (Am F C G), one chord per bar. Bars (1-based) follow
// the scenes in video/timeline.js:
//   1-2   intro: pad, filtered bass arpeggio, no drums
//   3-17  app, phone, private, CLI: kick, gated snare on 2 and 4, hats on
//         8ths; the bass filter opens slowly
//   18-21 nerd: cold lead, busier hats, filter wide open; noise riser in 21
//   22-23 outro: hard hit on bar 22's downbeat, dark tail
import { writeFileSync } from 'node:fs'

const SR = 48000, BPM = 120, BEAT = 60 / BPM, BAR = 4 * BEAT, BARS = 23
const LEN = Math.round(BARS * BAR * SR)
const L = new Float32Array(LEN), R = new Float32Array(LEN)

let seed = 0x2545f491
const rnd = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return ((seed >>> 0) / 4294967296) * 2 - 1 }
const hz = (m) => 440 * Math.pow(2, (m - 69) / 12)
const add = (i, l, r = l) => { if (i >= 0 && i < LEN) { L[i] += l; R[i] += r } }
const at = (t) => Math.round(t * SR)
const bar = (b) => (b - 1) * BAR

const CHORDS = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]] // Am F C G
const chordOf = (b) => CHORDS[(b - 1) % 4]

// Chamberlin state-variable low-pass (resonant), per voice.
function svf() {
  let low = 0, band = 0
  return (x, cutoff, q) => {
    const f = 2 * Math.sin(Math.PI * Math.min(cutoff, SR / 6) / SR)
    low += f * band
    const high = x - low - q * band
    band += f * high
    return low
  }
}
// PolyBLEP-free naive saw is fine at these levels with the low-pass after it.
const saw = (p) => 2 * (p % 1) - 1

// --- drums --------------------------------------------------------------------
function kick(t0, gain = 1) {
  const n = at(0.55)
  let ph = 0
  for (let i = 0; i < n; i++) {
    const t = i / SR
    ph += 2 * Math.PI * (38 + 95 * Math.exp(-t * 22)) / SR
    const env = Math.exp(-t * 5.5) * Math.min(1, t * 700)
    const click = i < 90 ? rnd() * 0.15 * (1 - i / 90) : 0
    add(at(t0) + i, (Math.sin(ph) * env + click) * gain)
  }
}
// Gated-reverb snare: a body tone and noise, a dense tail held flat, then cut.
function snare(t0, gain = 0.3) {
  const n = at(0.26)
  let prev = 0, tail = 0
  for (let i = 0; i < n; i++) {
    const t = i / SR
    const x = rnd(), hp = x - prev * 0.85; prev = x
    tail += 0.25 * (hp - tail)
    const body = Math.sin(2 * Math.PI * 185 * t) * Math.exp(-t * 30) * 0.6
    const gate = t < 0.2 ? 1 : Math.max(0, 1 - (t - 0.2) / 0.06)
    const env = (0.55 + 0.45 * Math.exp(-t * 25)) * gate
    add(at(t0) + i, (body + hp * 0.5 * env + tail * 0.7 * env) * gain,
                    (body + hp * 0.45 * env + tail * 0.75 * env) * gain)
  }
}
function hat(t0, gain = 0.07) {
  const n = at(0.05)
  let prev = 0
  for (let i = 0; i < n; i++) {
    const x = rnd(), hp = x - prev; prev = x
    add(at(t0) + i, hp * Math.exp(-(i / SR) * 90) * gain * 0.85, hp * Math.exp(-(i / SR) * 90) * gain)
  }
}

// --- bass: 16th-note arpeggio, two detuned saws through a resonant low-pass --
function bassBar(t0, ch, cutoff, gain = 0.2) {
  const root = ch[0] - 24
  const pattern = [0, 0, 12, 0, 7, 0, 12, 7, 0, 0, 12, 0, 10, 7, 12, 7]  // semitones over the root
  const step = BAR / 16
  const filt = svf()
  for (let k = 0; k < 16; k++) {
    const f = hz(root + pattern[k]), n = at(step)
    let p1 = 0, p2 = 0.37
    for (let i = 0; i < n; i++) {
      const t = i / SR
      p1 += f / SR; p2 += f * 1.006 / SR
      const env = Math.min(1, t * 300) * Math.exp(-t * 9)
      const fc = cutoff * (0.35 + 0.65 * Math.exp(-t * 14))       // a little pluck in the filter
      const y = filt((saw(p1) + saw(p2)) * 0.5, fc, 0.45)
      add(at(t0 + k * step) + i, y * env * gain)
    }
  }
}

// --- pad: detuned saws, slow attack, dark low-pass, wide ---------------------
function pad(t0, notes, dur, gain, cutoff) {
  const n = at(dur)
  const vs = []
  for (const m of notes) for (const d of [-0.14, 0.02, 0.13]) vs.push({ f: hz(m) * Math.pow(2, d / 12), p: Math.abs(rnd()), pan: 0.5 + d * 2.8 })
  const fl = svf(), fr = svf()
  for (let i = 0; i < n; i++) {
    const t = i / SR
    const env = Math.min(1, t / 0.9) * Math.min(1, (dur - t) / 0.6)
    let sl = 0, sr = 0
    for (const v of vs) { v.p += v.f / SR; const s = saw(v.p); sl += s * (1 - v.pan); sr += s * v.pan }
    add(at(t0) + i, fl(sl, cutoff, 0.9) * env * gain, fr(sr, cutoff, 0.9) * env * gain)
  }
}

// --- lead: cold square with slow vibrato and a dark echo --------------------
function lead(t0, midi, dur, gain = 0.07) {
  const n = at(dur), f0 = hz(midi)
  const filt = svf()
  let p = 0
  for (let i = 0; i < n; i++) {
    const t = i / SR
    const f = f0 * (1 + 0.004 * Math.sin(2 * Math.PI * 5.2 * t) * Math.min(1, t * 2))
    p += f / SR
    const sq = (p % 1) < 0.5 ? 1 : -1
    const env = Math.min(1, t * 40) * Math.min(1, (dur - t) * 12) * (0.8 + 0.2 * Math.exp(-t * 3))
    const y = filt(sq, 2600, 0.7) * env * gain
    const i0 = at(t0) + i
    add(i0, y * 0.9, y * 0.7)
    add(i0 + at(BEAT * 0.75), y * 0.25, y * 0.4)   // dotted-eighth echo, right-heavy
    add(i0 + at(BEAT * 1.5), y * 0.12, y * 0.08)
  }
}

// --- riser, final hit ----------------------------------------------------------
function riser(t0, dur, gain = 0.12) {
  const n = at(dur), filt = svf()
  for (let i = 0; i < n; i++) {
    const k = i / n
    const y = filt(rnd(), 200 + 6000 * k * k, 0.5) * k * k * gain
    add(at(t0) + i, y, y * 0.95)
  }
}
function darkTail(t0, gain = 0.1) {
  const n = at(3.5), filt = svf()
  for (let i = 0; i < n; i++) {
    const t = i / SR
    const y = filt(rnd(), 900 * Math.exp(-t * 0.8) + 120, 0.6) * Math.exp(-t * 1.3) * gain
    add(at(t0) + i, y, y)
  }
}

// --- arrangement ---------------------------------------------------------------
const OUTRO = bar(22)
for (let b = 1; b <= 21; b++) {
  const t0 = bar(b), ch = chordOf(b)
  // The bass filter opens from the intro to the nerd section.
  const open = Math.min(1, Math.max(0, (b - 1) / 18))
  bassBar(t0, ch, 280 + 1800 * open * open, b <= 2 ? 0.16 : 0.2)
  pad(t0, ch.map((m) => m - 12), BAR + 0.5, 0.045, 700 + 500 * open)
  if (b >= 3) {
    for (let k = 0; k < 4; k++) {
      kick(t0 + k * BEAT, 0.95)
      if (k % 2 === 1) snare(t0 + k * BEAT, 0.28)
      hat(t0 + k * BEAT + BEAT / 2, 0.07)
      if (b >= 18) { hat(t0 + k * BEAT + BEAT / 4, 0.035); hat(t0 + k * BEAT + 3 * BEAT / 4, 0.035) }
    }
  }
}
// Cold lead over the nerd section (bars 18-21): long notes on chord tones.
const LEAD = [[76, 1.5], [72, 0.5], [69, 2], [77, 1.5], [76, 0.5], [72, 2], [72, 1.5], [74, 0.5], [76, 2], [79, 1], [77, 1], [74, 2]]
let tl = bar(18)
for (const [m, beats] of LEAD) { if (tl >= bar(21) + BAR * 0.5) break; lead(tl, m, beats * BEAT * 0.95); tl += beats * BEAT }
riser(bar(21), BAR, 0.13)
// Hard final hit: kick, snare, a low A-minor chord, then the dark tail.
kick(OUTRO, 1.1)
snare(OUTRO, 0.34)
pad(OUTRO, [33, 45, 48, 52], 3.8, 0.07, 900)
darkTail(OUTRO, 0.09)

// Soft-clip gently, then normalize the peak to -1 dBFS (loudness is set in build.sh).
let peak = 0
for (let i = 0; i < LEN; i++) { L[i] = Math.tanh(L[i]); R[i] = Math.tanh(R[i]); peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i])) }
const norm = 0.891 / peak

const out = process.argv[2] || new URL('./cache/soundtrack.wav', import.meta.url).pathname
const buf = Buffer.alloc(44 + LEN * 4)
buf.write('RIFF', 0); buf.writeUInt32LE(36 + LEN * 4, 4); buf.write('WAVE', 8)
buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22)
buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34)
buf.write('data', 36); buf.writeUInt32LE(LEN * 4, 40)
for (let i = 0; i < LEN; i++) {
  buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, L[i] * norm)) * 32767), 44 + i * 4)
  buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, R[i] * norm)) * 32767), 46 + i * 4)
}
writeFileSync(out, buf)
console.log(`synth: ${out} (${(LEN / SR).toFixed(1)} s, ${BPM} BPM, dark synthwave)`)
