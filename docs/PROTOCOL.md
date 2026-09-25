# omajot contracts

The three interfaces every part of omajot is built against. Change them here
first, then in code. Design rationale lives in [DESIGN.md](../DESIGN.md).

```
 QML plugin ──JSON lines (stdio)──▶ omajot daemon ─┐
                                     └ core Engine  │  §2 hub HTTP API
 PWA (JS) ────omj_call (wasm)─────▶ core.wasm      ├──────────────▶ omajot hub (baz)
                                     └ core Engine  │
                                                    ┘
 §1 client protocol: identical for QML↔daemon and JS↔wasm
 §3 Engine Zig API: what the daemon and the wasm shell call
```

## Conventions

- **Positions are UTF-16 code units** (QString, JS, CodeMirror all use them).
  The core stores UTF-8 and converts at its edge; a position that splits a
  surrogate pair is an error.
- **Ids** are strings. Replica ids: 16 lowercase hex chars (random u64).
  Note ids `n-<replica>-<counter>`, folder ids `f-<replica>-<counter>`
  (the id of the op that created them).
- **Times** are Unix milliseconds (i64 / JS number).
- All JSON is UTF-8, one object per line where lines are used.

## 1. Client protocol (UI ↔ engine)

Used verbatim over the daemon's stdin/stdout (one JSON object per line) and
through `omj_call` in the browser (request in, reply + event lines out).

Every request carries an integer `id` and a `cmd`. Every request gets exactly
one reply: `{"re": <id>, "ok": true, ...}` or `{"re": <id>, "ok": false, "error": "<text>"}`.
Events are unsolicited lines with an `ev` field and may appear at any time
(on stdio) or after the reply in the same `omj_call` result (wasm).

### Types

```
NoteSummary = {
  "id": "n-…", "title": "first line, markdown heading marks stripped",
  "snippet": "≤120 chars of the text after the title, whitespace collapsed",
  "folder": "f-…" | null, "tags": ["tag", …],          // inline #hashtags, lowercase, unique, sorted
  "pinned": bool, "trashed": bool, "created": ms, "updated": ms
}
Folder = { "id": "f-…", "name": "…", "parent": "f-…" | null }
```

Tags follow Apple Notes: `#` + letters/digits/`_`/`-`/`/`, preceded by start of line
or whitespace, not inside inline code or fenced code, not a heading (`# x`, `## x`).
All-digit tags (`#123`) are not tags; a trailing `-` or `/` is dropped; lowercasing
covers ASCII and Latin-1. `updated` changes on text edits only (not on pin, move, trash).

### Requests

| cmd | fields | reply fields |
|---|---|---|
| `hello` | `client`: `"qml"` \| `"web"` | `replica`, `version`; the daemon adds `data`, `attachments` (absolute path with trailing `/`, the QML preview's `baseUrl`), `hub`, `daemon` |
| `list` | – | `notes: [NoteSummary]` (incl. trashed), `folders: [Folder]` |
| `open` | `note` | `text`, `seq` (last applied client edit seq for this note, initially 0), `pseq` (last patch seq, initially 0) |
| `close` | `note` | – |
| `edit` | `note`, `seq`, `pos`, `del`, `ins`, `ack` (optional: last `pseq` the client applied) | – |
| `create` | `folder` (nullable), `text` (optional, default `""`), `created` + `updated` (optional, import only: ms, `0 < created ≤ updated ≤ now`) | `note` |
| `set` | `note` + any of `folder`, `pinned`, `trashed` | – |
| `folder.create` | `name`, `parent` (nullable) | `folder` |
| `folder.rename` | `folder`, `name` | – |
| `folder.move` | `folder`, `parent` (nullable) | – |
| `folder.delete` | `folder` | – (its notes move to `folder: null`, subfolders to its parent) |
| `search` | `q` | `ids: ["n-…"]`, case-insensitive substring over title + body, updated desc, trashed included |
| `paste` | `note`, `pos` | `ins` (markdown to insert). **Daemon only**, the daemon handles it itself (clipboard → attachments) and never forwards it to the engine. The client then sends the text as an ordinary `edit` |
| `qr` | `text` (≤ 213 bytes) | `size`, `rows: ["0101…"]` (1 = dark module, no quiet zone): a QR code, byte mode, level M, versions 1–10. Used for "open on your phone" |
| `attach` | `path` (a local file) | `name` (`attachments/<sha256>.<ext>`). **Daemon only**: copies the file into the attachments and queues its upload |
| `status` | – | `sync`: `"online"`\|`"connecting"`\|`"offline"`, `hub`, `pending` (unsent batches), `head`. **Answered by the shell** (daemon / PWA); the engine only returns offline placeholders |

**Editing.** A client may have several notes open. For each open note it numbers
its own edits `seq = 1, 2, 3 …` and sends every change as
`{"cmd":"edit","note":…,"seq":k,"ack":a,"pos":p,"del":d,"ins":"…"}` against its
current text, where `ack` is the last patch `pseq` it has applied. An edit with
`seq ≤` the last applied one is ignored (idempotent resend).

Edits and patches can cross on the wire, so both sides transform (two-party OT,
Jupiter style; reference: `src/core/ot.zig`, whose `xform`/`xformPrim` the QML and
JS ports mirror exactly):

- The **engine** transforms an incoming edit over the patches it sent with
  `pseq > ack`. Without `ack` it assumes the client has seen every patch, which is
  exact for the synchronous wasm path.
- The **client**, on a patch, drops its pending edits with `seq ≤ base`, transforms
  the patch over the remaining pending edits, applies it, and remembers its `pseq`
  as the next `ack`.
- **Remote (engine-side) changes win ties** on both sides, so concurrent inserts at
  one position end up in the same order everywhere.

### Events

| ev | fields | meaning |
|---|---|---|
| `patch` | `note`, `base`, `pseq`, `pos`, `del`, `ins` | Remote change to an open note. `pseq` numbers the patches per open note (1, 2, …). Positions refer to the text after the client's edits up to `seq = base` and all earlier patches. Transform and apply as described under Editing, with `insert`/`remove`. Never echo a patch back as an edit |
| `notes` | `upsert: [NoteSummary]` | Summaries that changed (local or remote) |
| `folders` | `folders: [Folder]` | The full folder list, whenever it changes |
| `sync` | `state` (`online`, `connecting`, `offline`, `conflict`), `pending`, `head` | Sync state changed (emitted by the daemon / PWA shell, not the engine). `conflict`: a 409 on push or a hub head behind the local cursor |
| `attachment` | `name` | A missing attachment finished downloading (daemon); re-render previews that use it |
| `error` | `error` | Something failed outside a request. Also emitted on a sync conflict (409 on push, or a hub head behind the local cursor); local edits are always kept |

An edit or patch is a delete followed by an insert at the same `pos`; transform
them as primitive pairs. An insert inside a range deleted concurrently survives at
the range start, and the delete splits around it; overlapping deletes remove
the overlap once.

## 2. Hub HTTP API

Served by `omajot hub` (baz), bound to 127.0.0.1, published with
`tailscale serve --bg --https=8443 http://127.0.0.1:8787`. Every `/api/*`
request must carry `Tailscale-User-Login` equal to the configured login
(`--login`), else 403. Ops are opaque to the hub.

```
Batch = { "replica": "<hex16>", "bseq": k, "ops": <JSON array from the engine> }
Stored = Batch + { "seq": N }       // hub sequence, assigned on first accept, starts at 1
```

| Method + path | Body / query | Response |
|---|---|---|
| `GET /api/whoami` | – | `{"login","name","head"}` |
| `POST /api/batches` | `Batch` (≤ 1 MiB) | `{"seq":N,"head":H}`. Idempotent: a repeated `(replica,bseq)` returns the original `seq`. Durable (fsync) before replying. `bseq` must be the replica's previous `bseq + 1` or a repeat, else 409 |
| `GET /api/batches?after=N&limit=M` | `limit` ≤ 1000 | `{"head":H,"batches":[Stored…]}` in `seq` order, response capped at ~1 MiB (the client pages until it reaches `head`) |
| `GET /api/events` | `Last-Event-ID` | SSE. `event: head`, `id: H`, `data: {"head":H}`: sent at once if `H >` the client's cursor, then whenever head moves; `:` heartbeat every 15 s. The hub ends the stream cleanly before the server deadline; clients just reconnect |
| `PUT /api/blobs/<sha256hex>.<ext>` | raw bytes (≤ 1 MiB) | `201` (or `200` if present). 400 if the sha256 of the body ≠ the name |
| `PUT /api/blobs/<name>?offset=N&total=T` | one chunk (≤ 1 MiB) | **Blobs over 1 MiB must be chunked.** `202 {"received":R}` per chunk; `409 {"received":R}` on a wrong offset (resume at R); `201`/`200` when complete and the hash matches |
| `GET /api/blobs/<sha256hex>.<ext>` | – | bytes, `Cache-Control: public, max-age=31536000, immutable` |
| `GET /` and static paths | – | The PWA (`web/dist`), no auth needed for the shell itself |

Clients: pull with `after = cursor`, `ingest` every batch (their own come back too;
ingest is idempotent), advance `cursor`. Push outbox batches in `bseq` order,
one in flight; a batch leaves the outbox when the hub returns its `seq`.
A doorbell means "pull now"; compare heads, never count events.

Attachments are referenced from markdown as `attachments/<sha256hex>.<ext>`.
The desktop keeps them in `<data>/attachments/`; the PWA maps that path to
`/api/blobs/<sha256hex>.<ext>`.

## 3. Engine Zig API (`src/core/engine.zig`)

Pure: no `std.Io`, no clock, no randomness, no globals. The shells (daemon,
wasm) provide time, persistence and networking. `ingest` fails with
`error.InvalidOps` if its input isn't a JSON array; a single malformed op becomes
an `{"ev":"error"}` line and is skipped. Ops whose dependency hasn't arrived yet
wait inside the engine until it does.

Op format v1 (opaque to the hub, documented in `src/core/engine.zig`): a JSON array of
`{"v":1,"k":<kind>,"r":"<hex16>","c":<lamport>,"t":<hlc ms>,…}` with kinds
`nc` (note create), `ins`, `del`, `ns` (note set), `fc` (folder create), `fs` (folder set).
Text is an RGA with run-length encoded items; registers are last-writer-wins by `(t, r, c)`.
A folder move that would close a cycle is dropped (the folder stays a root).

```zig
pub const Engine = struct {
    pub fn init(gpa: std.mem.Allocator, replica: u64) !Engine;
    pub fn deinit(self: *Engine) void;

    /// Handle one §1 request (JSON). Appends the reply line and any event
    /// lines ("\n"-terminated) to `out`, allocated with the engine's gpa.
    pub fn call(self: *Engine, request: []const u8, now_ms: i64, out: *std.ArrayList(u8)) !void;

    /// Apply an ops array (JSON, as produced by takeNewOps on any replica,
    /// including this one). Idempotent. Continues this replica's own counter
    /// after the highest own op seen, so replaying the local log on startup
    /// restores state. Appends §1 events (`patch`, `notes`, `folders`) to `out`.
    pub fn ingest(self: *Engine, ops: []const u8, out: *std.ArrayList(u8)) !void;

    /// Ops created by `call` since the last take, as a JSON array ("[]" if none).
    /// The shell persists them, wraps them in a Batch and queues them for the hub.
    pub fn takeNewOps(self: *Engine, gpa: std.mem.Allocator) ![]u8;
};
```

Wasm exports (`src/wasm/wasm.zig`), per `spikes/wasm/REPORT.md`:

```
omj_alloc(len) -> ptr            omj_free(ptr, len)
omj_engine_new(replica_lo: u32, replica_hi: u32) -> handle (0 = error)
omj_call(handle, ptr, len, now_ms: f64) -> result      // §1 lines
omj_ingest(handle, ptr, len) -> result                 // §1 event lines
omj_take_new_ops(handle) -> result                     // JSON array
omj_free_result(result)
omj_engine_free(handle)   omj_pending(handle) -> ops waiting for a missing dependency
result = pointer to [u32 LE length][bytes]; 0 = out of memory
```

## 4. Files and processes

| | |
|---|---|
| Binary | one `omajot` executable: `omajot hub …`, `omajot daemon …`, `omajot qr [url]` (URL + terminal QR code; default: the configured hub) |
| Hub | `omajot hub --port 8787 --data <dir> --login <tailscale login> [--web <dir>] [--bind 127.0.0.1] [--timeout-ms N] [--url <public url>] [--no-auth (loopback only)]`; prints its phone URL and QR code at startup (`--url`, else found in `tailscale serve status`); data: `<dir>/batches.jsonl`, `<dir>/blobs/`. Request bodies are capped at 1 MiB because bounded/http reserves and touches 2 × `max_body` per connection at startup (16 MiB cost ~800 MB RSS) |
| Config | `$XDG_CONFIG_HOME/omajot/config.json` (`~/.config/omajot/config.json`), all fields optional: `{"hub": "<url>", "data": "<dir, ~/ allowed>"}`. Precedence: command-line flag, then config, then built-in default. The plugin passes `--hub` only when its `hubUrl` setting is non-empty |
| Import | `tools/import_joplin.py`: Joplin profile → omajot through a daemon (folders, created/updated times, `# Title` first line, tags → `#hashtags`, resources → attachments); rerunnable via `<data>/import-joplin.json` |
| Daemon | `omajot daemon [--hub <url> \| --no-hub] [--data <dir>]`, data default `$XDG_DATA_HOME/omajot` (`~/.local/share/omajot`): `replica.json` (id, cursor, next bseq), `ops.jsonl` (every ingested or local ops array, one per line, replayed on start), `outbox.jsonl`, `attachments/` |
| Plugin | repo root: `manifest.json` (id `io.github.renerocksai.omajot`), `Service.qml`, `BarWidget.qml`, `Panel.qml`, `qml/…`. Finds the daemon at `<plugin>/bin/omajot`, else `<plugin>/zig-out/bin/omajot`. Settings: `hubUrl` |
| PWA | sources in `web/`, built into `web/dist/` (committed, so `zig build` needs no node). Replica in IndexedDB |
| Default hub URL | `https://your-mac.your-tailnet.ts.net:8443` |
