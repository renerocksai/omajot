import { test } from 'node:test'
import assert from 'node:assert/strict'
import { darkRuns, qrSvg, QUIET } from '../src/qr.js'

const square = (size, fn) => Array.from({ length: size }, (_, y) => Array.from({ length: size }, (_, x) => fn(x, y) ? '1' : '0').join(''))

test('darkRuns merges horizontal runs and covers exactly the dark modules', () => {
  const rows = ['0110111', '1000001']
  assert.deepEqual(darkRuns(rows), [[1, 0, 2], [4, 0, 3], [0, 1, 1], [6, 1, 1]])
  const big = square(25, (x, y) => (x * 7 + y * 3) % 5 < 2)
  const dark = big.join('').split('').filter(c => c === '1').length
  assert.equal(darkRuns(big).reduce((s, [, , n]) => s + n, 0), dark)
})

test('qrSvg: quiet zone, one unit per module, dark runs offset by the quiet zone', () => {
  const rows = square(21, (x, y) => x === y)
  const svg = qrSvg({ size: 21, rows })
  const total = 21 + 2 * QUIET
  assert.match(svg, new RegExp(`viewBox="0 0 ${total} ${total}"`))
  assert.match(svg, /shape-rendering="crispEdges"/)
  assert.match(svg, /data-modules="21"/)
  assert.match(svg, /<rect width="29" height="29" fill="#fff"\/>/)
  // The diagonal: 21 one-module runs, the first at (4,4), the last at (24,24).
  const runs = [...svg.matchAll(/M(\d+) (\d+)h(\d+)v1h-\d+z/g)].map(m => m.slice(1).map(Number))
  assert.equal(runs.length, 21)
  assert.deepEqual(runs[0], [4, 4, 1])
  assert.deepEqual(runs[20], [24, 24, 1])
})

test('qrSvg rejects non-square input', () => {
  assert.throws(() => qrSvg({ size: 21, rows: ['1'] }))
  assert.throws(() => qrSvg({ size: 3, rows: ['111', '111', '111'] }))
})
