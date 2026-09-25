// Smoke test for core.wasm through its exports (docs/PROTOCOL.md §3).
// Run: zig build wasm && node src/wasm/smoke.mjs
import { readFileSync } from 'node:fs';

const bytes = readFileSync(new URL('../../zig-out/web/core.wasm', import.meta.url));
const { instance } = await WebAssembly.instantiate(bytes, {});
const x = instance.exports;
const enc = new TextEncoder();
const dec = new TextDecoder();

function withInput(str, fn) {
  const data = enc.encode(str);
  const ptr = x.omj_alloc(data.length) >>> 0;
  new Uint8Array(x.memory.buffer, ptr, data.length).set(data);
  try { return fn(ptr, data.length); } finally { x.omj_free(ptr, data.length); }
}

function take(res) {
  res >>>= 0;
  if (res === 0) throw new Error('out of memory');
  const len = new DataView(x.memory.buffer).getUint32(res, true);
  const s = dec.decode(new Uint8Array(x.memory.buffer, res + 4, len));
  x.omj_free_result(res);
  return s;
}

const lines = (s) => s.split('\n').filter(Boolean).map((l) => JSON.parse(l));
const call = (h, req) => lines(take(withInput(JSON.stringify(req), (p, n) => x.omj_call(h, p, n, Date.now()))));
const ingest = (h, ops) => lines(take(withInput(ops, (p, n) => x.omj_ingest(h, p, n))));
const newOps = (h) => take(x.omj_take_new_ops(h));

let failures = 0;
const check = (name, ok) => { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`); if (!ok) failures++; };

const a = x.omj_engine_new(0x11111111, 0xa);
const b = x.omj_engine_new(0x22222222, 0xb);
check('hello', call(a, { id: 1, cmd: 'hello', client: 'web' })[0].replica === '0000000a11111111');

const created = call(a, { id: 2, cmd: 'create', folder: null, text: 'Grüße 🎉\n#tag body' });
const note = created[0].note;
check('create replies with a note id', /^n-[0-9a-f]{16}-\d+$/.test(note));
check('create emits a notes event', created.some((l) => l.ev === 'notes'));

const opsA = newOps(a);
const evB = ingest(b, opsA);
check('ingest emits the summary on the other replica', evB.some((l) => l.ev === 'notes' && l.upsert[0].title === 'Grüße 🎉'));

const opened = call(b, { id: 3, cmd: 'open', note })[0];
check('open returns the text', opened.text === 'Grüße 🎉\n#tag body');

// A edits: insert after the emoji (JS UTF-16 index), B has the note open.
const pos = 'Grüße 🎉'.length;
call(a, { id: 4, cmd: 'edit', note, seq: 1, pos, del: 0, ins: '!' });
const patch = ingest(b, newOps(a)).find((l) => l.ev === 'patch');
check('open note receives a patch at the JS index', patch && patch.pos === pos && patch.ins === '!');
check('B tags', call(b, { id: 5, cmd: 'list' })[0].notes[0].tags[0] === 'tag');
check('nothing pending', x.omj_pending(b) === 0);

x.omj_engine_free(a);
x.omj_engine_free(b);
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
