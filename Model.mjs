// omajot plugin model: everything that can be decided without a compositor.
//
// The QML files stay presentational; text diffing, patch transformation,
// undo, list continuation, the note index, and preview rendering live here so
// `node --test tests/` covers them. Positions are UTF-16 code units, the same
// units QString, JS strings and the daemon protocol use (docs/PROTOCOL.md §1).

export const PLUGIN_ID = "io.github.renerocksai.omajot"
export const DEFAULT_HUB_URL = "https://your-mac.your-tailnet.ts.net:8443"
export const DEFAULT_DATA_SUBDIR = "omajot"

export const SOURCE_ALL = "all"
export const SOURCE_PINNED = "pinned"
export const SOURCE_UNFILED = "unfiled"
export const SOURCE_FOLDER = "folder"
export const SOURCE_TAG = "tag"
export const SOURCE_TRASH = "trash"

// Typing within this window at a contiguous position is one undo step.
export const UNDO_COALESCE_MS = 1200
export const MAX_UNDO = 500
export const MAX_IMAGE_PIXELS_PER_SIDE = 4096
export const RESTART_BACKOFF_MS = [500, 1000, 2000, 5000, 10000, 30000]

// Nerd Font / Font Awesome glyphs, as escapes so no editor can drop them.
export const GLYPH = {
  note: "\uf249",
  pin: "\uf08d",
  add: "\uf067",
  newNote: "\uf044",
  preview: "\uf06e",
  source: "\uf121",
  split: "\uf0db",
  window: "\uf2d0",
  folder: "\uf07b",
  folderOpen: "\uf07c",
  tag: "\uf02b",
  trash: "\uf1f8",
  all: "\uf01c",
  unfiled: "\uf15c",
  restore: "\uf0e2",
  rename: "\uf040",
  close: "\uf00d",
  move: "\uf08e",
  menu: "\uf0c9"
}

// --- settings ---------------------------------------------------------------

export function normalizeHubUrl(value) {
  const url = String(value === undefined || value === null ? "" : value).trim().replace(/\/+$/, "")
  if (!/^https?:\/\/[^\s/?#@]+(:\d+)?(\/[^\s?#]*)?$/.test(url)) return DEFAULT_HUB_URL
  return url
}

function stripTrailingSlash(path) {
  return path.length > 1 ? path.replace(/\/+$/, "") : path
}

// `<dataHome>/omajot`, where dataHome is $XDG_DATA_HOME or ~/.local/share.
// An explicit setting wins; "~/" expands to the home directory.
export function dataDirectory(setting, home, xdgDataHome) {
  const homeDir = stripTrailingSlash(String(home || ""))
  const explicit = String(setting === undefined || setting === null ? "" : setting).trim()
  if (explicit !== "") {
    if (explicit === "~") return homeDir
    if (explicit.slice(0, 2) === "~/") return stripTrailingSlash(homeDir + explicit.slice(1))
    if (explicit.charAt(0) === "/") return stripTrailingSlash(explicit)
  }
  const xdg = String(xdgDataHome || "").trim()
  const base = xdg.charAt(0) === "/" ? stripTrailingSlash(xdg) : homeDir + "/.local/share"
  return base + "/" + DEFAULT_DATA_SUBDIR
}

// Qt's baseUrl resolves relative paths against the *directory* only when the
// URL ends in "/" (spikes/qml/REPORT.md).
export function directoryUrl(path) {
  const clean = stripTrailingSlash(String(path || ""))
  return "file://" + encodeURI(clean) + "/"
}

// An empty hub setting passes no --hub, so the daemon uses "hub" from
// ~/.config/omajot/config.json, else its built-in default.
export function daemonArgv(binary, hubUrl, dataDir) {
  const argv = [String(binary), "daemon"]
  if (String(hubUrl || "").trim() !== "") argv.push("--hub", normalizeHubUrl(hubUrl))
  argv.push("--data", String(dataDir))
  return argv
}

export function restartDelay(attempt) {
  const i = Math.max(0, Math.min(RESTART_BACKOFF_MS.length - 1, Math.floor(Number(attempt) || 0)))
  return RESTART_BACKOFF_MS[i]
}

// --- protocol lines ---------------------------------------------------------

// Parses one stdout line from the daemon. Returns null for anything that is
// not a JSON object, so log noise on stdout cannot crash the service.
export function parseLine(line) {
  const text = String(line === undefined || line === null ? "" : line).trim()
  if (text === "" || text.charAt(0) !== "{") return null
  try {
    const value = JSON.parse(text)
    return value && typeof value === "object" && !Array.isArray(value) ? value : null
  } catch (error) {
    return null
  }
}

export function requestLine(id, cmd, fields) {
  const message = { id: id, cmd: cmd }
  const extra = fields || {}
  for (const key in extra) {
    if (key !== "id" && key !== "cmd") message[key] = extra[key]
  }
  return JSON.stringify(message) + "\n"
}

// --- text edits -------------------------------------------------------------
//
// An edit is {pos, del, ins}: remove `del` units at `pos`, then insert `ins`
// there. Everything below is expressed in those three numbers.

export function applyEdit(text, edit) {
  const source = String(text)
  const pos = Math.max(0, Math.min(source.length, edit.pos))
  const end = Math.max(pos, Math.min(source.length, pos + edit.del))
  return source.slice(0, pos) + (edit.ins || "") + source.slice(end)
}

function isHighSurrogate(code) { return code >= 0xd800 && code <= 0xdbff }
function isLowSurrogate(code) { return code >= 0xdc00 && code <= 0xdfff }

// The single contiguous change turning `before` into `after`: common prefix,
// then common suffix. `hint` (the caret after the change) lets a keystroke at
// the end of a long note skip the full prefix scan, and ambiguous runs
// ("aa" -> "aaa") resolve towards the caret like an editor would.
export function diffText(before, after, hint) {
  const a = String(before)
  const b = String(after)
  if (a === b) return null
  const max = Math.min(a.length, b.length)
  // With a caret, the change cannot start after caret - growth: that bound
  // resolves "aa" -> "aaa" at the caret.
  const caret = Number(hint)
  const limit = hint !== undefined && isFinite(caret)
    ? Math.max(0, Math.min(max, caret - Math.max(0, b.length - a.length))) : max
  let start = 0
  // One native comparison skips most of a long note's unchanged prefix.
  if (limit > 256 && a.slice(0, limit - 1) === b.slice(0, limit - 1)) start = limit - 1
  while (start < limit && a.charCodeAt(start) === b.charCodeAt(start)) start++
  let endA = a.length
  let endB = b.length
  while (endA > start && endB > start && a.charCodeAt(endA - 1) === b.charCodeAt(endB - 1)) {
    endA--
    endB--
  }
  // Never split a surrogate pair: widen the edit to whole code points.
  if (start > 0 && isHighSurrogate(a.charCodeAt(start - 1))) start--
  if (endA < a.length && isLowSurrogate(a.charCodeAt(endA))) { endA++; endB++ }
  return { pos: start, del: endA - start, ins: b.slice(start, endB) }
}

// --- transform (mirrors src/core/ot.zig) --------------------------------------
//
// Edits and patches cross on the wire, so both sides transform, Jupiter style
// (docs/PROTOCOL.md §1 "Editing"). This is a line-for-line port of
// `xform` / `xformPrim` from src/core/ot.zig: the engine and this client must
// resolve every conflict identically. Remote (engine-side) changes win ties.
//
// A primitive is {kind: "ins"|"del", pos, len, text, tag}; `tag` is the edit
// seq or patch pseq and is copied to both halves of a split.

export function insPrim(pos, text, tag) {
  return { kind: "ins", pos: pos, len: 0, text: String(text), tag: tag || 0 }
}

export function delPrim(pos, len, tag) {
  return { kind: "del", pos: pos, len: len, text: "", tag: tag || 0 }
}

function emptyPrim(p) {
  return p.kind === "ins" ? p.text.length === 0 : p.len === 0
}

function copyPrim(p) {
  return { kind: p.kind, pos: p.pos, len: p.len, text: p.text, tag: p.tag }
}

// A client edit {pos, del, ins} as primitives: delete first, then insert.
export function primsFromEdit(pos, del, ins, tag) {
  const out = []
  if (del > 0) out.push(delPrim(pos, del, tag))
  if (ins && ins.length > 0) out.push(insPrim(pos, ins, tag))
  return out
}

function one(p) {
  return emptyPrim(p) ? [] : [p]
}

function two(p, q) {
  if (emptyPrim(p)) return one(q)
  if (emptyPrim(q)) return one(p)
  return [p, q]
}

// Insert `i` against delete `d`, both on the same text.
function insVsDel(i, d) {
  const dEnd = d.pos + d.len
  const moved = copyPrim(i)
  if (i.pos <= d.pos) {
    const d2 = copyPrim(d)
    d2.pos += i.text.length
    return { i: one(moved), d: one(d2) }
  }
  if (i.pos >= dEnd) {
    moved.pos -= d.len
    return { i: one(moved), d: one(copyPrim(d)) }
  }
  // Insert inside the deleted range: the text survives at the range start,
  // the delete splits around it.
  moved.pos = d.pos
  const before = delPrim(d.pos, i.pos - d.pos, d.tag)
  const after = delPrim(d.pos + i.text.length, dEnd - i.pos, d.tag)
  return { i: one(moved), d: two(before, after) }
}

function delVsDel(a, b) {
  const aEnd = a.pos + a.len
  const bEnd = b.pos + b.len
  const lo = Math.max(a.pos, b.pos)
  const hi = Math.min(aEnd, bEnd)
  const overlap = hi > lo ? hi - lo : 0
  const r = copyPrim(a)
  r.len = a.len - overlap
  r.pos = a.pos <= b.pos ? a.pos : (a.pos >= bEnd ? a.pos - b.len : b.pos)
  return r
}

export function xformPrim(a, b, aWins) {
  if (a.kind === "ins") {
    if (b.kind === "ins") {
      const a2 = copyPrim(a)
      const b2 = copyPrim(b)
      if (a.pos < b.pos || (a.pos === b.pos && aWins)) b2.pos += a.text.length
      else a2.pos += b.text.length
      return { a: one(a2), b: one(b2) }
    }
    const r = insVsDel(a, b)
    return { a: r.i, b: r.d }
  }
  if (b.kind === "ins") {
    const r = insVsDel(b, a)
    return { a: r.d, b: r.i }
  }
  return { a: one(delVsDel(a, b)), b: one(delVsDel(b, a)) }
}

// Transform two sequences made concurrently on the same text: `a` rewritten
// to apply after `b`, and `b` rewritten to apply after `a`.
export function xform(a, b, aWins) {
  if (a.length === 0 || b.length === 0) return { a: a.map(copyPrim), b: b.map(copyPrim) }
  if (a.length === 1 && b.length === 1) return xformPrim(a[0], b[0], aWins)
  if (a.length > 1) {
    const first = xform(a.slice(0, 1), b, aWins)
    const rest = xform(a.slice(1), first.b, aWins)
    return { a: first.a.concat(rest.a), b: rest.b }
  }
  const first = xform(a, b.slice(0, 1), aWins)
  const rest = xform(first.a, b.slice(1), aWins)
  return { a: rest.a, b: first.b.concat(rest.b) }
}

// Applies one primitive; returns null when it does not fit the text.
export function applyPrim(text, p) {
  if (p.pos < 0 || p.pos > text.length) return null
  if (p.kind === "ins") return text.slice(0, p.pos) + p.text + text.slice(p.pos)
  if (p.pos + p.len > text.length) return null
  return text.slice(0, p.pos) + text.slice(p.pos + p.len)
}

// The {pos, del, ins} piece a TextArea applies with remove()/insert().
export function primToPiece(p) {
  return p.kind === "ins" ? { pos: p.pos, del: 0, ins: p.text } : { pos: p.pos, del: p.len, ins: "" }
}

// Where `index` lands after `p`; `afterInsert` decides an insert exactly at it.
export function mapThroughPrim(index, p, afterInsert) {
  if (p.kind === "ins") {
    if (index > p.pos || (index === p.pos && afterInsert)) return index + p.text.length
    return index
  }
  if (index <= p.pos) return index
  if (index >= p.pos + p.len) return index - p.len
  return p.pos
}

// --- documents --------------------------------------------------------------
//
// One per open note, shared by every view of that note. `seq` numbers this
// client's edits; `pending` holds their primitives until the engine has
// applied them (a patch's `base` says how far it got); `ack` is the last
// patch `pseq` applied here, sent with every edit so the engine can
// transform an edit that crossed a patch in flight.

export function newDoc(note, text, seq, pseq) {
  return {
    note: String(note),
    text: String(text || ""),
    seq: Math.max(0, Math.floor(Number(seq) || 0)),
    ack: Math.max(0, Math.floor(Number(pseq) || 0)),
    pending: [],
    undo: [],
    redo: [],
    patches: 0,
    lastEditAt: 0,
    lastPatchAt: 0
  }
}

function coalesces(prev, entry, nowMs) {
  if (!prev || prev.stale || nowMs - prev.at > UNDO_COALESCE_MS) return false
  const typing = prev.removed === "" && entry.removed === "" && entry.inserted.length >= 1
    && entry.inserted.length <= 2 && prev.inserted.length > 0
    && entry.pos === prev.pos + prev.inserted.length
    // A word boundary starts a new step: "a b" undoes as "b", then "a ".
    && !(/\s$/.test(prev.inserted) && !/\s/.test(entry.inserted))
  const erasing = prev.inserted === "" && entry.inserted === "" && entry.removed.length <= 2
    && (entry.pos + entry.removed.length === prev.pos || entry.pos === prev.pos)
  return typing || erasing
}

function recordUndo(doc, edit, removed, nowMs) {
  const entry = { pos: edit.pos, removed: removed, inserted: edit.ins || "", at: nowMs }
  const prev = doc.undo.length > 0 ? doc.undo[doc.undo.length - 1] : null
  if (coalesces(prev, entry, nowMs)) {
    if (entry.removed === "") {
      prev.inserted += entry.inserted
    } else if (entry.pos + entry.removed.length === prev.pos) {
      prev.removed = entry.removed + prev.removed
      prev.pos = entry.pos
    } else {
      prev.removed += entry.removed
    }
    prev.at = nowMs
  } else {
    doc.undo.push(entry)
    if (doc.undo.length > MAX_UNDO) doc.undo.shift()
  }
  doc.redo = []
}

function nextEdit(doc, edit) {
  doc.seq += 1
  const out = { seq: doc.seq, ack: doc.ack, pos: edit.pos, del: edit.del, ins: edit.ins || "" }
  const prims = primsFromEdit(out.pos, out.del, out.ins, doc.seq)
  for (let i = 0; i < prims.length; i++) doc.pending.push(prims[i])
  doc.text = applyEdit(doc.text, out)
  return out
}

// A view changed its text to `newText`. Returns the edit to send, or null.
export function docLocalEdit(doc, newText, nowMs, caret) {
  const edit = diffText(doc.text, newText, caret)
  if (!edit) return null
  return docApplyLocal(doc, edit, nowMs)
}

// An edit decided by code (list continuation, paste, …) rather than typing.
export function docApplyLocal(doc, edit, nowMs) {
  if (edit.del === 0 && !(edit.ins && edit.ins.length)) return null
  const removed = doc.text.slice(edit.pos, edit.pos + edit.del)
  recordUndo(doc, edit, removed, nowMs || 0)
  doc.lastEditAt = nowMs || 0
  return nextEdit(doc, edit)
}

// The engine applied edit `seq`.
export function docAck(doc, seq) {
  doc.pending = doc.pending.filter(function (p) { return p.tag > seq })
}

function shiftStack(stack, p) {
  for (let i = 0; i < stack.length; i++) {
    const entry = stack[i]
    const start = mapThroughPrim(entry.pos, p, true)
    const end = mapThroughPrim(entry.pos + entry.inserted.length, p, false)
    // A remote change inside the entry's own text makes it unsafe to invert.
    if (end - start !== entry.inserted.length) entry.stale = true
    entry.pos = start
  }
}

// Applies a §1 `patch` event. Returns {pieces, resync}: the pieces every view
// applies, in order, with remove()/insert(); resync is true when the patch
// cannot belong to this document (the service then reloads the note).
export function docApplyPatch(doc, patch, nowMs) {
  const base = Math.max(0, Math.floor(Number(patch.base) || 0))
  const keep = doc.pending.filter(function (p) { return p.tag > base })
  const pseq = Math.max(0, Math.floor(Number(patch.pseq) || 0))
  const pos = Number(patch.pos)
  const del = Number(patch.del)
  if (!(pos >= 0 && del >= 0)) return { pieces: [], resync: true }
  const r = xform(primsFromEdit(pos, del, patch.ins || "", pseq), keep, true)
  let text = doc.text
  for (let i = 0; i < r.a.length; i++) {
    text = applyPrim(text, r.a[i])
    if (text === null) return { pieces: [], resync: true }
  }
  doc.text = text
  doc.pending = r.b
  if (pseq > 0) doc.ack = pseq
  for (let j = 0; j < r.a.length; j++) {
    shiftStack(doc.undo, r.a[j])
    shiftStack(doc.redo, r.a[j])
  }
  doc.patches += 1
  doc.lastPatchAt = nowMs || 0
  return { pieces: r.a.map(primToPiece), resync: false }
}

// Replaces the text wholesale after (re)opening; history no longer lines up.
export function docReset(doc, text, seq, pseq) {
  doc.text = String(text || "")
  doc.seq = Math.max(doc.seq, Math.floor(Number(seq) || 0))
  doc.ack = Math.max(0, Math.floor(Number(pseq) || 0))
  doc.pending = []
  doc.undo = []
  doc.redo = []
}

function invert(doc, from, to) {
  while (from.length > 0) {
    const entry = from.pop()
    if (entry.stale) continue
    if (doc.text.slice(entry.pos, entry.pos + entry.inserted.length) !== entry.inserted) continue
    to.push({ pos: entry.pos, removed: entry.inserted, inserted: entry.removed, at: 0 })
    const out = nextEdit(doc, { pos: entry.pos, del: entry.inserted.length, ins: entry.removed })
    out.caret = entry.pos + entry.removed.length
    return out
  }
  return null
}

// Undo inverts this client's own last step only; remote text is never touched.
export function docUndo(doc) { return invert(doc, doc.undo, doc.redo) }
export function docRedo(doc) { return invert(doc, doc.redo, doc.undo) }

// --- editing helpers --------------------------------------------------------

export function lineBounds(text, pos) {
  const source = String(text)
  const start = source.lastIndexOf("\n", Math.max(0, pos - 1)) + 1
  let end = source.indexOf("\n", pos)
  if (end < 0) end = source.length
  return { start: pos === 0 ? 0 : start, end: end }
}

const LIST_LINE_RE = /^(\s*)([-*+]|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?/

// Enter at `caret`: continue the list item or checklist the caret is in.
// An empty item ends the list instead. Returns {edit, caret} or null to let
// the editor insert a plain newline.
export function continueList(text, caret) {
  const source = String(text)
  const bounds = lineBounds(source, caret)
  const line = source.slice(bounds.start, bounds.end)
  const match = LIST_LINE_RE.exec(line)
  if (!match) return null
  const prefixLength = match[0].length
  if (caret < bounds.start + prefixLength) return null
  const rest = line.slice(prefixLength)
  if (rest.trim() === "" && caret === bounds.end) {
    // "- " alone: drop the marker and leave an empty line.
    return { edit: { pos: bounds.start, del: bounds.end - bounds.start, ins: "" }, caret: bounds.start }
  }
  let marker = match[2]
  if (match[3] !== undefined) marker = (parseInt(match[3], 10) + 1) + match[4]
  const box = match[6] ? "[ ] " : ""
  const insert = "\n" + match[1] + marker + match[5] + box
  return { edit: { pos: caret, del: 0, ins: insert }, caret: caret + insert.length }
}

const TASK_RE = /^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\])/

// Toggles the checkbox on (0-based) line `lineIndex`. Returns an edit or null.
export function toggleTaskAtLine(text, lineIndex) {
  const source = String(text)
  let start = 0
  for (let i = 0; i < lineIndex; i++) {
    const next = source.indexOf("\n", start)
    if (next < 0) return null
    start = next + 1
  }
  let end = source.indexOf("\n", start)
  if (end < 0) end = source.length
  const match = TASK_RE.exec(source.slice(start, end))
  if (!match) return null
  const at = start + match[1].length
  return { pos: at, del: 1, ins: match[2] === " " ? "x" : " " }
}

// Ctrl+B / Ctrl+I: wrap the selection, or unwrap it if already wrapped. With
// no selection, insert the pair and put the caret between.
export function wrapSelection(text, selStart, selEnd, marker) {
  const source = String(text)
  const a = Math.min(selStart, selEnd)
  const b = Math.max(selStart, selEnd)
  const m = String(marker)
  const inner = source.slice(a, b)
  if (a >= m.length && source.slice(a - m.length, a) === m && source.slice(b, b + m.length) === m
      && !(m === "*" && source.slice(a - 2, a) === "**" && source.slice(b, b + 2) === "**")) {
    return {
      edit: { pos: a - m.length, del: inner.length + 2 * m.length, ins: inner },
      selStart: a - m.length, selEnd: b - m.length
    }
  }
  return {
    edit: { pos: a, del: inner.length, ins: m + inner + m },
    selStart: a + m.length, selEnd: b + m.length
  }
}

// Tags: `#` + letters/digits/_/-//, at line start or after whitespace, outside
// code, and not a heading. Mirrors the §1 definition the engine uses.
// Letters from the common scripts, spelled out: Qt's JS engine has no \\p{L}.
const TAG_LETTERS = "A-Za-z0-9_\\-/\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u024F\\u0370-\\u03FF"
  + "\\u0400-\\u04FF\\u0590-\\u05FF\\u0600-\\u06FF\\u0900-\\u097F\\u3040-\\u30FF\\u4E00-\\u9FFF\\uAC00-\\uD7AF"
const TAG_BODY = "[" + TAG_LETTERS + "]"
const TAG_RE = new RegExp("(^|\\s)#(" + TAG_BODY + "+)", "g")

export function extractTags(text) {
  const source = String(text || "")
  const found = {}
  const lines = source.split("\n")
  let fenced = false
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (/^\s*(```|~~~)/.test(line)) { fenced = !fenced; continue }
    if (fenced) continue
    const prose = line.replace(/`[^`]*`/g, " ")
    TAG_RE.lastIndex = 0
    let match
    while ((match = TAG_RE.exec(prose)) !== null) {
      const tag = match[2].replace(/[\/\-]+$/, "").toLowerCase()
      if (tag !== "" && !/^\d+$/.test(tag)) found[tag] = true
    }
  }
  return Object.keys(found).sort()
}

// The partial tag being typed at the caret ("#pro|" -> "pro"), or null.
export function tagPrefixAt(text, caret) {
  const before = String(text).slice(0, caret)
  const match = new RegExp("(^|\\s)#(" + TAG_BODY + "*)$").exec(before)
  if (!match) return null
  const lineStart = before.lastIndexOf("\n") + 1
  // "# " at a line start is a heading being typed, not a tag.
  if (match[2] === "" && before.length - 1 === lineStart && before.slice(lineStart) === "#") return ""
  return match[2]
}

export function tagCompletions(prefix, allTags, limit) {
  if (prefix === null || prefix === undefined) return []
  const p = String(prefix).toLowerCase()
  const out = []
  for (let i = 0; i < allTags.length && out.length < (limit || 6); i++) {
    const tag = String(allTags[i].tag || allTags[i])
    if (tag.indexOf(p) === 0 && tag !== p) out.push(tag)
  }
  return out
}

// --- note index -------------------------------------------------------------

export function noteTitle(note) {
  const title = note && note.title ? plainLine(note.title) : ""
  return title !== "" ? title : "New note"
}

export function upsertNotes(notes, updates) {
  const byId = {}
  const out = []
  for (let i = 0; i < notes.length; i++) {
    byId[notes[i].id] = out.length
    out.push(notes[i])
  }
  for (let j = 0; j < updates.length; j++) {
    const note = updates[j]
    if (!note || !note.id) continue
    if (byId[note.id] !== undefined) out[byId[note.id]] = note
    else {
      byId[note.id] = out.length
      out.push(note)
    }
  }
  return out
}

// Pinned first, then most recently updated.
export function sortNotes(notes) {
  return notes.slice().sort(function (a, b) {
    if (!!a.pinned !== !!b.pinned) return a.pinned ? -1 : 1
    return (Number(b.updated) || 0) - (Number(a.updated) || 0)
  })
}

export function tagCounts(notes) {
  const counts = {}
  for (let i = 0; i < notes.length; i++) {
    if (notes[i].trashed) continue
    const tags = notes[i].tags || []
    for (let j = 0; j < tags.length; j++) counts[tags[j]] = (counts[tags[j]] || 0) + 1
  }
  return Object.keys(counts).sort().map(function (tag) { return { tag: tag, count: counts[tag] } })
}

// Folders as a depth-first list with direct (`count`) and subtree (`total`)
// note counts. A parent that does not exist, or a cycle, puts the folder at
// the top level.
export function folderTree(folders, notes) {
  const byId = {}
  for (let i = 0; i < folders.length; i++) byId[folders[i].id] = folders[i]
  function effectiveParent(folder) {
    const seen = {}
    seen[folder.id] = true
    const parent = folder.parent && byId[folder.parent] ? folder.parent : null
    let cursor = parent
    while (cursor) {
      if (seen[cursor]) return null
      seen[cursor] = true
      const up = byId[cursor].parent
      cursor = up && byId[up] ? up : null
    }
    return parent
  }
  const children = {}
  const roots = []
  for (let j = 0; j < folders.length; j++) {
    const parent = effectiveParent(folders[j])
    if (parent) (children[parent] = children[parent] || []).push(folders[j])
    else roots.push(folders[j])
  }
  const direct = {}
  for (let k = 0; k < notes.length; k++) {
    if (notes[k].trashed || !notes[k].folder) continue
    direct[notes[k].folder] = (direct[notes[k].folder] || 0) + 1
  }
  function byName(a, b) { return String(a.name).localeCompare(String(b.name)) }
  const out = []
  function visit(folder, depth) {
    const row = { id: folder.id, name: folder.name, parent: folder.parent || null,
      depth: depth, count: direct[folder.id] || 0, total: 0 }
    out.push(row)
    let total = row.count
    const kids = (children[folder.id] || []).slice().sort(byName)
    for (let c = 0; c < kids.length; c++) total += visit(kids[c], depth + 1)
    row.total = total
    return total
  }
  roots.sort(byName)
  for (let r = 0; r < roots.length; r++) visit(roots[r], 0)
  return out
}

// All folder ids under `id`, including itself.
export function folderSubtree(tree, id) {
  const ids = {}
  let depth = -1
  for (let i = 0; i < tree.length; i++) {
    if (depth < 0) {
      if (tree[i].id === id) { depth = tree[i].depth; ids[id] = true }
      continue
    }
    if (tree[i].depth <= depth) break
    ids[tree[i].id] = true
  }
  return ids
}

export function notesForSource(notes, kind, id, tree) {
  const out = []
  const subtree = kind === SOURCE_FOLDER ? folderSubtree(tree || [], id) : null
  for (let i = 0; i < notes.length; i++) {
    const note = notes[i]
    if (kind === SOURCE_TRASH) { if (note.trashed) out.push(note); continue }
    if (note.trashed) continue
    if (kind === SOURCE_PINNED && !note.pinned) continue
    if (kind === SOURCE_UNFILED && note.folder) continue
    if (kind === SOURCE_FOLDER && !(note.folder && subtree[note.folder])) continue
    if (kind === SOURCE_TAG && (note.tags || []).indexOf(id) < 0) continue
    out.push(note)
  }
  return out
}

// Titles and snippets filter instantly; `bodyIds` widens that with the
// engine's full-text `search` result.
export function filterNotes(notes, query, bodyIds) {
  const q = plainLine(query).toLowerCase()
  if (q === "") return notes
  const hits = bodyIds || {}
  return notes.filter(function (note) {
    if (hits[note.id]) return true
    return String(note.title || "").toLowerCase().indexOf(q) >= 0
      || String(note.snippet || "").toLowerCase().indexOf(q) >= 0
      || (note.tags || []).some(function (t) { return ("#" + t).indexOf(q) >= 0 })
  })
}

export function findNote(notes, id) {
  for (let i = 0; i < notes.length; i++) if (notes[i].id === id) return notes[i]
  return null
}

export function idSet(ids) {
  const out = {}
  for (let i = 0; i < (ids || []).length; i++) out[ids[i]] = true
  return out
}

// --- formatting -------------------------------------------------------------

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function toMillis(value) {
  if (value instanceof Date) return value.getTime()
  const n = Number(value)
  return isFinite(n) ? n : Date.now()
}

function formatAbsolute(ms, nowMs) {
  const date = new Date(ms)
  const stamp = date.getDate() + " " + MONTHS[date.getMonth()]
  const sameYear = date.getFullYear() === new Date(nowMs).getFullYear()
  return sameYear ? stamp : stamp + " " + date.getFullYear()
}

export function formatUpdated(ms, now) {
  const stamp = Number(ms)
  if (!isFinite(stamp) || stamp <= 0) return ""
  const nowMs = toMillis(now)
  const diff = nowMs - stamp
  if (diff < 0) return formatAbsolute(stamp, nowMs)
  const minutes = Math.floor(diff / 60000)
  if (minutes < 1) return "just now"
  if (minutes < 60) return minutes + "m ago"
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  const days = Math.floor(hours / 24)
  if (days < 7) return days + "d ago"
  return formatAbsolute(stamp, nowMs)
}

export function plainLine(text) {
  return String(text === undefined || text === null ? "" : text).replace(/\s+/g, " ").trim()
}

export function syncLabel(state, pending) {
  const n = Math.max(0, Number(pending) || 0)
  if (state === "online") return n > 0 ? "Syncing " + n : "Synced"
  if (state === "connecting") return "Connecting…"
  if (state === "offline") return n > 0 ? "Offline · " + n + " unsent" : "Offline"
  return "Starting…"
}

// --- preview ----------------------------------------------------------------
//
// Qt's Markdown renderer paints nothing for file:// images inside a Text in
// the shell (found in omajop), so images are lifted into their own segments
// and drawn by Image items. Task markers become `task:<line>` links, so a
// click in the preview can toggle the checkbox in the source.

const ATTACHMENT_IMAGE_RE = /!\[([^\]]*)\]\((attachments\/[0-9a-f]{64}\.[A-Za-z0-9]{1,8})(?:\s+"[^"]*")?\)/g
const FENCE_LINE_RE = /^\s*(```|~~~)/

export function attachmentUrl(dataDir, relative) {
  const rel = String(relative || "")
  if (!/^attachments\/[0-9a-f]{64}\.[A-Za-z0-9]{1,8}$/.test(rel)) return ""
  return "file://" + encodeURI(stripTrailingSlash(String(dataDir)) + "/" + rel)
}

function linkTasks(line, index) {
  return line.replace(/^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]\s/, function (whole, lead, mark) {
    const box = mark === " " ? "☐" : "☑"
    return lead + "[" + box + "](task:" + index + ") "
  })
}

export function splitPreview(text, dataDir) {
  const lines = String(text || "").split("\n")
  const segments = []
  let buffer = []
  let fenced = false
  function flush() {
    const chunk = buffer.join("\n")
    if (chunk.trim() !== "") segments.push({ kind: "text", text: chunk })
    buffer = []
  }
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i]
    if (FENCE_LINE_RE.test(line)) fenced = !fenced
    if (fenced || FENCE_LINE_RE.test(line)) { buffer.push(line); continue }
    line = linkTasks(line, i)
    let last = 0
    let match
    ATTACHMENT_IMAGE_RE.lastIndex = 0
    let pieces = ""
    let emitted = false
    while ((match = ATTACHMENT_IMAGE_RE.exec(line)) !== null) {
      pieces += line.slice(last, match.index)
      last = match.index + match[0].length
      const url = attachmentUrl(dataDir, match[2])
      if (url === "") { pieces += match[1]; continue }
      if (pieces.trim() !== "") buffer.push(pieces)
      pieces = ""
      flush()
      segments.push({ kind: "image", url: url, title: match[1] })
      emitted = true
    }
    pieces += line.slice(last)
    if (!emitted || pieces.trim() !== "") buffer.push(pieces)
  }
  flush()
  return segments
}

// Links a reader may open from a note: http(s) only, no credentials, no
// control characters. task: links are handled by the panel itself.
export function externalLinkUrl(link) {
  const url = String(link === undefined || link === null ? "" : link).trim()
  if (url === "" || /[\u0000-\u001f\u007f\s]/.test(url)) return ""
  const scheme = /^([A-Za-z][A-Za-z0-9+.-]*):\/\//.exec(url)
  if (!scheme) return ""
  const name = scheme[1].toLowerCase()
  if (name !== "http" && name !== "https") return ""
  const authority = url.slice(scheme[0].length).split(/[/?#]/)[0]
  if (authority === "" || authority.indexOf("@") !== -1) return ""
  return url
}

export function taskLine(link) {
  const match = /^task:(\d{1,7})$/.exec(String(link || ""))
  return match ? parseInt(match[1], 10) : -1
}

// --- markdown styling (from omajop) ----------------------------------------
//
// Qt's importer bakes its own blue into links and draws code in the system
// fixed font at its own size, so both are rewritten as inline HTML carrying
// the theme's colour and size. Raw HTML that could load something is removed.

export function sanitizeColor(value) {
  const text = String(value || "").trim()
  if (/^#[0-9a-fA-F]{3,8}$/.test(text)) return text
  if (/^[a-zA-Z]{3,20}$/.test(text)) return text
  return ""
}

export function sanitizeFontSize(value) {
  const size = Math.round(Number(value))
  if (!isFinite(size) || size < 1 || size > 200) return ""
  return size + "px"
}

function escapeText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

function escapeAttribute(value) {
  return escapeText(value).replace(/"/g, "&quot;")
}

const LINK_RE = /(^|[^!])\[([^\]]*)\]\(([^)\s]+)\)/g

function styleLinksInProse(chunk, color) {
  if (color === "") return chunk
  return chunk.replace(LINK_RE, function (whole, prefix, label, url) {
    // Task boxes keep the text colour; they read as controls, not links.
    const style = /^task:/.test(url) ? "text-decoration:none" : "color:" + color
    return prefix + '<a href="' + escapeAttribute(url) + '" style="' + style + '">' + label + "</a>"
  })
}

const LIST_ITEM_RE = /^\s*(?:[-*+]|\d+[.)])\s+/

function addBlockSpacing(chunk) {
  const lines = chunk.split("\n")
  const out = []
  let i = 0
  while (i < lines.length) {
    if (lines[i].trim() !== "") { out.push(lines[i]); i++; continue }
    let end = i
    while (end < lines.length && lines[end].trim() === "") end++
    const before = out.length > 0 ? out[out.length - 1] : ""
    const after = end < lines.length ? lines[end] : ""
    const atEdge = before === "" || after === ""
    const withinList = LIST_ITEM_RE.test(before) && LIST_ITEM_RE.test(after)
    if (atEdge) { for (let k = i; k < end; k++) out.push(lines[k]) }
    else if (withinList) out.push("")
    else out.push("", "&nbsp;", "")
    i = end
  }
  return out.join("\n")
}

const TABLE_DELIMITER_RE = /^\s*\|?(\s*:?-+:?\s*\|)+\s*:?-*:?\s*\|?\s*$/
const CELL_LINK_RE = /\[([^\]]*)\]\(([^)\s]+)\)/g
const CELL_CODE_RE = /`[^`\n]+`/g

function splitRow(line) {
  let text = line.trim()
  if (text.charAt(0) === "|") text = text.slice(1)
  if (text.charAt(text.length - 1) === "|") text = text.slice(0, -1)
  return text.split("|").map(function (c) { return c.trim() })
}

function alignmentOf(spec) {
  const text = String(spec || "").trim()
  const left = text.charAt(0) === ":"
  const right = text.charAt(text.length - 1) === ":"
  if (left && right) return "center"
  if (right) return "right"
  if (left) return "left"
  return ""
}

function renderCellProse(text, color) {
  let out = escapeText(text)
  if (color !== "") {
    out = out.replace(CELL_LINK_RE, function (whole, label, url) {
      return '<a href="' + url + '" style="color:' + color + '">' + label + "</a>"
    })
  }
  out = out.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
  out = out.replace(/__([^_]+)__/g, "<b>$1</b>")
  out = out.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<i>$2</i>")
  out = out.replace(/~~([^~]+)~~/g, "<s>$1</s>")
  return out
}

function codeSpan(text, size) {
  return '<code style="font-size:' + size + '">' + escapeText(text) + "</code>"
}

function renderCell(text, color, size) {
  const parts = []
  let last = 0
  let match
  CELL_CODE_RE.lastIndex = 0
  while ((match = CELL_CODE_RE.exec(text)) !== null) {
    parts.push(renderCellProse(text.slice(last, match.index), color))
    const code = match[0].slice(1, -1)
    parts.push(size !== "" ? codeSpan(code, size) : escapeText(code))
    last = match.index + match[0].length
  }
  parts.push(renderCellProse(text.slice(last), color))
  return parts.join("")
}

function renderTable(header, alignments, rows, options) {
  const parts = ['<table border="1" bordercolor="' + options.border + '" cellpadding="4" cellspacing="0">']
  function cells(values, tag) {
    let row = "<tr>"
    for (let i = 0; i < values.length; i++) {
      const align = alignments[i] || ""
      row += "<" + tag + (align !== "" ? ' align="' + align + '"' : "") + ">"
        + renderCell(values[i], options.color, options.size) + "</" + tag + ">"
    }
    return row + "</tr>"
  }
  parts.push(cells(header, "th"))
  for (let i = 0; i < rows.length; i++) parts.push(cells(rows[i], "td"))
  parts.push("</table>")
  return parts.join("")
}

function convertTables(chunk, options) {
  if (options.border === "") return chunk
  const lines = chunk.split("\n")
  const out = []
  let i = 0
  while (i < lines.length) {
    const isTableStart = i + 1 < lines.length && lines[i].indexOf("|") !== -1
      && TABLE_DELIMITER_RE.test(lines[i + 1])
    if (!isTableStart) { out.push(lines[i]); i++; continue }
    const header = splitRow(lines[i])
    const alignments = splitRow(lines[i + 1]).map(alignmentOf)
    const rows = []
    let end = i + 2
    while (end < lines.length && lines[end].trim() !== "" && lines[end].indexOf("|") !== -1) {
      rows.push(splitRow(lines[end]))
      end++
    }
    out.push(renderTable(header, alignments, rows, options))
    i = end
  }
  return out.join("\n")
}

const HTML_DROP_WITH_CONTENT = [
  "script", "style", "iframe", "object", "embed", "video", "audio", "canvas",
  "svg", "math", "template", "noscript", "applet", "frame", "frameset", "head",
  "form", "map", "portal"
]
const HTML_IMG_RE = /<img\b([^>]*)>/gi
const HTML_TAG_RE = /<(\/?)([A-Za-z][A-Za-z0-9]*)\b([^>]*)>/g
const ALT_RE = /\balt\s*=\s*["']([^"']*)["']/i
const LOADING_ATTRIBUTE_RE =
  /\s(?:on[a-z]+|src|srcset|data|poster|background|formaction|xlink:href|lowsrc|dynsrc)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi
const STYLE_ATTRIBUTE_RE = /(\sstyle\s*=\s*)("([^"]*)"|'([^']*)')/gi

function sanitizeStyleDeclarations(value) {
  const parts = String(value === undefined || value === null ? "" : value).split(";")
  const kept = []
  for (let i = 0; i < parts.length; i++) {
    const declaration = parts[i].trim()
    if (declaration === "") continue
    if (/url\s*\(/i.test(declaration) || /expression\s*\(/i.test(declaration)) continue
    if (/[<>"']/.test(declaration)) continue
    kept.push(declaration)
  }
  return kept.join(";")
}

function stripLoadingAttributes(rawAttributes) {
  let out = String(rawAttributes === undefined || rawAttributes === null ? "" : rawAttributes)
  out = out.replace(LOADING_ATTRIBUTE_RE, "")
  out = out.replace(STYLE_ATTRIBUTE_RE, function (whole, lead, quoted, double, single) {
    const value = double !== undefined ? double : (single !== undefined ? single : "")
    const cleaned = sanitizeStyleDeclarations(value)
    return cleaned === "" ? "" : lead + '"' + escapeAttribute(cleaned) + '"'
  })
  return out
}

// Removes what would make the preview fetch something (an <img src=http…>
// is loaded by Qt during layout, without a click).
export function neutralizeEmbeds(text) {
  let out = String(text === undefined || text === null ? "" : text)
  for (let i = 0; i < HTML_DROP_WITH_CONTENT.length; i++) {
    const tag = HTML_DROP_WITH_CONTENT[i]
    out = out.replace(new RegExp("<" + tag + "\\b[\\s\\S]*?<\\/" + tag + "\\s*>", "gi"), "")
    out = out.replace(new RegExp("<\\/?" + tag + "\\b[^>]*>", "gi"), "")
  }
  out = out.replace(HTML_IMG_RE, function (whole, attributes) {
    const alt = ALT_RE.exec(attributes)
    return alt && alt[1] ? escapeText(alt[1]) : ""
  })
  out = out.replace(HTML_TAG_RE, function (whole, closing, rawName, rawAttributes) {
    if (closing === "/") return whole
    return "<" + rawName + stripLoadingAttributes(rawAttributes) + ">"
  })
  // Remote markdown images load the same way; keep their alt text as a link.
  out = out.replace(/!\[([^\]]*)\]\(((?:https?:)?\/\/[^)\s]+)[^)]*\)/g, "[$1]($2)")
  return out
}

const INLINE_CODE_RE = /`[^`\n]+`/g
const FENCE_RE = /(```[^\n]*\n[\s\S]*?^```|~~~[^\n]*\n[\s\S]*?^~~~)/gm

function styleInline(chunk, options) {
  const parts = []
  let last = 0
  let match
  INLINE_CODE_RE.lastIndex = 0
  while ((match = INLINE_CODE_RE.exec(chunk)) !== null) {
    parts.push(styleLinksInProse(neutralizeEmbeds(chunk.slice(last, match.index)), options.color))
    parts.push(options.size !== "" ? codeSpan(match[0].slice(1, -1), options.size) : match[0])
    last = match.index + match[0].length
  }
  parts.push(styleLinksInProse(neutralizeEmbeds(chunk.slice(last)), options.color))
  return parts.join("")
}

function styleProse(chunk, options) {
  return addBlockSpacing(styleInline(convertTables(chunk, options), options))
}

function styleFence(block, size) {
  const lines = block.split("\n")
  lines.shift()
  if (lines.length > 0 && /^\s*(```|~~~)\s*$/.test(lines[lines.length - 1])) lines.pop()
  if (lines.length === 0) return ""
  const rendered = []
  for (let i = 0; i < lines.length; i++) {
    rendered.push(lines[i].trim() === "" ? ">" : "> " + codeSpan(lines[i], size))
  }
  return "\n\n" + rendered.join("  \n") + "\n\n"
}

export function styleMarkdown(markdown, options) {
  const text = String(markdown === undefined || markdown === null ? "" : markdown)
  const settings = options || {}
  const size = sanitizeFontSize(settings.fontSizePx)
  const styling = {
    color: sanitizeColor(settings.linkColor),
    size: size,
    border: sanitizeColor(settings.tableBorderColor)
  }
  const out = []
  let last = 0
  let match
  FENCE_RE.lastIndex = 0
  while ((match = FENCE_RE.exec(text)) !== null) {
    out.push(styleProse(text.slice(last, match.index), styling))
    out.push(size === "" ? match[0] : styleFence(match[0], size))
    last = match.index + match[0].length
  }
  out.push(styleProse(text.slice(last), styling))
  return out.join("")
}
