# Spike 0e — pure core → wasm32-freestanding → browser

Date: 2026-09-25. Zig 0.16.0, Chromium 152 headless, node 26.

**Answer: yes.** A pure core (no `std.Io`, caller-passed allocator, bytes in and
bytes out) compiles unchanged to a native test binary and to wasm, and runs in
a browser page.

| Check | Result |
|---|---|
| `zig build test` (native) | 3/3 pass |
| `zig build web` → `zig-out/web/core.wasm` (ReleaseSmall, stripped) | **5,785 bytes** |
| `node node-test.mjs` | 8/8 pass; 1000 edits on a 205 KB note in ~93 ms (toy O(n) buffer) |
| Headless Chromium `--dump-dom` of `web/index.html` | 8/8 PASS |

What the 8 checks cover: umlauts, and emoji edited using JS `indexOf`/`length`;
UTF-16 length parity between JS and the core; a position inside a surrogate pair is
rejected, and so is one past the end; hashtag extraction, where headings, `##`,
`no#tag`, inline code and fenced code are not tags while umlaut and emoji tags are;
memory growth over a large edit loop. (`--virtual-time-budget` freezes
`performance.now()`, so the browser timing shows 0 ms; node has real numbers.)

## Recommended wasm interface for the real core

1. Handles = pointers to core structs, passed as u32 (JS applies `>>> 0` to every pointer).
2. JS encodes strings to UTF-8, `omj_alloc`s, copies them in, calls, then `omj_free`s in `finally`.
3. Every export returns an i32 status: 0 = ok, negative = a shared `Status` enum.
4. Owned results come back as `[u32 LE len][bytes]` and are freed with `omj_free_result`. Hot paths
   (current text) return a borrowed ptr + out-len, valid until the next edit.
5. Never cache a `Uint8Array` over `memory.buffer`: growth replaces the buffer.
6. Keep a few hot exports (local edit, read text, apply binary remote ops) plus one
   `omj_call(msg)` that speaks the **same message vocabulary as the daemon's
   JSON-lines protocol**, so the PWA and the QML plugin share one protocol and one test suite.

Zig 0.16 notes: the build needs `entry = .disabled` and `rdynamic = true`, and
`.strip` goes in `createModule`. The new `std.ArrayList` API (`.empty`, the allocator
passed to methods) and `std.heap.wasm_allocator` gave no trouble.

## Index units: UTF-16 at the API, UTF-8 in storage

QString/`TextArea` positions, JS strings and CodeMirror positions are all UTF-16
code units (confirmed for `TextArea` in spike 0c: an emoji advances the position by 2).
So **public positions are UTF-16**; the core converts at its edge and rejects
positions that split a surrogate pair. The real CRDT should store each run's
UTF-16 length so position lookup stays O(log n) (the approach Yjs takes).

Files: `build.zig`, `src/core.zig`, `src/wasm.zig`, `web/glue.js`, `web/index.html`, `node-test.mjs`.
