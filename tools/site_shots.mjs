// Screenshots of the web app for README.md and the site, from the sample notes.
//
//   zig build -Doptimize=ReleaseSafe
//   ./zig-out/bin/omajot hub --port 8791 --data /tmp/demo-hub --no-auth --web web/dist &
//   tools/seed_sample.py --data /tmp/demo-replica --hub http://127.0.0.1:8791
//   HUB=http://127.0.0.1:8791 node tools/site_shots.mjs
//
// Env: HUB (required), OUT (default site/assets/shots), CHROMIUM (default /usr/bin/chromium).
//
// Placeholder origin: the web app refuses to show a QR code for a loopback
// address (a phone cannot open it), and no public image may show 127.0.0.1.
// So this tool puts a small HTTPS proxy (self-signed cert, made with openssl)
// on 127.0.0.1:8443 in front of HUB, maps the docs host name to 127.0.0.1 in
// Chromium only, and opens https://your-mac.your-tailnet.ts.net:8443/. The
// page's own origin is then exactly the placeholder the docs use.
import { createRequire } from 'node:module'
import { mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { unlinkSync, readFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import https from 'node:https'
import http from 'node:http'

const require = createRequire(new URL('../web/package.json', import.meta.url))
const { default: puppeteer } = await import(require.resolve('puppeteer-core'))

const hub = process.env.HUB
if (!hub) throw new Error('set HUB, e.g. HUB=http://127.0.0.1:8791')
const out = process.env.OUT || new URL('../site/assets/shots', import.meta.url).pathname
await mkdir(out, { recursive: true })

// --- HTTPS proxy under the docs host name ----------------------------------
const docsHost = 'your-mac.your-tailnet.ts.net'
const docsPort = 8443
const docsOrigin = `https://${docsHost}:${docsPort}/`
const certDir = mkdtempSync(join(tmpdir(), 'omajot-shots-'))
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', `/CN=${docsHost}`,
  '-addext', `subjectAltName=DNS:${docsHost}`, '-keyout', join(certDir, 'key.pem'), '-out', join(certDir, 'cert.pem')], { stdio: 'ignore' })
const upstream = new URL(hub)
const proxy = https.createServer({ key: readFileSync(join(certDir, 'key.pem')), cert: readFileSync(join(certDir, 'cert.pem')) }, (req, res) => {
  const fwd = http.request({ host: upstream.hostname, port: upstream.port, path: req.url, method: req.method,
    headers: { ...req.headers, host: upstream.host } }, (up) => {
    res.writeHead(up.statusCode, up.headers)
    up.pipe(res) // streams SSE through as it arrives
  })
  fwd.on('error', () => { res.writeHead(502); res.end() })
  req.pipe(fwd)
})
await new Promise((resolve) => proxy.listen(docsPort, '127.0.0.1', resolve))

const browser = await puppeteer.launch({
  executablePath: process.env.CHROMIUM || '/usr/bin/chromium',
  headless: true,
  args: ['--no-first-run', '--font-render-hinting=none',
    `--host-resolver-rules=MAP ${docsHost} 127.0.0.1`, '--ignore-certificate-errors'],
})

const synced = (page) => page.waitForFunction(
  () => window.omajot?.state.sync?.state === 'online' && document.querySelectorAll('.nrow').length > 5,
  { timeout: 20000, polling: 100 })

async function open(theme, viewport) {
  const context = await browser.createBrowserContext()
  const page = await context.newPage()
  await page.setViewport(viewport)
  await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
  // The SSE doorbell keeps one request open, so the network is never idle.
  await page.goto(docsOrigin, { waitUntil: 'load' })
  await synced(page)
  return { context, page }
}

async function openNote(page, title) {
  await page.$$eval('.nrow', (rows, t) => rows.find(r => r.textContent.includes(t)).click(), title)
  await page.waitForFunction(t => document.querySelector('.cm-content')?.textContent.includes(t), {}, title)
}

async function mode(page, want, selector) {
  for (let i = 0; i < 4 && (await page.evaluate(() => document.querySelector('.app').dataset.mode)) !== want; i++)
    await page.click(selector)
}

async function settle(page) {
  await page.waitForNetworkIdle({ idleTime: 300, concurrency: 1, timeout: 5000 }).catch(() => {})
  await page.evaluate(() => Promise.all([...document.images].map(i => i.complete ? 0 : new Promise(r => { i.onload = i.onerror = r }))))
  await page.evaluate(() => document.fonts.ready)
  await new Promise(r => setTimeout(r, 250))
}

const shot = async (page, name) => {
  await settle(page)
  const png = join(out, name + '.png')
  await page.screenshot({ path: png })
  // WebP for the site: at most 1600 px wide.
  execFileSync('magick', [png, '-resize', '1600x>', '-quality', '86', join(out, name + '.webp')])
  unlinkSync(png)
  console.log('  ' + name)
}

for (const theme of ['light', 'dark']) {
  // Desktop: three columns, a note with an image, table and checklist.
  // The hero and README show the rendered note (preview only); the editor
  // section of the Using page shows source and preview side by side.
  const d = await open(theme, { width: 1440, height: 900, deviceScaleFactor: 2 })
  await openNote(d.page, 'Lisbon in October')
  await mode(d.page, 'preview', '.p-editor .actions [data-act="mode"]')
  await shot(d.page, `desktop-note-${theme}`)
  await mode(d.page, 'split', '.p-editor .actions [data-act="mode"]')
  await shot(d.page, `desktop-split-${theme}`)


  await d.page.click('.p-folders [data-act="phone"]')
  await d.page.waitForSelector('.qr-modal svg.qr-code')
  await shot(d.page, `desktop-qr-${theme}`)
  await d.page.keyboard.press('Escape')
  await d.context.close()

  // Phone shots come from the real iOS Simulator (iphone-*.webp, see site/assets/shots/README.md).
}

await browser.close()
// Open SSE streams would keep the proxy (and node) alive.
proxy.closeAllConnections()
proxy.close()
console.log('screenshots in', out)
process.exit(0)
