import { test } from 'node:test'
import assert from 'node:assert/strict'
import { FakeHub } from './fakehub.mjs'
import { MemoryStore } from '../src/store.js'
import { Replica } from '../src/replica.js'
import { engineFactory } from './core.mjs'
import { SyncClient } from '../src/sync.js'

// Timers that only fire when the test says so, so cycles are deterministic.
function manualTimers() {
  const pending = new Map()
  let n = 0
  return {
    setTimeout: (fn, ms) => { pending.set(++n, { fn, ms }); return n },
    clearTimeout: (id) => pending.delete(id),
    // Fire every timer due within `ms` (safety pulls are 60 s, so 0 skips them).
    async fire(ms = 0) {
      for (const [id, t] of [...pending]) if (t.ms <= ms) { pending.delete(id); t.fn() }
    },
  }
}

async function device(hub, store = new MemoryStore()) {
  const timers = manualTimers()
  const events = []
  const r = await Replica.open({ store, engine: engineFactory, fetch: hub.fetch,
    EventSource: hub.EventSource, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout, log: () => {} })
  r.on((e) => events.push(e))
  await r.start()
  return { r, timers, events, store, settle: async () => { await r.flushed(); await timers.fire(0); await r.sync.kick() } }
}

test('a note created on one device appears on another, text included', async () => {
  const hub = new FakeHub()
  const a = await device(hub)
  const b = await device(hub)
  const { note } = a.r.request('create', { folder: null, text: '' })
  a.r.request('open', { note })
  a.r.request('edit', { note, seq: 1, pos: 0, del: 0, ins: 'Groceries\nmilk #shopping' })
  await a.settle()
  assert.equal(hub.head, 1, 'create + edit are coalesced into one batch')
  assert.equal(a.r.sync.pending, 0)
  await b.settle()
  const list = b.r.request('list').notes
  assert.equal(list.length, 1)
  assert.equal(list[0].title, 'Groceries')
  assert.deepEqual(list[0].tags, ['shopping'])
  assert.equal(b.r.sync.cursor, 1)
  assert.ok(b.events.some(e => e.ev === 'notes'))
})

test('an open note on the other device receives a patch event', async () => {
  const hub = new FakeHub()
  const a = await device(hub)
  const b = await device(hub)
  const { note } = a.r.request('create', { folder: null, text: 'hello' })
  await a.settle(); await b.settle()
  const opened = b.r.request('open', { note })
  assert.equal(opened.text, 'hello')
  a.r.request('open', { note })
  a.r.request('edit', { note, seq: 1, pos: 5, del: 0, ins: ' world' })
  await a.settle(); await b.settle()
  const patch = b.events.find(e => e.ev === 'patch')
  assert.deepEqual({ ...patch }, { ev: 'patch', note, base: 0, pseq: 1, pos: 5, del: 0, ins: ' world' })
})

test('restart replays the local log and keeps cursor and outbox', async () => {
  const hub = new FakeHub()
  hub.down = true
  const store = new MemoryStore()
  const a = await device(hub, store)
  a.r.request('create', { folder: null, text: 'offline note' })
  await a.settle()
  assert.equal(a.r.sync.state, 'offline')
  assert.equal((await store.listOutbox()).length, 1)
  a.r.sync.stop()

  hub.down = false
  const again = await device(hub, store)
  assert.equal(again.r.request('list').notes[0].title, 'offline note')
  await again.settle()
  assert.equal(hub.head, 1)
  assert.equal((await store.listOutbox()).length, 0)
  assert.equal(again.r.sync.state, 'online')
  // New local ops continue the batch sequence.
  again.r.request('create', { folder: null, text: 'second' })
  await again.settle()
  assert.equal(hub.batches[1].bseq, 2)
})

test('a push whose reply was lost is cleared by the pull', async () => {
  const hub = new FakeHub()
  const store = new MemoryStore()
  const a = await device(hub, store)
  // Simulate: the hub accepted bseq 1 but the client never saw the reply.
  a.r.request('create', { folder: null, text: 'x' })
  await a.r.flushed()
  const [batch] = await store.listOutbox()
  hub.handle('POST', '/api/batches', JSON.stringify(batch))
  // The client pushes again (idempotent) and the pull sees its own batch.
  await a.settle()
  assert.equal(hub.head, 1)
  assert.equal((await store.listOutbox()).length, 0)
})

test('pulls page until the cursor reaches head', async () => {
  const hub = new FakeHub()
  for (let i = 1; i <= 1200; i++) {
    hub.handle('POST', '/api/batches', JSON.stringify({ replica: 'ffffffffffffffff', bseq: i,
      ops: [{ id: `ffffffffffffffff-${i}`, t: i, k: 'note.create', note: `n-ffffffffffffffff-${i}`, folder: null, text: 'n' + i }] }))
  }
  const store = new MemoryStore()
  const ingested = []
  const sync = new SyncClient({ store, replica: '0000000000000001', ingest: (o) => ingested.push(o), fetch: hub.fetch,
    EventSource: null, setTimeout: () => 0, clearTimeout: () => {} })
  await sync.start()
  await sync.kick()
  assert.equal(sync.cursor, 1200)
  assert.equal(ingested.length, 1200)
  assert.equal(await store.getMeta('cursor'), 1200)
})

test('blobs upload before batches, and bad hashes are rejected by the hub', async () => {
  const hub = new FakeHub()
  const store = new MemoryStore()
  const bytes = new TextEncoder().encode('png bytes')
  const sha = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(b => b.toString(16).padStart(2, '0')).join('')
  await store.putBlob(sha + '.png', new Blob([bytes]))
  const a = await device(hub, store)
  a.r.request('create', { folder: null, text: `![](attachments/${sha}.png)` })
  await a.settle()
  assert.ok(hub.blobs.has(sha + '.png'))
  assert.equal((await store.pendingBlobs()).length, 0)
  assert.equal(hub.handle('PUT', '/api/blobs/' + '0'.repeat(64) + '.png', Buffer.from('x')).status, 400)
})

test('local ops are coalesced into batches of up to BATCH_MS', async () => {
  const hub = new FakeHub()
  const a = await device(hub)
  const { note } = a.r.request('create', { folder: null, text: '' })
  a.r.request('open', { note })
  for (let i = 0; i < 20; i++) a.r.request('edit', { note, seq: i + 1, pos: i, del: 0, ins: 'x' })
  const waiting = a.r.pendingOps.length
  assert.ok(waiting > 1)
  assert.equal((await a.store.listOutbox()).length, 0, 'nothing persisted before the batch window closes')
  await a.settle()
  assert.equal(hub.head, 1)
  assert.equal(hub.batches[0].ops.length, waiting)
  assert.equal(a.r.pendingOps.length, 0)
})

async function blobOf(size) {
  const bytes = new Uint8Array(size)
  for (let i = 0; i < size; i++) bytes[i] = (i * 31 + 7) & 0xff
  const sha = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(b => b.toString(16).padStart(2, '0')).join('')
  return { bytes, name: sha + '.jpg' }
}

test('blobs over 1 MiB upload in chunks and resume after a 409', async () => {
  const hub = new FakeHub()
  const { bytes, name } = await blobOf(2.5 * 1024 * 1024)
  // Pretend an earlier attempt already delivered the first chunk.
  hub.handle('PUT', `/api/blobs/${name}?offset=0&total=${bytes.length}`, Buffer.from(bytes.subarray(0, 1024 * 1024)))
  const store = new MemoryStore()
  await store.putBlob(name, new Blob([bytes]))
  const puts = []
  const fetchSpy = (url, init) => { if (init?.method === 'PUT') puts.push(new URL(url, 'http://h/').search); return hub.fetch(url, init) }
  const sync = new SyncClient({ store, replica: '0000000000000001', ingest: () => {}, fetch: fetchSpy, EventSource: null,
    setTimeout: () => 0, clearTimeout: () => {} })
  await sync.start()
  await sync.kick()
  assert.deepEqual(puts, ['?offset=0&total=2621440', '?offset=1048576&total=2621440', '?offset=2097152&total=2621440'])
  assert.equal(Buffer.compare(hub.blobs.get(name), Buffer.from(bytes)), 0)
  assert.equal((await store.pendingBlobs()).length, 0)
})

test('a 409 on push keeps the outbox, reports once, and still pulls', async () => {
  const hub = new FakeHub()
  const store = new MemoryStore()
  const errors = []
  const a = await device(hub, store)
  a.r.on(e => { if (e.ev === 'error') errors.push(e.error) })
  a.r.request('create', { folder: null, text: 'mine' })
  await a.r.flushed()
  // The hub forgot this replica: its first batch looks like a gap.
  const [batch] = await store.listOutbox()
  batch.bseq = 5
  await store.deleteOutbox(1)
  await store.addLocal('[]', batch)
  hub.handle('POST', '/api/batches', JSON.stringify({ replica: 'ffffffffffffffff', bseq: 1, ops: [] }))
  await a.settle()
  await a.r.sync.kick()
  assert.equal(errors.length, 1)
  assert.match(errors[0], /Sync conflict/)
  assert.equal((await store.listOutbox()).length, 1)
  assert.equal(a.r.sync.state, 'conflict')
  assert.equal(a.r.sync.cursor, 1, 'other replicas are still pulled')
})

test('a hub behind the local cursor is reported, nothing is lost', async () => {
  const hub = new FakeHub()
  const store = new MemoryStore()
  await store.setMeta('cursor', 10)
  const errors = []
  const a = await device(hub, store)
  a.r.on(e => { if (e.ev === 'error') errors.push(e.error) })
  a.r.request('create', { folder: null, text: 'still here' })
  await a.settle()
  assert.equal(a.r.sync.cursor, 10)
  assert.ok(errors.some(e => /fewer changes/.test(e)))
  assert.equal(a.r.request('list').notes[0].title, 'still here')
})

test('ops stored but not yet batched when the page died are recovered and pushed', async () => {
  const hub = new FakeHub()
  const store = new MemoryStore()
  const a = await device(hub, store)
  const { note } = a.r.request('create', { folder: null, text: 'typed just before closing' })
  await a.r.persisting // stored in the log, batch window still open
  assert.equal((await store.listOutbox()).length, 0)
  a.r.stop() // the page is gone; the batch timer never fires

  const b = await device(hub, store)
  assert.equal(b.r.request('list').notes[0].id, note)
  assert.equal((await store.listOutbox()).length, 1, 'recovery batch queued')
  await b.settle()
  assert.equal(hub.head, 1)
  const c = await device(hub)
  await c.settle()
  assert.equal(c.r.request('list').notes[0].title, 'typed just before closing')
  // A second restart must not batch the same ops again.
  const d = await device(hub, store)
  assert.equal((await store.listOutbox()).length, 0)
  for (const x of [b, c, d]) x.r.stop()
})
