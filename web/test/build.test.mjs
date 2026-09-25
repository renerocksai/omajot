// The built service worker and page must be fully stamped and parse.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import vm from 'node:vm'

const dist = new URL('../dist/', import.meta.url)
const skip = existsSync(new URL('sw.js', dist)) ? false : 'run `npm run build` first'

test('dist/sw.js is stamped, parses, and precaches the shell', { skip }, () => {
  const sw = readFileSync(new URL('sw.js', dist), 'utf8')
  assert.doesNotMatch(sw, /__[A-Z]+__/)
  new vm.Script(sw) // throws on a syntax error
  const assets = JSON.parse(/const ASSETS = (\[.*\])/.exec(sw)[1])
  for (const a of ['./', 'app.js', 'app.css', 'core.wasm', 'manifest.webmanifest']) assert.ok(assets.includes(a), a)
  for (const a of assets.slice(1)) assert.ok(existsSync(new URL(a, dist)), 'missing ' + a)
})

test('dist/index.html is stamped', { skip }, () => {
  assert.doesNotMatch(readFileSync(new URL('index.html', dist), 'utf8'), /__[A-Z]+__/)
})
