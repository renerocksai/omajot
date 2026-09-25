// Loads the real core.wasm for tests: `engineFactory(hex)` gives a fresh
// engine instance per replica. Build it first with `zig build wasm`.
import { readFileSync, existsSync } from 'node:fs'
import { WasmEngine, REQUIRED_EXPORTS } from '../src/engine-wasm.js'

const candidates = [new URL('../../zig-out/web/core.wasm', import.meta.url), new URL('../dist/core.wasm', import.meta.url)]
const path = candidates.find(u => existsSync(u))
if (!path) throw new Error('core.wasm not found: run `zig build wasm` in the repo root')
const module = new WebAssembly.Module(readFileSync(path))
const missing = REQUIRED_EXPORTS.filter(n => !WebAssembly.Module.exports(module).some(e => e.name === n))
if (missing.length) throw new Error('core.wasm lacks exports: ' + missing.join(', '))

export function engineFactory(hex) {
  return new WasmEngine(new WebAssembly.Instance(module, {}).exports, hex)
}
