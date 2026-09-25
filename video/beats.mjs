// Beat and bar times of a music track, for cutting the video to it.
//
//   node video/beats.mjs <track> [out.json]
//
// Decodes the track with ffmpeg, builds an onset envelope of the kick band
// (< 150 Hz) and of the snare band (150 Hz–3 kHz), finds the tempo by
// autocorrelation (90–160 BPM), the beat phase, snaps each beat to its nearest
// kick onset and fits a straight line through them (constant tempo). The bar
// starts on the first strong beat; the snare band checks that beats 2 and 4
// of each bar carry the backbeat. Writes { bpm, beat, first, beats[], bars[],
// duration, backbeat } to JSON.
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'

const [track, out] = process.argv.slice(2)
if (!track) throw new Error('usage: node video/beats.mjs <track> [out.json]')
const SR = 11025, HOP = 128

function band(filter) {
  const raw = execFileSync('ffmpeg', ['-v', 'error', '-i', track, '-ac', '1', '-ar', String(SR), '-af', filter, '-f', 'f32le', '-'],
    { maxBuffer: 1 << 28 })
  const x = new Float32Array(raw.buffer, raw.byteOffset, raw.length / 4)
  const n = Math.floor(x.length / HOP)
  const env = new Float32Array(n)
  for (let i = 0; i < n; i++) {
    let s = 0
    for (let j = 0; j < HOP; j++) s += x[i * HOP + j] ** 2
    env[i] = Math.log(1e-9 + s / HOP)
  }
  const onset = new Float32Array(n)
  for (let i = 1; i < n; i++) onset[i] = Math.max(0, env[i] - env[i - 1])
  return { onset, n, samples: x.length }
}

const kick = band('lowpass=f=150,lowpass=f=150')
const snare = band('highpass=f=150,lowpass=f=3000')
const fps = SR / HOP
const duration = kick.samples / SR

// Tempo: autocorrelation of the kick onsets over 90–160 BPM.
let best = 0, bestLag = 0
const ac = (lag) => { let s = 0; for (let i = 0; i + lag < kick.n; i++) s += kick.onset[i] * kick.onset[i + lag]; return s }
for (let lag = Math.floor(fps * 60 / 160); lag <= Math.ceil(fps * 60 / 90); lag++) {
  const v = ac(lag)
  if (v > best) { best = v; bestLag = lag }
}
const a = ac(bestLag - 1), b = ac(bestLag), c = ac(bestLag + 1)
const lag = bestLag + 0.5 * (a - c) / (a - 2 * b + c)   // parabolic peak
const period = lag / fps                                // seconds per beat (first guess)

// Phase: the offset whose grid collects the most kick onset energy.
let bestPhase = 0, bestSum = -1
for (let p = 0; p < lag; p++) {
  let s = 0
  for (let k = 0; p + k * lag < kick.n; k++) s += kick.onset[Math.round(p + k * lag)] || 0
  if (s > bestSum) { bestSum = s; bestPhase = p }
}

// Snap every grid beat to the strongest kick onset within ±40 ms, then fit a line.
const win = Math.round(0.04 * fps)
const snapped = []
for (let k = 0; bestPhase + k * lag < kick.n; k++) {
  const c0 = Math.round(bestPhase + k * lag)
  let arg = c0, val = -1
  for (let i = Math.max(0, c0 - win); i <= Math.min(kick.n - 1, c0 + win); i++) if (kick.onset[i] > val) { val = kick.onset[i]; arg = i }
  if (val > 0.15) snapped.push([k, arg / fps])
}
const m = snapped.length
const sx = snapped.reduce((s, [k]) => s + k, 0), sy = snapped.reduce((s, [, t]) => s + t, 0)
const sxx = snapped.reduce((s, [k]) => s + k * k, 0), sxy = snapped.reduce((s, [k, t]) => s + k * t, 0)
const beat = (m * sxy - sx * sy) / (m * sxx - sx * sx)
const t0 = (sy - beat * sx) / m

// The first beat: the earliest grid beat with a clear kick (the track's first downbeat).
const firstStrong = snapped.find(([, t]) => t >= t0 - beat / 2)
let first = t0
while (first - beat > -beat * 0.25 && first - beat >= 0) first -= beat
if (firstStrong) first = t0 + Math.round((firstStrong[1] - t0) / beat) * beat
const beats = []
for (let t = first; t < duration - 0.05; t += beat) beats.push(+t.toFixed(4))
const bars = beats.filter((_, i) => i % 4 === 0)

// Backbeat check: mean snare onset per position in the bar (1..4).
const pos = [0, 0, 0, 0], cnt = [0, 0, 0, 0]
beats.forEach((t, i) => {
  const c0 = Math.round(t * fps)
  let v = 0
  for (let j = c0 - win; j <= c0 + win; j++) v = Math.max(v, snare.onset[j] || 0)
  pos[i % 4] += v; cnt[i % 4]++
})
const backbeat = pos.map((v, i) => +(v / cnt[i]).toFixed(3))

const result = { track: track.split('/').pop(), bpm: +(60 / beat).toFixed(3), beat: +beat.toFixed(5), first: +first.toFixed(4),
  duration: +duration.toFixed(3), backbeat, beats, bars }
if (out) writeFileSync(out, JSON.stringify(result, null, 1) + '\n')
console.log(`beats: ${result.bpm} BPM, beat ${result.beat} s, first downbeat ${result.first} s, ${bars.length} bars, ` +
  `duration ${result.duration} s, snare by bar position ${backbeat.join(' / ')}`)
