// Renders video/timeline.html frame by frame into video/cache/frames/*.jpg.
//
//   CUT=video/tracks/neon-drive.json FPS=30 node video/render.mjs
//
// Every number shown in the video is read here from the code or measured:
// hub limits from src/hub, the core.wasm size from web/dist, the release
// binary sizes from cache/release.json (written by build.sh with `gh`), the
// convergence test parameters from src/core/engine_test.zig, and the QR code
// text from the real `omajot qr` output (cache/qr.txt).
import { createRequire } from 'node:module'
import { readFileSync, readdirSync, statSync, mkdirSync, rmSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const here = new URL('.', import.meta.url).pathname
const repo = join(here, '..')
const require = createRequire(join(repo, 'web/package.json'))
const { default: puppeteer } = await import(require.resolve('puppeteer-core'))

const cut = JSON.parse(readFileSync(process.env.CUT || join(here, 'tracks/neon-drive.json'), 'utf8'))
const fps = Number(process.env.FPS || 30)
const out = join(here, 'cache/frames')
rmSync(out, { recursive: true, force: true })
mkdirSync(out, { recursive: true })

const src = (p) => readFileSync(join(repo, p), 'utf8')
const num = (text, re) => { const m = text.match(re); if (!m) throw new Error('not found: ' + re); return m[1] }
const hub = src('src/hub/hub.zig'), store = src('src/hub/store.zig'), tests = src('src/core/engine_test.zig')
const mib = (expr) => { const m = expr.match(/(\d+)\s*<<\s*20/); return m ? `${m[1]} MiB` : expr }

// QR code text from `omajot qr` (ANSI stripped): the code lines, the URL line and the footer.
const raw = readFileSync(join(here, 'cache/qr.txt'), 'utf8').split('\n')
const strip = (l) => l.replace(/\x1b\[[0-9;]*m/g, '')
const qr = raw.filter((l) => l.includes('\x1b[30;107m')).map(strip)
const url = strip(raw.find((l) => l.trim().startsWith('https://'))).trim()
const footer = strip(raw.filter((l) => l.trim()).pop()).trim()

const release = JSON.parse(readFileSync(join(here, 'cache/release.json'), 'utf8'))
const sizes = release.assets.filter((a) => a.name.startsWith('omajot-')).map((a) => a.size / 1e6)

const DATA = {
  webFrames: readdirSync(join(here, 'cache/web')).length,
  iosFrames: readdirSync(join(here, 'cache/ios')).length,
  qr, url, footer,
  qrFocus: [50, 42],
  hub: {
    connections: num(hub, /pub const connections = (\d+);/),
    workers: num(hub, /pub const workers = (\d+);/),
    maxBody: mib(num(store, /pub const max_batch_bytes: usize = ([^;]+);/)),
    budget: mib(num(hub, /\.memory_budget_bytes = ([^,]+),/)),
  },
  wasmKB: Math.round(statSync(join(repo, 'web/dist/core.wasm')).size / 1000),
  binMin: Math.min(...sizes).toFixed(1), binMax: Math.max(...sizes).toFixed(1),
  tests: `${num(tests, /const replicas = (\d+);/)} replicas × ${num(tests, /const steps = (\d+);/)} random steps × ${num(tests, /const seeds = (\d+);/)} seeds converge in the tests`,
}
console.log('render: data', JSON.stringify({ ...DATA, qr: `${qr.length} lines` }))

const browser = await puppeteer.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium', headless: true,
  args: ['--no-first-run', '--allow-file-access-from-files', '--font-render-hinting=none', '--hide-scrollbars'] })
const page = await browser.newPage()
await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 })
await page.evaluateOnNewDocument((c, d) => { window.CUT = c; window.DATA = d }, cut, DATA)
await page.goto('file://' + join(here, 'timeline.html'), { waitUntil: 'load' })
await page.evaluate(() => document.fonts.ready)

const frames = Math.ceil(cut.duration * fps)
const t0 = Date.now()
for (let i = 0; i < frames; i++) {
  await page.evaluate((t) => window.render(t), i / fps)
  await page.screenshot({ path: join(out, String(i).padStart(5, '0') + '.jpg'), type: 'jpeg', quality: 92 })
  if (i % 300 === 0) console.log(`render: frame ${i}/${frames} (${((Date.now() - t0) / 1000).toFixed(0)} s)`)
}
await browser.close()
console.log(`render: ${frames} frames at ${fps} fps in ${out}`)
