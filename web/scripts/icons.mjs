// Renders src/icons/icon.svg to the PNG sizes the manifest and iOS need.
// Run once after changing the SVG: `node scripts/icons.mjs` (uses system Chromium).
import puppeteer from 'puppeteer-core'
import { readFile } from 'node:fs/promises'

const svg = await readFile(new URL('../src/icons/icon.svg', import.meta.url), 'utf8')
const browser = await puppeteer.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium', headless: true })
const page = await browser.newPage()
const out = (name) => new URL('../src/icons/' + name, import.meta.url).pathname
const render = async (size, name, maskable = false) => {
  await page.setViewport({ width: size, height: size, deviceScaleFactor: 1 })
  // Maskable icons keep the artwork inside the central 80% safe zone.
  const inner = maskable ? `<div style="width:100%;height:100%;background:#f5b400;display:grid;place-items:center">
      <div style="width:80%;height:80%">${svg.replace('rx="112"', 'rx="0"')}</div></div>` : svg
  await page.setContent(`<html><body style="margin:0;background:transparent">
    <div style="width:${size}px;height:${size}px">${inner}</div>
    <style>svg{width:100%;height:100%;display:block}</style></body></html>`)
  await page.screenshot({ path: out(name), omitBackground: !maskable, clip: { x: 0, y: 0, width: size, height: size } })
}
await render(180, 'icon-180.png')
await render(192, 'icon-192.png')
await render(512, 'icon-512.png')
await render(512, 'icon-maskable-512.png', true)
await browser.close()
console.log('icons written')
