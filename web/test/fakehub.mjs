// An in-memory implementation of the hub API (docs/PROTOCOL.md §2) for tests
// and local development: a `fetch` adapter, a fake EventSource, and an HTTP
// server (`node test/fakehub.mjs --port 8788 --web dist`) that also serves
// the PWA. The real hub is `omajot hub`.
import { createHash } from 'node:crypto'

export class FakeHub {
  constructor() {
    this.batches = [] // Stored
    this.byKey = new Map() // "replica/bseq" → seq
    this.lastBseq = new Map()
    this.blobs = new Map()
    this.partial = new Map() // name → { total, chunks: Buffer[] , received }
    this.maxBody = 1024 * 1024
    this.sources = new Set()
    this.down = false
  }

  get head() { return this.batches.length }

  // Returns { status, json?, body?, headers? }.
  handle(method, url, body) {
    if (this.down) return { status: 503, json: { error: 'down' } }
    const u = new URL(url, 'http://hub/')
    const path = u.pathname.replace(/^\/+/, '/')
    if (method === 'GET' && path === '/api/whoami') return { status: 200, json: { login: 'test@example.com', name: 'Test', head: this.head } }
    if (method === 'POST' && path === '/api/batches') {
      const b = JSON.parse(body)
      const key = b.replica + '/' + b.bseq
      if (this.byKey.has(key)) return { status: 200, json: { seq: this.byKey.get(key), head: this.head } }
      const last = this.lastBseq.get(b.replica) || 0
      if (b.bseq !== last + 1) return { status: 409, json: { error: `bseq ${b.bseq} after ${last}` } }
      const seq = this.batches.length + 1
      this.batches.push({ ...b, seq })
      this.byKey.set(key, seq)
      this.lastBseq.set(b.replica, b.bseq)
      for (const s of this.sources) s.ring(this.head)
      return { status: 200, json: { seq, head: this.head } }
    }
    if (method === 'GET' && path === '/api/batches') {
      const after = +u.searchParams.get('after') || 0
      const limit = Math.min(+u.searchParams.get('limit') || 1000, 1000)
      return { status: 200, json: { head: this.head, batches: this.batches.slice(after, after + limit) } }
    }
    const blob = /^\/api\/blobs\/([0-9a-f]{64})\.([a-z0-9]+)$/.exec(path)
    if (body && body.length > this.maxBody) return { status: 413, json: { error: 'body too large' } }
    if (blob && method === 'PUT' && u.searchParams.has('offset')) {
      const name = blob[1] + '.' + blob[2]
      const offset = +u.searchParams.get('offset'), total = +u.searchParams.get('total')
      if (this.blobs.has(name)) return { status: 200, json: { received: total } }
      const part = this.partial.get(name) || { total, chunks: [], received: 0 }
      if (offset !== part.received) return { status: 409, json: { received: part.received } }
      part.chunks.push(Buffer.from(body))
      part.received += body.length
      this.partial.set(name, part)
      if (part.received < total) return { status: 202, json: { received: part.received } }
      this.partial.delete(name)
      const all = Buffer.concat(part.chunks)
      if (createHash('sha256').update(all).digest('hex') !== blob[1]) return { status: 400, json: { error: 'sha256 mismatch' } }
      this.blobs.set(name, all)
      return { status: 201, json: {} }
    }
    if (blob && method === 'PUT') {
      const bytes = Buffer.from(body)
      if (createHash('sha256').update(bytes).digest('hex') !== blob[1]) return { status: 400, json: { error: 'sha256 mismatch' } }
      const had = this.blobs.has(blob[1] + '.' + blob[2])
      this.blobs.set(blob[1] + '.' + blob[2], bytes)
      return { status: had ? 200 : 201, json: {} }
    }
    if (blob && method === 'GET') {
      const bytes = this.blobs.get(blob[1] + '.' + blob[2])
      return bytes ? { status: 200, body: bytes, headers: { 'cache-control': 'public, max-age=31536000, immutable' } }
        : { status: 404, json: { error: 'no blob' } }
    }
    return { status: 404, json: { error: 'not found' } }
  }

  // A fetch(url, init) for SyncClient.
  fetch = async (url, init = {}) => {
    let body = init.body
    if (body && typeof body !== 'string') body = Buffer.from(await new Response(body).arrayBuffer())
    const r = this.handle(init.method || 'GET', url, body)
    const payload = r.body ?? JSON.stringify(r.json ?? {})
    return new Response(payload, { status: r.status, headers: r.headers })
  }

  // An EventSource class bound to this hub.
  get EventSource() {
    const hub = this
    return class FakeEventSource {
      constructor() {
        this.readyState = 1
        this.listeners = []
        hub.sources.add(this)
        queueMicrotask(() => {
          this.onopen?.()
          if (hub.head > 0) this.ring(hub.head)
        })
      }
      addEventListener(type, fn) { if (type === 'head') this.listeners.push(fn) }
      ring(head) { for (const fn of this.listeners) fn({ data: JSON.stringify({ head }), lastEventId: String(head) }) }
      close() { this.readyState = 2; hub.sources.delete(this) }
    }
  }
}

// ------------------------------------------------------------ HTTP server
// Dev/e2e only: serves §2 (no auth) plus static files from --web.
async function serve() {
  const http = await import('node:http')
  const fs = await import('node:fs/promises')
  const pathMod = await import('node:path')
  const args = process.argv.slice(2)
  const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def }
  const port = +opt('--port', 8788)
  const web = pathMod.resolve(opt('--web', 'dist'))
  const hub = new FakeHub()
  const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm',
    '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml', '.json': 'application/json' }
  const streams = new Set()
  hub.sources.add({ ring: (head) => { for (const res of streams) res.write(`event: head\nid: ${head}\ndata: {"head":${head}}\n\n`) } })

  http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x')
    if (url.pathname === '/api/events') {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store' })
      const cursor = +(req.headers['last-event-id'] || 0)
      if (hub.head > cursor) res.write(`event: head\nid: ${hub.head}\ndata: {"head":${hub.head}}\n\n`)
      streams.add(res)
      const beat = setInterval(() => res.write(':\n\n'), 15000)
      req.on('close', () => { clearInterval(beat); streams.delete(res) })
      return
    }
    if (url.pathname.startsWith('/api/')) {
      const chunks = []
      for await (const c of req) chunks.push(c)
      const body = Buffer.concat(chunks)
      const r = hub.handle(req.method, req.url, req.method === 'PUT' ? body : body.toString())
      res.writeHead(r.status, { 'content-type': r.body ? 'application/octet-stream' : 'application/json', ...(r.headers || {}) })
      return res.end(r.body ?? JSON.stringify(r.json ?? {}))
    }
    let file = pathMod.join(web, url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname))
    if (!file.startsWith(web)) { res.writeHead(403); return res.end() }
    try {
      const data = await fs.readFile(file)
      res.writeHead(200, { 'content-type': types[pathMod.extname(file)] || 'application/octet-stream', 'cache-control': 'no-cache' })
      res.end(data)
    } catch {
      res.writeHead(404)
      res.end('not found')
    }
  }).listen(port, '127.0.0.1', () => console.log(`fakehub on http://127.0.0.1:${port}/ serving ${web}`))
}

if (import.meta.url === `file://${process.argv[1]}`) serve()
