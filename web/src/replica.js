// One device's replica: the engine (core.wasm), its storage and the hub sync.
// The UI talks to it with §1 requests and listens to §1 events.
import { loadWasmEngine } from './engine-wasm.js'
import { openStore } from './store.js'
import { SyncClient } from './sync.js'

export function randomReplica() {
  const b = new Uint8Array(8)
  crypto.getRandomValues(b)
  return [...b].map(x => x.toString(16).padStart(2, '0')).join('')
}

export const BATCH_MS = 300
export const BATCH_MAX_OPS = 500

export class Replica {
  // opts: base (URL prefix of the hub, '' = same origin), store, engine
  // (injected in tests), fetch / EventSource / timers (injected in tests).
  static async open(opts = {}) {
    const r = new Replica()
    r.base = opts.base ?? ''
    r.store = opts.store || await openStore()
    r.listeners = new Set()
    r.nextId = 1
    r.persisting = Promise.resolve()
    r.pendingOps = []
    r.batchTimer = null
    r.lastKey = 0

    r.replica = await r.store.getMeta('replica')
    if (!r.replica) {
      r.replica = randomReplica()
      await r.store.setMeta('replica', r.replica)
    }
    r.nextBseq = (await r.store.getMeta('nextBseq')) || 1

    r.engine = opts.engine ? opts.engine(r.replica) : await loadWasmEngine(r.base + 'core.wasm', r.replica)

    for (const ops of await r.store.loadOps()) r.engine.ingest(ops)
    await r.recoverUnbatched()

    r.sync = new SyncClient({
      store: r.store,
      replica: r.replica,
      base: r.base,
      ingest: (ops) => r.dispatch(r.engine.ingest(ops)),
      fetch: opts.fetch,
      EventSource: opts.EventSource,
      setTimeout: opts.setTimeout,
      clearTimeout: opts.clearTimeout,
      onState: (s) => r.dispatch([{ ev: 'sync', ...s }]),
      onError: (error) => r.dispatch([{ ev: 'error', error }]),
      log: opts.log || ((m) => console.debug('omajot sync:', m)),
    })
    return r
  }

  on(fn) {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }

  dispatch(events) {
    for (const e of events) for (const fn of this.listeners) fn(e)
  }

  // Sends one §1 request; returns the reply (check `ok`). Events are
  // dispatched before this returns.
  call(cmd, fields = {}) {
    const id = this.nextId++
    const lines = this.engine.call({ id, cmd, ...fields })
    const reply = lines.find(l => l.re === id) || { re: id, ok: false, error: 'no reply' }
    this.dispatch(lines.filter(l => l !== reply && l.ev))
    this.collectOps()
    return reply
  }

  // Like call, but throws on an error reply.
  request(cmd, fields) {
    const reply = this.call(cmd, fields)
    if (!reply.ok) throw new Error(`${cmd}: ${reply.error}`)
    return reply
  }

  // Every call's ops are stored at once (so nothing typed is lost when the
  // page goes away), but batches for the hub are coalesced for BATCH_MS
  // (DESIGN.md: "the editor sends ops every ~300 ms"), so typing a sentence
  // is one batch, not one per key.
  collectOps() {
    const ops = this.engine.takeNewOps()
    if (!ops || ops === '[]') return
    this.pendingOps.push(...JSON.parse(ops))
    this.persisting = this.persisting
      .then(() => this.store.appendLocalOps(ops))
      .then((key) => { this.lastKey = key })
      .catch((e) => this.dispatch([{ ev: 'error', error: 'saving failed: ' + e.message }]))
    if (this.pendingOps.length >= BATCH_MAX_OPS) this.flushOps()
    else if (!this.batchTimer) this.batchTimer = setTimeout(() => this.flushOps(), BATCH_MS)
  }

  flushOps() {
    clearTimeout(this.batchTimer)
    this.batchTimer = null
    if (!this.pendingOps.length) return this.persisting
    const batch = { replica: this.replica, bseq: this.nextBseq++, ops: this.pendingOps }
    this.pendingOps = []
    this.persisting = this.persisting
      .then(() => this.store.commitBatch(batch, this.lastKey))
      .then(() => this.sync.queued())
      .catch((e) => this.dispatch([{ ev: 'error', error: 'saving failed: ' + e.message }]))
    return this.persisting
  }

  // Resolves once every local change so far is stored and batched (not necessarily synced).
  flushed() {
    return this.flushOps()
  }

  // Own ops stored but never batched (the page closed within BATCH_MS) go
  // into one recovery batch, so they still reach the hub.
  async recoverUnbatched() {
    const rows = await this.store.unbatchedLocalOps()
    if (!rows.length) return
    const ops = rows.flatMap(r => JSON.parse(r.ops))
    const batch = { replica: this.replica, bseq: this.nextBseq++, ops }
    await this.store.commitBatch(batch, rows[rows.length - 1].key)
  }

  async start() {
    await this.sync.start()
  }

  // Stops syncing and batching (the page is going away or lost its lock).
  stop() {
    clearTimeout(this.batchTimer)
    this.batchTimer = null
    this.sync.stop()
  }
}
