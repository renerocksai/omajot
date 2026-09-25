// The glue against the real core.wasm (skipped until it exists with all exports).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { instantiateCore, WasmEngine, replicaHalves } from '../src/engine-wasm.js'

const path = [new URL('../../zig-out/web/core.wasm', import.meta.url), new URL('../dist/core.wasm', import.meta.url)]
  .find(u => existsSync(u))
const bytes = path ? await readFile(path) : null
let ready = false
if (bytes) {
  const { exports, missing } = await instantiateCore(bytes)
  if (!missing.length) {
    const reply = new WasmEngine(exports, '00000000000000aa').call({ id: 1, cmd: 'hello', client: 'web' })[0]
    ready = !!reply?.ok
  }
}
const skip = ready ? false : 'core.wasm missing or still a stub'

async function engine(hex) {
  const { exports } = await instantiateCore(bytes) // one instance per replica, like one per tab
  return new WasmEngine(exports, hex)
}
const reply = (lines, id) => lines.find(l => l.re === id)

test('replica halves', () => {
  assert.deepEqual(replicaHalves('0123456789abcdef'), [0x89abcdef, 0x01234567])
})

test('create, edit, list through core.wasm', { skip }, async () => {
  const a = await engine('00000000000000a1')
  assert.equal(reply(a.call({ id: 1, cmd: 'hello', client: 'web' }), 1).replica, '00000000000000a1')
  const { note } = reply(a.call({ id: 2, cmd: 'create', folder: null, text: '' }), 2)
  assert.match(note, /^n-00000000000000a1-\d+$/)
  assert.equal(reply(a.call({ id: 3, cmd: 'open', note }), 3).seq, 0)
  const lines = a.call({ id: 4, cmd: 'edit', note, seq: 1, pos: 0, del: 0, ins: 'Grüße 🎉\nbody #Work' })
  assert.equal(reply(lines, 4).ok, true)
  const summary = lines.find(l => l.ev === 'notes').upsert[0]
  assert.equal(summary.title, 'Grüße 🎉')
  assert.deepEqual(summary.tags, ['work'])
  assert.notEqual(a.takeNewOps(), '[]')
  assert.equal(a.takeNewOps(), '[]')
})

test('two engines converge; the open note gets a patch; ingest is idempotent', { skip }, async () => {
  const a = await engine('00000000000000a1')
  const b = await engine('00000000000000b2')
  const { note } = reply(a.call({ id: 1, cmd: 'create', folder: null, text: 'hello' }), 1)
  const ops1 = a.takeNewOps()
  b.ingest(ops1)
  assert.equal(reply(b.call({ id: 2, cmd: 'open', note }), 2).text, 'hello')
  a.call({ id: 3, cmd: 'open', note })
  a.call({ id: 4, cmd: 'edit', note, seq: 1, pos: 5, del: 0, ins: ' world' })
  const ops2 = a.takeNewOps()
  const events = b.ingest(ops2)
  const patch = events.find(e => e.ev === 'patch')
  assert.deepEqual({ ...patch }, { ev: 'patch', note, base: 0, pseq: 1, pos: 5, del: 0, ins: ' world' })
  assert.deepEqual(b.ingest(ops2).filter(e => e.ev === 'patch'), [])
  // Concurrent edits at both ends merge.
  b.call({ id: 5, cmd: 'edit', note, seq: 1, ack: 1, pos: 0, del: 0, ins: 'B:' })
  a.call({ id: 6, cmd: 'edit', note, seq: 2, pos: 11, del: 0, ins: '!' })
  const fromB = b.takeNewOps(), fromA = a.takeNewOps()
  a.ingest(fromB)
  b.ingest(fromA)
  const textA = reply(a.call({ id: 7, cmd: 'open', note }), 7).text
  const textB = reply(b.call({ id: 8, cmd: 'open', note }), 8).text
  assert.equal(textA, 'B:hello world!')
  assert.equal(textB, textA)
})

test('replaying the own log restores state and the counter', { skip }, async () => {
  const a = await engine('00000000000000a1')
  a.call({ id: 1, cmd: 'create', folder: null, text: 'one' })
  const log = [a.takeNewOps()]
  const again = await engine('00000000000000a1')
  for (const ops of log) again.ingest(ops)
  const r = reply(again.call({ id: 2, cmd: 'create', folder: null, text: 'two' }), 2)
  const list = reply(again.call({ id: 3, cmd: 'list' }), 3).notes.map(n => n.title).sort()
  assert.deepEqual(list, ['one', 'two'])
  assert.ok(!log[0].includes(r.note.replace(/^n-/, '')), 'new note id must not collide with replayed ops')
})

// Cross-implementation check: the JS OtClient against the Zig engine, with
// edits and patches crossing on the wire. Replica R edits the same note; E
// (the client's engine) ingests R's ops and sends patches; the client's edits
// reach E late, carrying `ack`. Afterwards a fresh engine that ingested every
// op must hold exactly the client's text.
test('JS OtClient converges with the engine under crossing edits and patches', { skip }, async () => {
  const { OtClient, applyEdit, applyPrims } = await import('../src/patch.js')
  let seed = 11
  const r = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n }
  for (let round = 0; round < 40; round++) {
    const E = await engine('00000000000000e1')
    const R = await engine('00000000000000f2')
    const all = []
    const take = (x) => { const ops = x.takeNewOps(); if (ops !== '[]') all.push(ops); return ops }
    const { note } = reply(E.call({ id: 1, cmd: 'create', folder: null, text: 'hello world' }), 1)
    R.ingest(take(E))
    const opened = reply(E.call({ id: 2, cmd: 'open', note }), 2)
    reply(R.call({ id: 3, cmd: 'open', note }), 3)
    let client = opened.text, rtext = opened.text
    const c = new OtClient()
    c.reset(opened.pseq)
    let seq = 0, rseq = 0, id = 10
    const toEngine = [], toClient = []
    const randEdit = (text) => {
      const pos = r(text.length + 1)
      const d = pos < text.length && r(2) ? 1 + r(Math.min(3, text.length - pos)) : 0
      let ins = r(3) ? ['a', 'ö', '🎉', 'zz'][r(4)] : ''
      if (!d && !ins) ins = 'q'
      // Keep emoji intact: never split a surrogate pair.
      const bad = (i) => i > 0 && i < text.length && /[\uDC00-\uDFFF]/.test(text[i])
      if (bad(pos) || bad(pos + d)) return null
      return { pos, del: d, ins }
    }
    for (let step = 0; step < 80 || toEngine.length || toClient.length; step++) {
      const choice = step < 80 ? r(4) : 2 + r(2)
      if (choice === 0) { // client types
        const e = randEdit(client)
        if (!e) continue
        seq++
        client = applyEdit(client, e)
        c.local(seq, e)
        toEngine.push({ seq, ack: c.pseq, ...e })
      } else if (choice === 1) { // the other replica types; E ingests its ops at once
        const e = randEdit(rtext)
        if (!e) continue
        rseq++
        rtext = applyEdit(rtext, e)
        assert.equal(reply(R.call({ id: id++, cmd: 'edit', note, seq: rseq, ...e }), id - 1).ok, true)
        const ops = take(R)
        for (const ev of E.ingest(ops)) if (ev.ev === 'patch') toClient.push(ev)
      } else if (choice === 2 && toEngine.length) { // a delayed client edit reaches E
        const m = toEngine.shift()
        const rep = reply(E.call({ id: id++, cmd: 'edit', note, ...m }), id - 1)
        assert.equal(rep.ok, true, JSON.stringify(rep))
        take(E)
      } else if (choice === 3 && toClient.length) { // a delayed patch reaches the client
        client = applyPrims(client, c.remote(toClient.shift()))
      }
    }
    const F = await engine('00000000000000f3')
    for (const ops of all) F.ingest(ops)
    const truth = reply(F.call({ id: 1, cmd: 'open', note }), 1).text
    assert.equal(client, truth, `round ${round}`)
  }
})
