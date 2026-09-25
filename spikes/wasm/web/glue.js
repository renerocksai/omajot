// Thin JS glue over core.wasm. Works in browsers and in node (ES module).
// Positions passed to edit() are plain JS string indices (UTF-16 code units);
// the core converts them to UTF-8 byte offsets, so JS never converts.

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8", { fatal: true });

const STATUS = ["ok", "out_of_memory", "out_of_range", "splits_surrogate_pair", "invalid_utf8", "bad_handle"];

export async function loadCore(wasmBytes) {
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});
  const x = instance.exports;
  // memory.buffer is replaced whenever linear memory grows: never cache a view.
  const u8 = () => new Uint8Array(x.memory.buffer);
  const scratch = x.omj_alloc(4) >>> 0; // out-param slot for lengths

  function withBytes(str, fn) {
    const bytes = enc.encode(str);
    const ptr = bytes.length ? x.omj_alloc(bytes.length) >>> 0 : 0;
    if (bytes.length && !ptr) throw new Error("out_of_memory");
    u8().set(bytes, ptr);
    try { return fn(ptr, bytes.length); } finally { if (bytes.length) x.omj_free(ptr, bytes.length); }
  }

  function takeResult(ptr) {
    ptr >>>= 0;
    if (!ptr) throw new Error("out_of_memory");
    const len = new DataView(x.memory.buffer).getUint32(ptr, true);
    const text = dec.decode(u8().slice(ptr + 4, ptr + 4 + len));
    x.omj_free_result(ptr);
    return text;
  }

  class Buffer {
    constructor() {
      this.h = x.omj_buffer_new() >>> 0;
      if (!this.h) throw new Error("out_of_memory");
    }
    edit(pos, del, ins) {
      const rc = withBytes(ins, (p, n) => x.omj_buffer_edit(this.h, pos, del, p, n));
      if (rc < 0) throw new Error(STATUS[-rc] ?? `status ${rc}`);
    }
    text() {
      const ptr = x.omj_buffer_text(this.h, scratch) >>> 0;
      const len = new DataView(x.memory.buffer).getUint32(scratch, true);
      return dec.decode(u8().slice(ptr, ptr + len)); // copy: the view is borrowed
    }
    free() { x.omj_buffer_free(this.h); this.h = 0; }
  }

  return {
    Buffer,
    hashtags: (s) => { const t = withBytes(s, (p, n) => takeResult(x.omj_hashtags(p, n))); return t ? t.split("\n") : []; },
    memoryBytes: () => x.memory.buffer.byteLength,
  };
}

// Shared checks, run by index.html and node-test.mjs.
export function runChecks(core) {
  const results = [];
  const check = (name, fn) => {
    try { const r = fn(); results.push({ name, ok: r === true, detail: r === true ? "" : String(r) }); }
    catch (e) { results.push({ name, ok: false, detail: e.message }); }
  };
  const eq = (got, want) => got === want || `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`;

  const b = new core.Buffer();
  check("insert umlauts", () => { b.edit(0, 0, "Grüße"); return eq(b.text(), "Grüße"); });
  check("append emoji at JS index", () => { const t = b.text(); b.edit(t.length, 0, " 🎉!"); return eq(b.text(), "Grüße 🎉!"); });
  check("replace emoji using JS indexOf/length", () => {
    const t = b.text(); const i = t.indexOf("🎉"); b.edit(i, "🎉".length, "✓"); return eq(b.text(), "Grüße ✓!");
  });
  check("JS string length == core UTF-16 length", () => eq(b.text().length, 8));
  check("mid-surrogate position rejected", () => {
    const c = new core.Buffer(); c.edit(0, 0, "a🎉b");
    try { c.edit(2, 0, "x"); return "no error"; } catch (e) { return eq(e.message, "splits_surrogate_pair"); } finally { c.free(); }
  });
  check("out of range rejected", () => { try { b.edit(99, 0, "x"); return "no error"; } catch (e) { return eq(e.message, "out_of_range"); } });
  check("hashtags", () => eq(JSON.stringify(core.hashtags(
    "# Heading\nShopping #einkauf and #Grüße, also #🎉party\n`#code` no#tag #work/omajot\n```\n#fenced\n```\n#einkauf")),
    JSON.stringify(["einkauf", "Grüße", "🎉party", "work/omajot"])));
  check("200 KB note + 1000 edits (memory growth, fresh views)", () => {
    const big = new core.Buffer();
    const line = "Zeile mit Ümlaut und 🎉 emoji\n";
    big.edit(0, 0, line.repeat(7000));
    const t0 = performance.now();
    // Line starts, back to front so earlier offsets stay valid; worst case for a
    // flat buffer is the O(n) scan per edit, which the real CRDT replaces.
    for (let i = 999; i >= 0; i--) big.edit(i * 7 * line.length, 0, "ä");
    const ms = performance.now() - t0;
    const ok = big.text().length === "Zeile mit Ümlaut und 🎉 emoji\n".length * 7000 + 1000;
    big.free();
    globalThis.__bigEditMs = ms;
    return ok || `length mismatch after ${ms.toFixed(1)} ms`;
  });
  b.free();
  return results;
}
