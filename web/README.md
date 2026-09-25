# omajot web app

The phone/tablet/desktop client: an installable PWA served by the hub at its
`https://…ts.net:8443` origin. It keeps a full replica in IndexedDB, runs the
same Zig core as the desktop (`core.wasm`), and syncs through the hub API
(docs/PROTOCOL.md §2). Works offline; changes sync when the hub is reachable.

```sh
zig build wasm            # repo root: builds zig-out/web/core.wasm
cd web && npm install
npm run build             # → web/dist (committed; the hub serves it with --web)
npm test                  # unit tests (node --test), incl. the real core.wasm
npm run e2e               # browser test against a real local hub (needs `zig build`)
```

Local development: `../zig-out/bin/omajot hub --port 8788 --data /tmp/omajot --no-auth --web dist`
and open http://127.0.0.1:8788/ (service workers and crypto.subtle need
localhost or https). `npm run watch` rebuilds on change; the hub reads `dist`
at startup, so restart it to pick up a build.

| File | |
|---|---|
| `src/app.js`, `app.css`, `icons.js` | UI: folders + tags → notes → editor; one pane on phones, three on wide screens |
| `src/editor.js`, `widgets.js` | CodeMirror 6 on markdown source; checkboxes and images inline; own undo history |
| `src/patch.js` | Port of `src/core/ot.zig` (patch/edit transform, remote wins ties) |
| `src/replica.js`, `store.js`, `sync.js` | Engine + IndexedDB + §2 sync (batching, chunked blobs, SSE doorbell, conflicts) |
| `src/engine-wasm.js` | core.wasm glue (§3) |
| `src/markdown.js`, `html2md.js`, `attach.js`, `model.js` | Preview renderer, paste conversion, attachments, list logic |
| `src/sw.js` | Offline shell + immutable attachment cache; never caches `/api/batches` or `/api/events` |
| `test/ios-selftest.html` | For iOS Safari in the simulator: copy next to `dist/index.html` on a hub, open, screenshot, delete |
