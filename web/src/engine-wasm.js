// core.wasm glue (docs/PROTOCOL.md §3, pattern from spikes/wasm/REPORT.md).
//
// The engine is synchronous: every call returns the reply and any events at
// once, so the browser never has edits in flight while a patch is computed.
//
// Rules: pointers are unsigned (`>>> 0`); never keep a Uint8Array/DataView
// over memory.buffer across a call (memory growth replaces the buffer);
// results are [u32 LE length][bytes] and must be freed with omj_free_result.

const enc = new TextEncoder()
const dec = new TextDecoder()

export const REQUIRED_EXPORTS = ['memory', 'omj_alloc', 'omj_free', 'omj_engine_new', 'omj_call', 'omj_ingest',
  'omj_take_new_ops', 'omj_free_result']

export function parseLines(text) {
  const out = []
  for (const line of text.split('\n')) if (line.trim()) out.push(JSON.parse(line))
  return out
}

export function replicaHalves(hex) {
  if (!/^[0-9a-f]{16}$/.test(hex)) throw new Error('replica id must be 16 hex chars')
  return [parseInt(hex.slice(8), 16) >>> 0, parseInt(hex.slice(0, 8), 16) >>> 0] // [lo, hi]
}

// Stub every import the module asks for, so a core built with extra imports
// (logging, panics) still instantiates; calls to them are logged.
function importsFor(module) {
  const imports = {}
  for (const imp of WebAssembly.Module.imports(module)) {
    imports[imp.module] ??= {}
    if (imp.kind === 'function') {
      imports[imp.module][imp.name] = (...args) => console.warn('core.wasm import called', imp.module, imp.name, args)
    }
  }
  return imports
}

export async function instantiateCore(bytes) {
  const module = await WebAssembly.compile(bytes)
  const instance = await WebAssembly.instantiate(module, importsFor(module))
  const missing = REQUIRED_EXPORTS.filter(n => !(n in instance.exports))
  return { exports: instance.exports, missing }
}

export class WasmEngine {
  constructor(exports, replicaHex, now = () => Date.now()) {
    this.x = exports
    this.now = now
    const [lo, hi] = replicaHalves(replicaHex)
    this.handle = this.x.omj_engine_new(lo, hi) >>> 0
    if (this.handle === 0) throw new Error('omj_engine_new failed')
    this.kind = 'wasm'
  }

  // Copies a string into wasm memory; returns [ptr, len].
  input(str) {
    const bytes = enc.encode(str)
    const len = Math.max(bytes.length, 1)
    const ptr = this.x.omj_alloc(len) >>> 0
    if (ptr === 0) throw new Error('core.wasm out of memory')
    new Uint8Array(this.x.memory.buffer, ptr, bytes.length).set(bytes)
    return [ptr, len, bytes.length]
  }

  result(r) {
    const ptr = r >>> 0
    if (ptr === 0) throw new Error('core.wasm out of memory')
    const len = new DataView(this.x.memory.buffer).getUint32(ptr, true)
    const text = dec.decode(new Uint8Array(this.x.memory.buffer, ptr + 4, len).slice())
    this.x.omj_free_result(ptr)
    return text
  }

  withInput(str, fn) {
    const [ptr, alloc, len] = this.input(str)
    try {
      return fn(ptr, len)
    } finally {
      this.x.omj_free(ptr, alloc)
    }
  }

  call(request) {
    const text = this.withInput(JSON.stringify(request), (p, l) =>
      this.result(this.x.omj_call(this.handle, p, l, this.now())))
    return parseLines(text)
  }

  ingest(opsJson) {
    const text = this.withInput(opsJson, (p, l) => this.result(this.x.omj_ingest(this.handle, p, l)))
    return parseLines(text)
  }

  takeNewOps() {
    return this.result(this.x.omj_take_new_ops(this.handle))
  }
}

// Loads core.wasm and checks the engine answers `hello`. Throws with a
// readable reason when the wasm is missing, incomplete or a stub.
export async function loadWasmEngine(url, replicaHex) {
  const res = await fetch(url)
  if (!res.ok) throw new Error(`core.wasm: HTTP ${res.status}`)
  const { exports, missing } = await instantiateCore(await res.arrayBuffer())
  if (missing.length) throw new Error('core.wasm lacks exports: ' + missing.join(', '))
  const engine = new WasmEngine(exports, replicaHex)
  const reply = engine.call({ id: 0, cmd: 'hello', client: 'web' }).find(l => l.re === 0)
  if (!reply || !reply.ok) throw new Error('core.wasm engine not ready: ' + (reply?.error || 'no reply'))
  engine.version = reply.version
  return engine
}
