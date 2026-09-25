// The PWA side of docs/PROTOCOL.md §2: push the outbox, pull pages, listen
// to the SSE doorbell. Everything environmental (fetch, EventSource, timers,
// online events) is injected, so the whole loop runs under node tests.
//
// Order per cycle: upload pending blobs (so other devices can load images a
// batch references) → push outbox batches in bseq order, one in flight →
// pull pages until the cursor reaches the hub head.

export const PAGE_LIMIT = 500
export const CHUNK = 1024 * 1024 // hub request bodies are capped at 1 MiB
const BACKOFF_MS = [1000, 2000, 5000, 10000, 30000]
const SAFETY_PULL_MS = 60000

export class SyncClient {
  constructor({ store, replica, ingest, base = '', fetch: f, EventSource: ES, setTimeout: st, clearTimeout: ct,
    onState = () => {}, onError = () => {}, log = () => {} }) {
    this.store = store
    this.replica = replica
    this.ingest = ingest // (opsJson) => void; routes engine events to the UI
    this.base = base
    this.fetch = f || globalThis.fetch.bind(globalThis)
    this.ES = ES === undefined ? globalThis.EventSource : ES
    this.setTimeout = st || globalThis.setTimeout.bind(globalThis)
    this.clearTimeout = ct || globalThis.clearTimeout.bind(globalThis)
    this.onState = onState
    this.onError = onError
    this.log = log
    this.reported = new Set() // conflicts already reported, so each shows once
    this.cursor = 0
    this.head = 0
    this.pending = 0
    this.state = 'connecting'
    this.running = false
    this.cycling = null
    this.again = false
    this.failures = 0
    this.timer = null
    this.es = null
    this.esTimer = null
  }

  async start() {
    this.cursor = (await this.store.getMeta('cursor')) || 0
    this.pending = (await this.store.listOutbox()).length
    this.running = true
    this.emit()
    this.openDoorbell()
    this.schedule(0)
  }

  stop() {
    this.running = false
    if (this.timer) this.clearTimeout(this.timer)
    if (this.esTimer) this.clearTimeout(this.esTimer)
    if (this.es) this.es.close()
    this.es = null
  }

  emit() {
    this.onState({ state: this.state, pending: this.pending, head: this.head, cursor: this.cursor })
  }

  setState(state) {
    if (state !== this.state) {
      this.state = state
      this.emit()
    }
  }

  // Run a sync cycle soon; coalesces with one already running.
  schedule(delay = 0) {
    if (!this.running) return
    if (this.timer) this.clearTimeout(this.timer)
    this.timer = this.setTimeout(() => {
      this.timer = null
      this.kick()
    }, delay)
  }

  // Runs a cycle now (or once more after the current one). Returns a promise
  // that resolves when the cycle it joined has finished.
  kick() {
    if (this.cycling) {
      this.again = true
      return this.cycling
    }
    this.cycling = (async () => {
      do {
        this.again = false
        await this.cycle()
      } while (this.again && this.running)
      this.cycling = null
    })()
    return this.cycling
  }

  async cycle() {
    this.conflicted = false
    try {
      await this.uploadBlobs()
      await this.push()
      await this.pull()
      this.failures = 0
      this.setState(this.conflicted ? 'conflict' : this.esOpen() || !this.ES ? 'online' : 'connecting')
      this.schedule(SAFETY_PULL_MS)
    } catch (e) {
      this.failures++
      this.log('sync failed: ' + (e.message || e))
      this.setState('offline')
      this.schedule(BACKOFF_MS[Math.min(this.failures - 1, BACKOFF_MS.length - 1)])
    }
  }

  async api(path, init) {
    const res = await this.fetch(this.base + path, { cache: 'no-store', ...init })
    if (!res.ok && res.status !== 201) {
      const err = new Error(`${init?.method || 'GET'} ${path}: HTTP ${res.status}`)
      err.status = res.status
      throw err
    }
    return res
  }

  async uploadBlobs() {
    for (const { name, blob } of await this.store.pendingBlobs()) {
      if (blob.size <= CHUNK) {
        await this.api('api/blobs/' + name, { method: 'PUT', body: blob,
          headers: { 'Content-Type': 'application/octet-stream' } })
      } else {
        await this.uploadChunked(name, blob)
      }
      await this.store.deleteBlob(name)
    }
  }

  // PUT ?offset=N&total=T per ≤ 1 MiB chunk: 202 {received} → continue,
  // 409 {received} → resume there, 200/201 → complete (hash checked by the hub).
  async uploadChunked(name, blob) {
    const total = blob.size
    let offset = 0
    for (let guard = 0; guard < 4 * Math.ceil(total / CHUNK) + 8; guard++) {
      const res = await this.fetch(`${this.base}api/blobs/${name}?offset=${offset}&total=${total}`, {
        method: 'PUT', cache: 'no-store', body: blob.slice(offset, offset + CHUNK),
        headers: { 'Content-Type': 'application/octet-stream' } })
      if (res.status === 200 || res.status === 201) return
      if (res.status === 202 || res.status === 409) {
        const { received } = await res.json()
        if (typeof received !== 'number' || received < 0 || received > total) throw new Error(`blob ${name}: bad received ${received}`)
        offset = received
        continue
      }
      const err = new Error(`PUT api/blobs/${name}: HTTP ${res.status}`)
      err.status = res.status
      throw err
    }
    throw new Error(`blob ${name}: upload did not complete`)
  }

  // Reports a sync conflict once; local edits always stay in the outbox.
  conflict(key, message) {
    if (this.reported.has(key)) return
    this.reported.add(key)
    this.onError(message)
  }

  async push() {
    for (;;) {
      const [batch] = await this.store.listOutbox()
      if (!batch) break
      const res = await this.fetch(this.base + 'api/batches', { method: 'POST', cache: 'no-store', body: JSON.stringify(batch),
        headers: { 'Content-Type': 'application/json' } })
      if (res.status === 409) {
        const detail = await res.text().catch(() => '')
        this.conflict('push/' + batch.bseq, `Sync conflict: the hub refused change batch ${batch.bseq} (${detail.slice(0, 120)}). `
          + 'Your edits are kept on this device.')
        this.conflicted = true
        return // keep the outbox; still pull what others wrote
      }
      if (!res.ok) {
        const err = new Error(`POST api/batches: HTTP ${res.status}`)
        err.status = res.status
        throw err
      }
      const { seq, head } = await res.json()
      await this.store.deleteOutbox(batch.bseq)
      this.pending = Math.max(0, this.pending - 1)
      if (head > this.head) this.head = head
      this.log(`pushed bseq ${batch.bseq} as seq ${seq}`)
      this.emit()
    }
  }

  async pull() {
    for (;;) {
      const res = await this.api(`api/batches?after=${this.cursor}&limit=${PAGE_LIMIT}`)
      const page = await res.json()
      if (page.head < this.cursor) {
        this.conflict('behind/' + page.head, `Sync conflict: the hub has fewer changes (${page.head}) than this device `
          + `has seen (${this.cursor}); it may have been reset. Your notes are kept on this device.`)
        this.conflicted = true
        break
      }
      if (page.head > this.head) this.head = page.head
      if (!page.batches.length) break
      const foreign = []
      let cursor = this.cursor
      for (const b of page.batches) {
        if (b.seq <= cursor) continue
        cursor = b.seq
        if (b.replica === this.replica) {
          // Our own batch coming back: the push reply may have been lost.
          await this.store.deleteOutbox(b.bseq)
          continue
        }
        const opsJson = JSON.stringify(b.ops)
        this.ingest(opsJson)
        foreign.push(opsJson)
      }
      await this.store.commitPull(foreign, cursor)
      this.cursor = cursor
      this.pending = (await this.store.listOutbox()).length
      this.emit()
      if (this.cursor >= page.head) break
    }
  }

  // New local batch stored in the outbox.
  queued() {
    this.pending++
    this.emit()
    this.schedule(0)
  }

  esOpen() {
    return !!this.es && this.es.readyState === 1
  }

  openDoorbell() {
    if (!this.ES || !this.running) return
    const es = new this.ES(this.base + 'api/events')
    this.es = es
    es.addEventListener('head', (e) => {
      let head = 0
      try { head = JSON.parse(e.data).head } catch { head = parseInt(e.lastEventId, 10) || 0 }
      if (head > this.head) this.head = head
      if (head > this.cursor) this.schedule(0)
      else this.setState('online')
    })
    es.onopen = () => {
      if (this.failures === 0) this.setState('online')
    }
    es.onerror = () => {
      // The hub ends streams before its deadline; the browser reconnects on
      // its own (readyState 0). A closed stream (e.g. a 403) needs a new one.
      if (es.readyState === 2) {
        this.es = null
        this.setState(this.failures ? 'offline' : 'connecting')
        this.esTimer = this.setTimeout(() => this.openDoorbell(), BACKOFF_MS[Math.min(this.failures, BACKOFF_MS.length - 1)])
      }
    }
  }

  // Browser connectivity hints.
  online() {
    this.failures = 0
    if (!this.es) this.openDoorbell()
    this.schedule(0)
  }

  offline() {
    this.setState('offline')
  }
}
