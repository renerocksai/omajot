// The PWA's replica storage (docs/PROTOCOL.md §2, §4).
//
//   meta    replica, cursor, nextBseq
//   ops     every ops array this replica applied (own and remote), in order;
//           replayed through `ingest` on start. Rows are { ops, local }. Own
//           ops are written at once; batching for the hub happens later, and
//           meta.batchedUpTo marks the last own row already in a batch, so
//           ops written just before a crash still reach the outbox.
//   outbox  own batches the hub has not confirmed, keyed by bseq
//   blobs   pasted attachments not yet uploaded, keyed by "<sha256>.<ext>"
//
// Two implementations with one interface: IdbStore (browser) and MemoryStore
// (tests, and a fallback when IndexedDB is unavailable, e.g. some private modes).

export class MemoryStore {
  constructor() {
    this.meta = new Map()
    this.ops = []
    this.outbox = new Map()
    this.blobs = new Map()
  }
  async getMeta(key) { return this.meta.get(key) }
  async setMeta(key, value) { this.meta.set(key, value) }
  async loadOps() { return this.ops.map(r => r.ops) }
  async appendLocalOps(opsJson) {
    this.ops.push({ ops: opsJson, local: true })
    return this.ops.length
  }
  async commitBatch(batch, upToKey) {
    this.outbox.set(batch.bseq, batch)
    this.meta.set('nextBseq', batch.bseq + 1)
    this.meta.set('batchedUpTo', upToKey)
  }
  async unbatchedLocalOps() {
    const from = this.meta.get('batchedUpTo') || 0
    return this.ops.map((r, i) => ({ key: i + 1, ...r })).filter(r => r.key > from && r.local)
  }
  async addLocal(opsJson, batch) {
    await this.commitBatch(batch, await this.appendLocalOps(opsJson))
  }
  async listOutbox() { return [...this.outbox.values()].sort((a, b) => a.bseq - b.bseq) }
  async deleteOutbox(bseq) { this.outbox.delete(bseq) }
  async commitPull(opsJsonList, cursor) {
    for (const ops of opsJsonList) this.ops.push({ ops, local: false })
    this.meta.set('cursor', cursor)
  }
  async putBlob(name, blob) { this.blobs.set(name, blob) }
  async getBlob(name) { return this.blobs.get(name) }
  async pendingBlobs() { return [...this.blobs].map(([name, blob]) => ({ name, blob })) }
  async deleteBlob(name) { this.blobs.delete(name) }
}

const DB = 'omajot'
const VERSION = 1

function req(r) {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result)
    r.onerror = () => reject(r.error)
  })
}

function done(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error)
    tx.onabort = () => reject(tx.error || new Error('transaction aborted'))
  })
}

export class IdbStore {
  static async open(name = DB) {
    const open = indexedDB.open(name, VERSION)
    open.onupgradeneeded = () => {
      const db = open.result
      db.createObjectStore('meta')
      db.createObjectStore('ops', { autoIncrement: true })
      db.createObjectStore('outbox', { keyPath: 'bseq' })
      db.createObjectStore('blobs')
    }
    const store = new IdbStore()
    store.db = await req(open)
    return store
  }

  tx(stores, mode = 'readonly') {
    return this.db.transaction(stores, mode)
  }

  async getMeta(key) { return req(this.tx('meta').objectStore('meta').get(key)) }
  async setMeta(key, value) {
    const tx = this.tx('meta', 'readwrite')
    tx.objectStore('meta').put(value, key)
    return done(tx)
  }
  async loadOps() {
    return (await req(this.tx('ops').objectStore('ops').getAll())).map(r => (typeof r === 'string' ? r : r.ops))
  }
  async appendLocalOps(opsJson) {
    const tx = this.tx('ops', 'readwrite')
    const key = req(tx.objectStore('ops').add({ ops: opsJson, local: true }))
    await done(tx)
    return key
  }
  async commitBatch(batch, upToKey) {
    const tx = this.tx(['outbox', 'meta'], 'readwrite')
    tx.objectStore('outbox').put(batch)
    tx.objectStore('meta').put(batch.bseq + 1, 'nextBseq')
    tx.objectStore('meta').put(upToKey, 'batchedUpTo')
    return done(tx)
  }
  async unbatchedLocalOps() {
    const from = (await this.getMeta('batchedUpTo')) || 0
    const tx = this.tx('ops')
    const range = IDBKeyRange.lowerBound(from, true)
    const [keys, rows] = await Promise.all([req(tx.objectStore('ops').getAllKeys(range)), req(tx.objectStore('ops').getAll(range))])
    return rows.map((r, i) => ({ key: keys[i], ...(typeof r === 'string' ? { ops: r, local: false } : r) })).filter(r => r.local)
  }
  async addLocal(opsJson, batch) {
    await this.commitBatch(batch, await this.appendLocalOps(opsJson))
  }
  async listOutbox() { return req(this.tx('outbox').objectStore('outbox').getAll()) } // key order = bseq
  async deleteOutbox(bseq) {
    const tx = this.tx('outbox', 'readwrite')
    tx.objectStore('outbox').delete(bseq)
    return done(tx)
  }
  async commitPull(opsJsonList, cursor) {
    const tx = this.tx(['ops', 'meta'], 'readwrite')
    for (const ops of opsJsonList) tx.objectStore('ops').add({ ops, local: false })
    tx.objectStore('meta').put(cursor, 'cursor')
    return done(tx)
  }
  async putBlob(name, blob) {
    const tx = this.tx('blobs', 'readwrite')
    tx.objectStore('blobs').put(blob, name)
    return done(tx)
  }
  async getBlob(name) { return req(this.tx('blobs').objectStore('blobs').get(name)) }
  async pendingBlobs() {
    const tx = this.tx('blobs')
    const [keys, values] = await Promise.all([req(tx.objectStore('blobs').getAllKeys()), req(tx.objectStore('blobs').getAll())])
    return keys.map((name, i) => ({ name, blob: values[i] }))
  }
  async deleteBlob(name) {
    const tx = this.tx('blobs', 'readwrite')
    tx.objectStore('blobs').delete(name)
    return done(tx)
  }
}

export async function openStore() {
  try {
    if (typeof indexedDB !== 'undefined') return await IdbStore.open()
  } catch (e) {
    console.warn('IndexedDB unavailable, keeping the replica in memory only', e)
  }
  return new MemoryStore()
}
