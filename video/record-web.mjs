// Records the web app for the video: a scripted session on the sample notes,
// captured as a JPEG sequence (one screenshot per frame, 30 fps pacing).
//
//   HUB=http://127.0.0.1:8792 OUT=video/cache/web node video/record-web.mjs
//
// The hub must hold the sample notes (tools/seed_sample.py). Dark theme, the
// app's own cool greys. Nothing here touches a real hub or the desktop.
import { createRequire } from 'node:module'
import { mkdir, rm } from 'node:fs/promises'
import { join } from 'node:path'

const require = createRequire(new URL('../web/package.json', import.meta.url))
const { default: puppeteer } = await import(require.resolve('puppeteer-core'))

const hub = process.env.HUB
if (!hub) throw new Error('set HUB')
const out = process.env.OUT || new URL('./cache/web', import.meta.url).pathname
await rm(out, { recursive: true, force: true })
await mkdir(out, { recursive: true })

const browser = await puppeteer.launch({
  executablePath: process.env.CHROMIUM || '/usr/bin/chromium',
  headless: true,
  args: ['--no-first-run', '--font-render-hinting=none', '--hide-scrollbars'],
})
const page = await browser.newPage()
await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 1.25 })
await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }])
await page.goto(hub, { waitUntil: 'load' })
await page.waitForFunction(() => window.omajot?.state.sync?.state === 'online' && document.querySelectorAll('.nrow').length > 5,
  { timeout: 20000, polling: 100 })
await page.evaluate(() => document.fonts.ready)

let n = 0
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
// One frame = one screenshot; `frames(k)` holds the current state for k frames
// (each capture takes real time, so CSS transitions play out naturally).
async function frame() {
  await page.screenshot({ path: join(out, String(n++).padStart(5, '0') + '.jpg'), type: 'jpeg', quality: 88 })
}
async function frames(k) { for (let i = 0; i < k; i++) { await frame(); await sleep(15) } }
const clickNote = (t) => page.$$eval('.nrow', (rows, t) => rows.find(r => r.textContent.includes(t)).click(), t)
async function mode(want) {
  for (let i = 0; i < 4 && (await page.evaluate(() => document.querySelector('.app').dataset.mode)) !== want; i++) {
    await page.click('.p-editor .actions [data-act="mode"]')
    await sleep(120)
  }
}

// 1. The Lisbon note, rendered: picture, table, checklist.
await clickNote('Lisbon in October')
await page.waitForFunction(() => document.querySelector('.cm-content')?.textContent.includes('Lisbon'))
await mode('preview')
await sleep(400)
await frames(60)

// 2. Groceries: tick an open item in the preview.
await clickNote('Groceries')
await page.waitForFunction(() => document.querySelector('.cm-content')?.textContent.includes('Groceries'))
await mode('preview')
await sleep(300)
await frames(24)
const box = await page.$('.preview input.task:not(:checked)')
if (box) { await box.click(); await sleep(60) }
await frames(30)

// 3. A new note, typed: it appears in the list as you type.
await page.click('.p-list [data-act="new-note"]')
await page.waitForSelector('.cm-content')
await mode('split')
await page.click('.cm-content')
await page.waitForSelector('.cm-content:focus')
await frames(6)
for (const ch of 'Tram 28 tickets\n- [ ] buy a Viva Viagem card #lisbon') {
  if (ch === '\n') await page.keyboard.press('Enter'); else await page.keyboard.type(ch)
  await frame()
}
await frames(40)

console.log(`web: ${n} frames in ${out}`)
await browser.close()
