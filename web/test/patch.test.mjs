import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ins, del, xformPrim, xform, fromEdit, OtClient, applyPrims, applyEdit, sequentialEdits } from '../src/patch.js'

// Ports of the unit tests in src/core/ot.zig.
test('concurrent inserts at one position: the winner goes first on both sides', () => {
  const p = ins(1, 'P'), l = ins(1, 'L')
  const r = xformPrim(p, l, true)
  const server = applyPrims(applyPrims('ab', [p]), r.b)
  const client = applyPrims(applyPrims('ab', [l]), r.a)
  assert.equal(server, 'aPLb')
  assert.equal(client, server)
})

test('insert inside a concurrent delete survives and splits the delete', () => {
  const r = xformPrim(ins(3, 'X'), del(1, 4, 7), false)
  assert.equal(r.a[0].pos, 1)
  assert.equal(r.b.length, 2)
  assert.equal(r.b[1].tag, 7)
})

test('fromEdit is delete then insert', () => {
  assert.deepEqual(fromEdit(2, 3, 'ab', 5).map(p => [p.kind, p.pos, p.len, p.text, p.tag]),
    [['del', 2, 3, '', 5], ['ins', 2, 0, 'ab', 5]])
  assert.deepEqual(fromEdit(2, 0, '', 1), [])
})

// Port of "jupiter convergence under random delays": a server making patches
// and a client making edits, with random delays both ways, end identical.
function rng(seed) {
  let s = BigInt(seed) || 1n
  return (n) => { s = (s * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn; return Number(s >> 33n) % n }
}
function randomPrim(r, len, tag) {
  if (len > 0 && r(2)) {
    const pos = r(len)
    return del(pos, 1 + r(Math.min(len - pos, 4)), tag)
  }
  return ins(r(len + 1), ['x', 'y', 'ü', '🎉'][r(4)], tag)
}

test('jupiter convergence under random delays (JS server and client)', () => {
  for (let seed = 1; seed <= 400; seed++) {
    const r = rng(seed)
    let server = 'hello', client = 'hello'
    const toClient = [], toServer = []
    let lastSeq = 0, pseq = 0, unacked = []
    let seq = 0
    const c = new OtClient()
    for (let step = 0; step < 60 || toClient.length || toServer.length; step++) {
      const choice = step < 60 ? r(4) : 2 + r(2)
      if (choice === 0) {
        pseq++
        const p = randomPrim(r, server.length, pseq)
        server = applyPrims(server, [p])
        unacked.push(p)
        toClient.push({ pseq, base: lastSeq, prims: [p] })
      } else if (choice === 1) {
        seq++
        const e = randomPrim(r, client.length, seq)
        client = applyPrims(client, [e])
        c.pending.push(e)
        toServer.push({ seq, ack: c.pseq, prims: [e] })
      } else if (choice === 2 && toServer.length) {
        const m = toServer.shift()
        const x = xform(m.prims, unacked.filter(p => p.tag > m.ack), false)
        unacked = x.b
        server = applyPrims(server, x.a)
        lastSeq = m.seq
      } else if (choice === 3 && toClient.length) {
        const m = toClient.shift()
        // Patches arrive as { pos, del, ins }; a single primitive maps cleanly.
        const p = m.prims[0]
        const ev = p.kind === 'ins' ? { pos: p.pos, del: 0, ins: p.text } : { pos: p.pos, del: p.len, ins: '' }
        client = applyPrims(client, c.remote({ ...ev, base: m.base, pseq: m.pseq }))
      }
    }
    assert.equal(client, server, `diverged at seed ${seed}`)
  }
})

test('applyEdit and sequentialEdits', () => {
  assert.equal(applyEdit('a🎉b', { pos: 3, del: 1, ins: 'B' }), 'a🎉B')
  const edits = sequentialEdits([{ fromA: 0, toA: 1, inserted: 'XX' }, { fromA: 3, toA: 3, inserted: 'Y' }])
  assert.deepEqual(edits, [{ pos: 0, del: 1, ins: 'XX' }, { pos: 4, del: 0, ins: 'Y' }])
  let t = 'abcd'
  for (const e of edits) t = applyEdit(t, e)
  assert.equal(t, 'XXbcYd')
})
