# omajot — design notes

Status: design agreed 2026-09-25; spikes done; the first real build is under way.
This file records what was decided and why, so later sessions do not reopen it.
The interfaces every part is built against are in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## What omajot is

A small, markdown-focused notes app that replaces **Joplin**, **omajop** and
**Apple Notes** for one person across Linux, macOS and iOS devices.

- An Omarchy shell plugin in the look of omajop: a **bar dropdown** for quick
  notes, plus a bigger **main window**, operable entirely from either.
- Notes are **editable** (omajop is read-only, which is the main complaint).
- No dependency on a running Joplin, and no dependency on Dropbox.
- A home-screen-installable **web app** for the phone and iPad.

Why not keep omajop: it reads Joplin's database, so synced notes only appear
if the Joplin app runs and syncs with Dropbox, and nothing can be edited.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Topology | **One Zig hub in the center**, every device a client that keeps a full replica | Simplest mental model; no third-party storage |
| Hub host | an always-on Mac (for the author: a headless M3 Max), run by hand in **tmux / herdr** for now | The only always-on machine in the tailnet; no service setup needed yet |
| Network | **Tailscale** (`tailscale serve` provides HTTPS on `*.ts.net`) | Private, encrypted, real certs so the PWA works |
| Dropbox | **Not used.** A Dropbox adapter may come later | "Nothing ever stored in Dropbox" |
| Conflict handling | **CRDT**, written in Zig | Laptop and phone edit the same note offline |
| Backend language | **Zig 0.16** (juicy main, `std.Io` passed explicitly) | Owner's preference; the same core compiles to wasm |
| Desktop UI | **Pure QML/JS** plugin, no compiled QML modules | omarchy-shell loads plain QML; a `.so` would break on every Arch Qt update |
| Web app | Static PWA served **by the hub**, core compiled to **wasm** | Offline-capable on the phone; one CRDT implementation everywhere |
| Editor | **Markdown source + preview** (toggle / split), not WYSIWYG | Pure QML has no syntax highlighter; Qt's rich-text markdown round-trip rewrites the source and would create fake edits |
| HTTP server | **baz** (on bounded/http) | Our own Zig 0.16 framework; see "What we take from baz" |
| Rejected | C++, Rust, Go, Electron | C++/Rust: owner dislikes them. Go: loses the shared wasm core |

### Why a hub, and not peer-to-peer over Tailscale

Tailscale is a network, not storage: two peers only sync while both are
awake and reachable at the same time. An iOS PWA only runs in the foreground
and laptops sleep, so peer-to-peer sync would feel broken ("I edited on the
train and the laptop never saw it"). An always-on hub stores and forwards,
so phone edits reach the hub whenever the phone is online, and the laptop
catches up whenever it wakes.

### Why still a CRDT with a central hub

The hub orders operations but cannot prevent **concurrent edits made offline**:
edit a note on the laptop on a plane and the same note on the phone, then
both sync. The CRDT merges both edits deterministically, with no conflict
copies and no conflict markers. (Two edits to the same spot end up side by side.)
When nothing is edited concurrently, the CRDT does nothing but costs nothing.

### Why every client keeps a full replica

- Works offline (laptop on a plane, phone without signal, hub rebooting).
- Instant search and note switching, with no round-trip.
- The hub API stays tiny: it only moves operations and blobs (see below).

## Architecture

```
                         tailnet (WireGuard)
   ┌──────────────────────────────────────────────────────────────┐
   │                                                              │
   │  your-mac (always on)                                        │
   │  ┌────────────────────────────────────────────┐              │
   │  │ tailscale serve  https://…ts.net → 127.0.0.1:PORT          │
   │  │ omajot hub  (baz, loopback only)           │              │
   │  │   op log (append-only) · blob store         │              │
   │  │   embedded PWA assets · .md mirror (backup) │              │
   │  └────────────────────────────────────────────┘              │
   │        ▲ POST ops / GET ops / SSE doorbell / blobs            │
   │        │                                                     │
   │  ┌─────┴───────────────────┐     ┌──────────────────────────┐ │
   │  │ Omarchy laptop           │     │ iPhone / iPad / Macs     │ │
   │  │ omajot daemon (Zig)      │     │ PWA (browser)            │ │
   │  │   replica + core         │     │   replica in OPFS/IDB    │ │
   │  │   hub client, paste      │     │   core.wasm              │ │
   │  │      ▲ JSON lines (stdio)│     │   CodeMirror 6 editor    │ │
   │  │ omarchy-shell plugin     │     └──────────────────────────┘ │
   │  │   bar dropdown · window  │                                  │
   │  └──────────────────────────┘                                  │
   └──────────────────────────────────────────────────────────────┘
```

Three roles, one codebase:

1. **core** (`src/core`) — pure Zig: CRDT, note model, op encoding, markdown
   helpers (title, hashtags), HTML→markdown. **No `std.Io`, no allocation
   policy of its own** (the caller passes the allocator), bytes in and bytes out.
   This keeps it wasm-compatible and unit-testable.
2. **hub** (`omajot hub`) — baz app on the M3 Max. Stores and relays ops, serves
   blobs and the PWA. Could be a dumb relay; it also runs the core to write
   a readable `.md` mirror (a backup that Time Machine can cover).
3. **clients** — the Linux daemon (`omajot daemon`) behind the QML plugin, and
   the PWA running `core.wasm`. Both hold a replica and sync with the hub.

One binary with subcommands (zli + `std.process.Init`, as in baz's examples):
`omajot hub`, `omajot daemon`, `omajot import-joplin`, …

## Data model

- **Replica id**: random 64-bit per device install. **Op id** = (replica, counter).
- **Note**: created by an op; its id is that op's id.
  - `body`: text CRDT (see below).
  - `folder`, `pinned`, `trashed`: last-writer-wins registers, ordered by a
    **hybrid logical clock**, with the replica id as tie-breaker.
  - **Title = first line of the body** (Apple Notes style). There is no separate
    title field, so there is nothing to conflict on.
- **Folder**: id, `name` LWW, `parent` LWW (nested, as in Joplin notebooks).
  Concurrent moves can create cycles; resolve deterministically when
  materializing (open detail).
- **Tags**: **inline `#hashtags` in the body** (Apple Notes style; decided):
  markdown-native, visible in the `.md` mirror, no extra CRDT. The tag UI from
  omajop (tag list in the sidebar, tag chips) is derived from the body; adding a
  tag in the UI appends `#tag`.
- **Attachments**: content-addressed, `attachments/<sha256>.<ext>`, immutable.
  Notes reference them with a **relative** link `![](attachments/<sha256>.png)`,
  which works in the QML preview (`baseUrl` = replica dir), in the `.md`
  mirror, and in the PWA (served by the hub and cached by the service worker).
  So pasted images never become broken links.

### Text CRDT

No usable library exists for us (Yjs is JavaScript; Automerge, Loro and yrs are
Rust), so we write one in Zig:

- A sequence CRDT from the RGA/**Fugue** family (Fugue avoids interleaving
  concurrent insertions), **run-length encoded** so typing a sentence is one
  run, not one node per character. Evaluate eg-walker later if memory matters.
- Local edits arrive as `{pos, del, ins}` with **UTF-16** positions (what every
  editor speaks); runs store their UTF-16 length so lookups stay O(log n).
- **Property tests are the core of the project**: N simulated replicas make
  random concurrent edits, exchange ops in random order with duplicates, and
  must converge to identical text. Plus fuzzing of the op decoder.

## Sync protocol (hub HTTP API)

The hub assigns every accepted op batch a monotonically increasing **hub
sequence number**. Clients remember the last hub seq they have applied (their
cursor). Ops are deduplicated by op id, so every call is idempotent and safe to retry.

| Endpoint | Purpose |
|---|---|
| `POST /api/ops` | Push a batch of local ops. Durably appended (fsync) before `200`. Returns the new head seq. |
| `GET /api/ops?after=N&limit=M` | Paged catch-up, bounded response size. |
| `GET /api/events` | **SSE doorbell**: `id:` = head seq, data = "head is now N". The client then pulls with `GET /api/ops`. Resumes with `Last-Event-ID`. |
| `PUT /api/blobs/<sha256>` | Upload an attachment; the hub verifies the hash. Idempotent. |
| `GET /api/blobs/<sha256>` | Download; `Cache-Control: immutable`. |
| `GET /api/snapshot` | *(later)* Fast bootstrap for a new device. |
| `GET /` … | The PWA, embedded into the binary. |

Why SSE as a doorbell instead of pushing ops through the stream:

- baz has no WebSockets (they need an engine upgrade lifecycle).
- baz's request deadline covers the whole stream, so SSE connections end and
  reconnect periodically. A doorbell carrying only a number makes reconnects
  harmless, and browsers' `EventSource` reconnects with `Last-Event-ID` on its own.
- SSE events stay tiny, so they fit baz's bounded staging buffers. Bulk data
  goes through ordinary paged GETs.

Verified in `spikes/hub/REPORT.md`, on a Linux laptop and on the M3 Max itself (kqueue),
including **iOS Safari 26.5** resuming across three deadline reconnects with nothing missed:
serve does not buffer SSE (~18 ms POST→event), identity headers arrive even from
the same node and can't be spoofed through serve, and `Last-Event-ID` resume works.
Rules that came out of it:

- The hub `.finish`es each SSE stream a few seconds **before** `server.timeout_ms`.
  Otherwise baz cuts the chunked body and the Zig client sees `error.ReadFailed`;
  clients treat that error as "reconnect" anyway.
- A doorbell can arrive before the POST response and cover several ops: clients
  compare heads (`head ≥ H`), never count events.
- The first HTTPS request after `tailscale serve` waits ~30 s for the certificate; warm it up once.
- Zig 0.16 on Linux links with `use_llvm`/`use_lld` (its own linker rejects GCC 16's `crt1.o`).

Live typing on two devices at once still works: the editor sends ops every
~300 ms, and the doorbell tells the other device to pull.

### Auth

- The hub listens on **127.0.0.1 only** (baz's default); only `tailscale serve`
  reaches it.
- `tailscale serve` adds identity headers (`Tailscale-User-Login`) for requests
  from tailnet user devices; a baz **middleware** rejects everything except the
  configured login. No passwords, no tokens, no login screen.
- Caveat: any local process on the Mac could reach the loopback port and
  forge the header. Acceptable for a single-user Mac.
- Never enable Tailscale Funnel for this.

## Desktop client (Omarchy)

- **Plugin** (repo root, like omajop: `manifest.json`, `Service.qml`,
  `BarWidget.qml`, `Panel.qml`). Kinds: `service`, `bar-widget`, `panel`,
  following neomarchy, which already uses `FloatingWindow` + `IpcHandler`.
  - **Bar dropdown**: quick capture (opens with a new note focused), search,
    pinned and recent notes, inline editing.
  - **Main window**: `FloatingWindow`, omajop's three columns (folders + tags │
    notes │ editor), Apple Notes look, opened from a Hyprland keybinding or a
    `.desktop` entry via `qs ipc call`.
- **Daemon**: `Service.qml` spawns and supervises `omajot daemon` and talks to
  it with **JSON lines over stdin/stdout** (the neomarchy `Process` pattern).
  Both surfaces live in the same shell process, so one pipe is enough. A unix
  socket can come later if a CLI needs to talk to a running daemon.
- **Editor ↔ CRDT** (verified in `spikes/qml/REPORT.md`): QML `TextArea` gives no
  deltas, so the JS side diffs old vs new text (common prefix/suffix, ~7 ms per
  keystroke on a 200 KB note) and sends `{pos, del, ins}`. Remote changes come back
  as positional patches applied with `insert()`/`remove()`; cursor and selection
  shift correctly. Remote patches are guarded by a flag so they aren't echoed back.
- **Undo/redo is omajot's own**: the built-in `TextArea` undo also reverts
  *remote* patches (verified). Ctrl+Z / Ctrl+Y are intercepted in `Keys.onPressed`,
  and undo inverts only this device's own ops.
- **Positions are UTF-16 code units** everywhere at the API (QString, JS,
  CodeMirror); the core stores UTF-8 and converts at its edge (spikes 0c and 0e).
- **Apple-Notes feel with small JS helpers**: continue lists and checkboxes on
  Enter, clicking a checkbox in the preview toggles it in the source,
  Ctrl+B / Ctrl+I, `#tag` completion.
- **Preview**: `Text.MarkdownText` (omajop already renders with it); local
  images load via `baseUrl`.
- **Binary distribution**: `omarchy plugin add` only clones the repo and stock
  Omarchy has no Zig, so publish GitHub release binaries and have the plugin
  download the one whose sha256 is pinned in the repo.

### Paste (desktop)

QML's clipboard only exposes plain text, so Ctrl+V asks the daemon, which runs
`wl-paste --list-types` and applies **its own priority** (the order `--list-types`
prints is not a preference; Chromium lists `text/html` before `image/png`).
Verified in `spikes/paste/REPORT.md`:

1. `image/*` → `attachments/<sha256>.<ext>`, uploaded to the hub, inserts `![](…)`.
   Only present for real image copies, never for mixed selections.
2. `text/uri-list` (files copied in a file manager) → copied in as attachments.
3. `text/markdown` → used as-is. LibreOffice 26.8 offers it, and it is better than
   its HTML, which drops images entirely.
4. `text/html` → markdown (lists, links, headings, emphasis, code, quotes,
   tables, `<input type=checkbox>` → `- [x]`). Chromium's HTML carries heavy
   inline `style` noise; ignore attributes except `href`, `src`, `checked`.
5. `text/plain`.

`text/rtf` is always offered alongside HTML/markdown, so there is no RTF parser.
For markdown and HTML, image references are post-processed: `data:` URIs are
decoded and `file://` paths are copied into attachments. Remote images are
downloaded, like Apple Notes does (decided).

The HTML→markdown converter lives in **core** (a small tolerant tokenizer that
only handles the tags above), so the PWA can reuse it. If it gets hairy, lexbor
(C) through `zig build` is the fallback.

## Web app (PWA)

- Served by the hub from assets embedded in the binary (`@embedFile` +
  baz `borrowBody`), at the hub's `https://…ts.net` origin. No GitHub Pages.
- `core.wasm` (wasm32-freestanding) plus a thin TypeScript glue layer. The
  interface pattern is in `spikes/wasm/REPORT.md`: status codes, length-prefixed
  results, and one `omj_call(msg)` that speaks the daemon's JSON-lines vocabulary,
  so desktop and PWA share one protocol.
- Replica in OPFS / IndexedDB; service worker caches the app shell, so it opens
  offline and syncs when Tailscale is connected.
- Editor: **CodeMirror 6** (good markdown source editing on mobile), preview
  with a small markdown renderer. Paste and camera images become attachments.
- iOS: Safari may evict website storage after ~7 days without use unless the
  app is on the home screen; the hub holds everything anyway.

## What we take from baz and bounded/http

Both repos: `~/code/github.com/technologylab.ai/{baz,bounded-http}`, Zig 0.16.0,
Linux io_uring / **macOS kqueue** / Windows IOCP. The hub runs on macOS, and
baz's benchmarks were taken on an M3 Max, the same model as our hub.

omajot is also meant to be **baz's showcase application**: a real app on
baz, served over HTTPS by `tailscale serve`. Improvements found here go upstream
to baz (e.g. per-route deadlines for SSE routes, an HTTPS example).

Use directly:

- **baz as the hub's HTTP framework**, pinned by URL and hash in
  `build.zig.zon` the way baz pins bounded_http.
- **`baz.sse`** encoder (`write`, `heartbeat`) for the doorbell.
- **Notifications + typed continuations** for waiting SSE clients: `POST
  /api/ops` appends, then signals every subscriber's notification handle;
  subscribers wake, read the head, and emit one doorbell event. This is the
  `examples/jobs.zig` pattern: producer signals, `Last-Event-ID` replay, 409
  when history is gone. For us, 409 means "cursor older than compaction,
  fetch a snapshot".
- **Middleware with typed locals** for the Tailscale identity check.
- **`borrowBody`** for serving embedded PWA assets and immutable blobs.
- **zli + `std.process.Init`** for the CLI.

Borrow as practice:

- TigerStyle **explicit limits**: max note size, max ops per batch, max blob size,
  max subscribers, all as named constants with tests at the bounds.
- The docs habits: `AGENTS.md`, `HANDOFF.md` between sessions, dated receipts.

Constraints to design around:

| baz limit | Consequence for omajot |
|---|---|
| No WebSockets | POST + SSE doorbell (above) |
| No TLS | `tailscale serve` terminates TLS; the hub listens on loopback |
| `server.timeout_ms` covers the whole request, including streams | SSE reconnects periodically; set it to ~60 s |
| Connection storage and `max_body` are reserved up front | Cap blob size (e.g. 16 MiB, downscale huge images on paste) or chunk uploads; size `connections × max_body` for the Mac |
| `max_response_bytes` (16 MiB default) | Paged `GET /api/ops`; blob cap as above |
| Blocking app work needs fixed workers | Run with worker execution; op-log fsync happens there |

Not needed: bounded/http's engine directly (baz wraps it), Mustache (the PWA
renders on the client), a custom `std.Io` provider.

## Joplin import

Needed on day one so Joplin can be uninstalled. omajop's `Model.mjs` already
knows the schema. Read `~/.config/joplin-desktop/database.sqlite` and the
`resources/` dir: notebooks → folders (nested), notes → notes (Joplin title
becomes the first line if the body does not start with it), tags → `#hashtags`,
resources → attachments with `:/<resource-id>` links rewritten.

## Plan

0. **Spikes** — all done 2026-09-25 (reports in `spikes/*/REPORT.md`):
   - baz hub on macOS behind `tailscale serve`: SSE through the proxy, identity
     header present, `EventSource` reconnect with `Last-Event-ID` from iOS Safari.
   - Zig 0.16 `std.http.Client` over TLS to the `*.ts.net` host, including
     reading an SSE stream.
   - QML `TextArea` inside omarchy-shell's `FloatingWindow`: incremental
     `insert`/`remove` without cursor jumps, speed on a 200 KB note.
   - `wl-paste` MIME selection for images and HTML from Firefox, Chromium and LibreOffice.
   - Core compiled to wasm32-freestanding and called from a browser page.
1. **core**: text CRDT + registers + op encoding, with convergence property tests.
2. **hub**: op log, blobs, SSE doorbell, auth middleware. Started by hand in
   tmux / herdr on the Mac.
3. **daemon**: replica, hub client, stdio protocol, paste, Joplin import.
4. **plugin**: omajop's panel turned into an editor, then the main window.
5. **PWA**: wasm core, CodeMirror, service worker, OPFS.
6. Later: `.md` mirror on the hub, snapshots/compaction, Dropbox adapter,
   end-to-end encryption (ops and blobs are opaque bytes to the hub, so it can
   be added without a protocol change), start-at-boot hub (below).

## Settled in review (2026-09-25)

- Tags are inline `#hashtags`.
- Remote images in pasted HTML are downloaded into attachments.
- No encryption in v1: the hub is our own Mac.
- The hub runs by hand in tmux / herdr. No launchd service yet.

## Start-at-boot hub (documented)

The Get started page now documents a systemd user service (with `loginctl enable-linger`) for Omarchy/Linux and a launchd LaunchAgent for macOS; both were tested (restart after a crash included). Earlier notes:

For a hub that must survive reboots without a login:

- **macOS**: a LaunchDaemon (runs before login, unlike a LaunchAgent), with
  Tailscale running as a system daemon too, or `tailscale serve` has no node to serve on.
- **VPS or home server** on the tailnet: a systemd unit. The better option for
  anyone without an always-on Mac; the hub is one static binary.

## Known follow-ups (first build, 2026-09-25)

- **Engine idle deadline**: bounded/http counts keep-alive idle time toward the next
  request's deadline, so SSE streams via `tailscale serve` end early; being fixed
  upstream together with per-route deadlines (bounded-http #7, baz #10).
- **Upload memory**: bounded/http reserves 2 × `max_body` per connection, so bodies are
  capped at 1 MiB and blobs are chunked. Streaming request bodies upstream would lift that.
- **No permanent delete / empty trash** in the protocol yet.
- **Hub reads `--web` only at startup**: every PWA deploy needs a hub restart (reload on SIGHUP?).
- **Engine**: split very large inserts so an ops array always fits in a 1 MiB batch;
  RGA → Fugue to avoid interleaving; counted tree for O(log n) position lookup.
- **PWA**: remote images in pasted HTML stay links (CORS); Add-to-Home-Screen and the
  toolbar above the iOS keyboard untested. (Fixed: the first-paragraph title styling,
  setext headings, hard breaks, parenthesised URLs; `app.js` 555 → 372 KiB.)
- **Plugin**: keyboard-driven checks still to do by hand: a main-window session, Ctrl+V,
  preview checkbox clicks, Ctrl+B/I, folder rename/move/delete, images in the preview.
- **Hub**: snapshots/compaction, start at boot.

## Open questions

- Folder cycles from concurrent moves: pick the deterministic rule.
