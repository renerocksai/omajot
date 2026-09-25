// Browser end-to-end test against the real hub: two isolated Chromium
// profiles (desktop + phone-sized) sync notes, patches, pasted images and
// HTML, checkboxes and undo; then the hub is stopped and the phone reloads
// offline from the service worker.
//
//   zig build && zig build wasm && npm run build && npm run e2e
//
// Env: CHROMIUM (default /usr/bin/chromium), SHOTS (screenshot dir, default
// ./test/shots), HEADFUL=1 to watch.
import puppeteer from 'puppeteer-core'
import { spawn } from 'node:child_process'
import { mkdtemp, mkdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import assert from 'node:assert/strict'

const root = new URL('../..', import.meta.url).pathname
const port = 8700 + Math.floor(Math.random() * 200)
const base = `http://127.0.0.1:${port}/`
const shots = process.env.SHOTS || new URL('./shots', import.meta.url).pathname
await mkdir(shots, { recursive: true })
const data = await mkdtemp(join(tmpdir(), 'omajot-e2e-'))

let hub
function startHub() {
  hub = spawn(join(root, 'zig-out/bin/omajot'), ['hub', '--port', String(port), '--data', data, '--no-auth', '--web', join(root, 'web/dist')],
    { stdio: ['ignore', 'pipe', 'pipe'] })
  return new Promise((resolve, reject) => {
    const onData = (d) => { if (String(d).includes('READY')) resolve() }
    hub.stdout.on('data', onData)
    hub.stderr.on('data', onData)
    hub.on('exit', (code) => reject(new Error('hub exited ' + code)))
  })
}
function stopHub() {
  if (!hub || hub.exitCode !== null) return Promise.resolve()
  hub.removeAllListeners('exit')
  const exited = new Promise(r => hub.once('exit', r))
  hub.kill('SIGTERM')
  return exited
}

const t0 = Date.now()
let watchdog = null
const step = (name) => {
  console.log(`• [${((Date.now() - t0) / 1000).toFixed(1)}s] ${name}`)
  clearTimeout(watchdog)
  watchdog = setTimeout(async () => {
    console.error('WATCHDOG: step stalled for 45 s:', name)
    for (const [n, page] of Object.entries(pages)) {
      const info = await Promise.race([page.evaluate(() => ({ view: document.querySelector('.app')?.dataset.view,
        sync: window.omajot?.state.sync, sw: !!navigator.serviceWorker.controller, ready: document.readyState })),
        new Promise(r => setTimeout(() => r('evaluate timed out'), 3000))]).catch(e => String(e))
      console.error('  ', n, JSON.stringify(info))
    }
  }, 45000)
  watchdog.unref()
}
const wait = (page, fn, arg, timeout = 8000) => page.waitForFunction(fn, { timeout, polling: 50 }, arg)
const settled = (page) => wait(page, () => window.omajot?.replica.pendingOps.length === 0 && window.omajot.state.sync?.pending === 0 && window.omajot.state.sync.state === 'online')
const docText = () => window.omajot.editor.view.state.doc.toString()
const editorText = (page) => page.evaluate(docText)
// Views slide in over 300 ms; tap only once they have arrived, as a person would.
const view = async (page, v) => { await wait(page, (x) => document.querySelector('.app').dataset.view === x, v); await new Promise(r => setTimeout(r, 350)) }
const shot = (page, name) => page.screenshot({ path: join(shots, name + '.png') })

const pages = {}
await startHub()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROMIUM || '/usr/bin/chromium',
  headless: !process.env.HEADFUL,
  args: ['--no-first-run', '--no-default-browser-check'],
})
try {
  const desktop = await (await browser.createBrowserContext()).newPage()
  await desktop.setViewport({ width: 1280, height: 800 })
  const phone = await (await browser.createBrowserContext()).newPage()
  await phone.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  for (const p of [desktop, phone]) p.on('pageerror', e => console.error('pageerror:', e.message))
  Object.assign(pages, { desktop, phone })

  step('both devices load the app with core.wasm')
  await desktop.goto(base)
  await phone.goto(base)
  await wait(desktop, () => window.omajot?.replica.engine.kind === 'wasm')
  await wait(phone, () => window.omajot?.replica.engine.kind === 'wasm')

  step('desktop shows this address as a QR code; Esc closes it')
  await desktop.click('.p-folders [data-act="phone"]')
  await desktop.waitForSelector('.qr-modal svg.qr-code')
  const qr = await desktop.evaluate(() => {
    const svg = document.querySelector('.qr-modal svg.qr-code')
    const expected = window.omajot.replica.request('qr', { text: location.origin + '/' })
    const box = svg.getBoundingClientRect()
    return { modules: +svg.dataset.modules, viewBox: svg.getAttribute('viewBox'), size: expected.size,
      url: document.querySelector('.qr-url').textContent, origin: location.origin + '/', width: box.width, height: box.height,
      runs: (svg.querySelector('path').getAttribute('d').match(/M/g) || []).length }
  })
  assert.equal(qr.modules, qr.size)
  assert.ok(qr.size >= 21 && (qr.size - 17) % 4 === 0, `a real QR size (${qr.size})`)
  assert.equal(qr.viewBox, `0 0 ${qr.size + 8} ${qr.size + 8}`, 'N×N modules plus a 4-module quiet zone')
  assert.equal(qr.url, qr.origin)
  assert.ok(qr.runs > qr.size, 'dark modules drawn')
  assert.ok(qr.width >= 200 && Math.abs(qr.width - qr.height) < 1, `square and large enough (${qr.width}×${qr.height})`)
  await shot(desktop, 'desktop-qr')
  await desktop.keyboard.press('Escape')
  await wait(desktop, () => !document.querySelector('.modal-root.open'))

  step('desktop creates a note and types')
  await desktop.click('.p-list [data-act="new-note"]')
  await desktop.waitForSelector('.cm-content:focus')
  await desktop.keyboard.type('Shopping list\nmilk #groceries\n- [ ] eggs')
  await settled(desktop)
  assert.equal(await editorText(desktop), 'Shopping list\nmilk #groceries\n- [ ] eggs')
  const head = await desktop.evaluate(() => window.omajot.state.sync.head)
  assert.ok(head <= 4, `typing is coalesced into few batches (head ${head})`)

  step('phone sees it in the list and in the #groceries tag')
  await wait(phone, () => document.querySelector('.p-list .ntitle')?.textContent.includes('Shopping list'))
  await shot(phone, 'phone-list')
  await phone.click('.p-list .back')
  await view(phone, 'folders')
  assert.ok(await phone.$eval('.tags', el => el.textContent.includes('#groceries')))
  await new Promise(r => setTimeout(r, 400))
  await shot(phone, 'phone-folders')
  await phone.click('.p-folders [data-act="phone"]')
  await phone.waitForSelector('.qr-modal svg.qr-code')
  assert.ok(await phone.$eval('.qr-modal svg.qr-code', el => el.getBoundingClientRect().right <= innerWidth), 'fits the phone screen')
  await shot(phone, 'phone-qr')
  await phone.mouse.click(8, 8)
  await wait(phone, () => !document.querySelector('.modal-root.open'))
  await phone.$$eval('.chip', els => els.find(e => e.textContent.includes('#groceries')).click())
  await view(phone, 'list')

  step('phone opens the note; desktop appends; the phone receives the patch')
  await phone.click('.p-list .nrow')
  await view(phone, 'editor')
  await desktop.keyboard.type('\nbread') // Enter continues the checklist
  await wait(phone, () => window.omajot.editor.view.state.doc.toString().includes('bread'))

  step('concurrent edits on both devices converge')
  await phone.evaluate(() => { const v = window.omajot.editor.view; v.focus(); v.dispatch({ selection: { anchor: 0 } }) })
  await phone.keyboard.type('Weekly ')
  await desktop.keyboard.type('\ncoffee')
  await settled(desktop); await settled(phone)
  await wait(phone, () => window.omajot.editor.view.state.doc.toString().includes('coffee'))
  await wait(desktop, () => window.omajot.editor.view.state.doc.toString().startsWith('Weekly '))
  const merged = 'Weekly Shopping list\nmilk #groceries\n- [ ] eggs\n- [ ] bread\n- [ ] coffee'
  assert.equal(await editorText(desktop), merged)
  assert.equal(await editorText(phone), merged)

  step('undo on the phone reverts only the phone\'s own typing')
  await phone.keyboard.down('Control'); await phone.keyboard.press('z'); await phone.keyboard.up('Control')
  const afterUndo = await editorText(phone)
  assert.ok(!afterUndo.startsWith('Weekly'), 'own edit undone: ' + JSON.stringify(afterUndo))
  assert.ok(afterUndo.includes('coffee') && afterUndo.includes('bread'), 'remote edits kept')
  await settled(phone)
  await wait(desktop, () => window.omajot.editor.view.state.doc.toString().startsWith('Shopping'))
  await shot(phone, 'phone-editor')

  step('desktop pastes an image: stored, uploaded, previewed; the phone loads it from the hub')
  const png = await desktop.evaluate(async () => {
    const c = new OffscreenCanvas(64, 40)
    const g = c.getContext('2d')
    g.fillStyle = '#f5b400'; g.fillRect(0, 0, 64, 40); g.fillStyle = '#333'; g.fillRect(8, 8, 20, 20)
    const blob = await c.convertToBlob({ type: 'image/png' })
    const dt = new DataTransfer()
    dt.items.add(new File([blob], 'shot.png', { type: 'image/png' }))
    const v = window.omajot.editor.view
    v.dispatch({ selection: { anchor: v.state.doc.length } })
    v.contentDOM.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }))
    return blob.size
  })
  assert.ok(png > 0)
  await wait(desktop, () => /!\[shot\]\(attachments\/[0-9a-f]{64}\.png\)/.test(window.omajot.editor.view.state.doc.toString()))
  await settled(desktop)
  const name = /attachments\/([0-9a-f]{64}\.png)/.exec(await editorText(desktop))[1]
  assert.equal((await fetch(base + 'api/blobs/' + name)).status, 200)

  step('desktop pastes HTML (Chromium shape) and gets markdown')
  await desktop.evaluate(() => {
    const dt = new DataTransfer()
    dt.setData('text/html', '<p style="color:red">A <b>bold</b> <a href="https://example.com">link</a></p><ul><li><input type="checkbox" checked> done</li></ul>')
    dt.setData('text/plain', 'A bold link')
    const v = window.omajot.editor.view
    v.dispatch({ selection: { anchor: v.state.doc.length } })
    v.contentDOM.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }))
  })
  await wait(desktop, () => window.omajot.editor.view.state.doc.toString().includes('A **bold** [link](https://example.com)\n\n- [x] done'))
  assert.match(await editorText(desktop), /coffee\n\n!\[shot\]\(attachments\/[0-9a-f]{64}\.png\)\nA \*\*bold\*\*/, 'block pastes sit on their own lines')
  await wait(desktop, () => document.querySelector('.cm-content img.cm-image')?.naturalWidth === 64)

  step('split preview renders the image and a clickable checkbox that edits the source')
  await desktop.evaluate(() => { while (document.querySelector('.app').dataset.mode !== 'split') document.querySelector('.p-editor .actions [data-act="mode"]').click() })
  await wait(desktop, () => document.querySelector('.preview img')?.complete && document.querySelector('.preview img').naturalWidth === 64)
  await desktop.click('.preview input.task:not([checked])')
  await wait(desktop, () => window.omajot.editor.view.state.doc.toString().includes('- [x] eggs'))
  await settled(desktop)
  await shot(desktop, 'desktop-split')
  await wait(phone, () => window.omajot.editor.view.state.doc.toString().includes('- [x] eggs'))
  step('tapping a checkbox in the phone editor toggles it and syncs')
  await wait(phone, () => document.querySelectorAll('.cm-content .cm-task').length === 4)
  await phone.evaluate(() => {
    const box = [...document.querySelectorAll('.cm-content .cm-task')].find(b => b.closest('.cm-line').textContent.includes('bread'))
    box.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }))
  })
  await wait(phone, () => window.omajot.editor.view.state.doc.toString().includes('- [x] bread'))
  await wait(desktop, () => window.omajot.editor.view.state.doc.toString().includes('- [x] bread'))
  await phone.evaluate(() => document.querySelector('.toolbar [data-act="mode"]').click())
  await wait(phone, () => document.querySelector('.preview img')?.naturalWidth === 64)
  await shot(phone, 'phone-preview')

  step('folders: create, move the note, pin')
  await desktop.click('[data-act="new-folder"]')
  await desktop.waitForSelector('.modal-input')
  await desktop.keyboard.type('Household')
  await desktop.keyboard.press('Enter')
  await wait(desktop, () => document.querySelector('.list-title').textContent === 'Household')
  await desktop.click('.frow[data-src*="all"]')
  await wait(desktop, () => document.querySelector('.list-title').textContent === 'All Notes' && !!document.querySelector('.p-list .nrow'))
  await desktop.click('.p-list .nrow')
  await desktop.click('.p-editor [data-act="move"]')
  await desktop.waitForSelector('.modal-buttons button')
  await desktop.$$eval('.modal-buttons button', bs => bs.find(b => b.textContent.includes('Household')).click())
  await desktop.click('.p-editor [data-act="pin"]')
  await settled(desktop)
  await wait(phone, () => [...window.omajot.state.notes.values()].some(n => n.pinned && n.folder && window.omajot.state.folders.some(f => f.id === n.folder && f.name === 'Household')))
  await shot(desktop, 'desktop-three-columns')

  step('hub goes away: the phone reloads offline from the service worker')
  await phone.evaluate(() => navigator.serviceWorker.ready)
  await phone.reload()
  await wait(phone, () => !!navigator.serviceWorker.controller && window.omajot?.state.notes.size > 0)
  await stopHub()
  step('  hub stopped; reloading the phone')
  await phone.reload({ waitUntil: 'domcontentloaded' })
  step('  reloaded')
  await wait(phone, () => window.omajot?.state.notes.size > 0 && document.querySelector('.p-list .ntitle')?.textContent.includes('Shopping'))
  await wait(phone, () => window.omajot.state.sync?.state === 'offline', null, 15000)
  await phone.click('.p-list [data-act="new-note"]')
  await phone.waitForSelector('.cm-content:focus')
  await phone.keyboard.type('Written offline')
  await wait(phone, () => window.omajot.state.sync.pending > 0)
  await phone.evaluate(() => document.querySelector('.p-editor .back').click())
  await new Promise(r => setTimeout(r, 400))
  await shot(phone, 'phone-offline')

  step('hub is back: the offline note reaches the desktop')
  await startHub()
  await phone.evaluate(() => window.omajot.replica.sync.online())
  await wait(phone, () => window.omajot.state.sync.pending === 0, null, 20000)
  await wait(desktop, () => [...window.omajot.state.notes.values()].some(n => n.title === 'Written offline'), null, 40000)

  step('a second tab waits for the replica lock, can take over, and the first tab steps back')
  const tab2 = await desktop.browserContext().newPage()
  await tab2.setViewport({ width: 1280, height: 800 })
  await tab2.goto(base)
  await wait(tab2, () => document.querySelector('.blocker')?.textContent.includes('open in another tab'))
  assert.equal(await tab2.evaluate(() => !!window.omajot), false, 'no second instance started')
  await tab2.click('.blocker button')
  await wait(tab2, () => window.omajot?.state.notes.size > 0 && !document.querySelector('.blocker'))
  await wait(desktop, () => document.querySelector('.blocker')?.textContent.includes('now open in another'))
  await shot(tab2, 'desktop-second-tab')

  console.log('E2E PASS; screenshots in', shots)
} catch (e) {
  for (const [name, page] of Object.entries(pages)) {
    await shot(page, 'FAIL-' + name).catch(() => {})
    const info = await page.evaluate(() => ({
      view: document.querySelector('.app')?.dataset.view, current: window.omajot?.state.current,
      sync: window.omajot?.state.sync, text: window.omajot?.editor?.view.state.doc.toString(),
      notes: window.omajot && [...window.omajot.state.notes.values()].map(n => n.title),
    })).catch(err => String(err))
    console.error('FAIL state', name, JSON.stringify(info))
  }
  throw e
} finally {
  await browser.close()
  await stopHub().catch(() => {})
  await rm(data, { recursive: true, force: true })
}
