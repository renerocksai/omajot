// Client side of the patch protocol (docs/PROTOCOL.md §1 "Editing").
//
// A JS port of src/core/ot.zig: `xformPrim` and `xform` mirror the Zig code
// exactly (two-party OT, Jupiter style; engine-side changes win ties), and
// `OtClient` is the client half of its convergence test. Positions are UTF-16
// code units, i.e. JS string indices and CodeMirror positions.
//
// A primitive is { kind: 'ins', pos, text, tag } or { kind: 'del', pos, len, tag };
// `tag` is the edit `seq` or patch `pseq`, copied to both halves of a split.

export const ins = (pos, text, tag = 0) => ({ kind: 'ins', pos, text, len: 0, tag })
export const del = (pos, len, tag = 0) => ({ kind: 'del', pos, len, text: '', tag })

const empty = (p) => (p.kind === 'ins' ? p.text.length === 0 : p.len === 0)
const one = (p) => (empty(p) ? [] : [p])
const two = (p, q) => (empty(p) ? one(q) : empty(q) ? one(p) : [p, q])

// An edit { pos, del, ins } as primitives: delete first, then insert.
export function fromEdit(pos, delLen, insText, tag = 0) {
  const out = []
  if (delLen > 0) out.push(del(pos, delLen, tag))
  if (insText.length > 0) out.push(ins(pos, insText, tag))
  return out
}

// Insert `i` against delete `d`, both on the same text.
function insVsDel(i, d) {
  const dEnd = d.pos + d.len
  if (i.pos <= d.pos) return { i: one({ ...i }), d: one({ ...d, pos: d.pos + i.text.length }) }
  if (i.pos >= dEnd) return { i: one({ ...i, pos: i.pos - d.len }), d: one({ ...d }) }
  // Insert inside the deleted range: the text survives at the range start,
  // the delete splits around it.
  const before = del(d.pos, i.pos - d.pos, d.tag)
  const after = del(d.pos + i.text.length, dEnd - i.pos, d.tag)
  return { i: one({ ...i, pos: d.pos }), d: two(before, after) }
}

function delVsDel(a, b) {
  const aEnd = a.pos + a.len
  const bEnd = b.pos + b.len
  const lo = Math.max(a.pos, b.pos)
  const hi = Math.min(aEnd, bEnd)
  const overlap = hi > lo ? hi - lo : 0
  const pos = a.pos <= b.pos ? a.pos : a.pos >= bEnd ? a.pos - b.len : b.pos
  return { ...a, len: a.len - overlap, pos }
}

// Returns { a: a rewritten to apply after b, b: b rewritten to apply after a }.
export function xformPrim(a, b, aWins) {
  if (a.kind === 'ins') {
    if (b.kind === 'ins') {
      const a2 = { ...a }
      const b2 = { ...b }
      if (a.pos < b.pos || (a.pos === b.pos && aWins)) b2.pos += a.text.length
      else a2.pos += b.text.length
      return { a: one(a2), b: one(b2) }
    }
    const r = insVsDel(a, b)
    return { a: r.i, b: r.d }
  }
  if (b.kind === 'ins') {
    const r = insVsDel(b, a)
    return { a: r.d, b: r.i }
  }
  return { a: one(delVsDel(a, b)), b: one(delVsDel(b, a)) }
}

// Transforms two primitive sequences made concurrently on the same text.
export function xform(a, b, aWins) {
  if (a.length === 0 || b.length === 0) return { a: [...a], b: [...b] }
  if (a.length === 1 && b.length === 1) return xformPrim(a[0], b[0], aWins)
  if (a.length > 1) {
    const first = xform(a.slice(0, 1), b, aWins)
    const rest = xform(a.slice(1), first.b, aWins)
    return { a: [...first.a, ...rest.a], b: rest.b }
  }
  const first = xform(a, b.slice(0, 1), aWins)
  const rest = xform(first.a, b.slice(1), aWins)
  return { a: rest.a, b: [...first.b, ...rest.b] }
}

// The client algorithm: remember own edits until the engine has seen them,
// transform incoming patches over the rest (remote wins ties).
export class OtClient {
  constructor() {
    this.pending = [] // own primitives, tagged with their edit seq
    this.pseq = 0 // last patch applied; sent as `ack`
  }

  reset(pseq = 0) {
    this.pending = []
    this.pseq = pseq
  }

  // A local edit (already applied to the local text) with its seq.
  local(seq, edit) {
    this.pending.push(...fromEdit(edit.pos, edit.del, edit.ins, seq))
  }

  // A §1 `patch` event. Returns the primitives to apply to the local text, in order.
  remote(patch) {
    const keep = this.pending.filter(p => p.tag > patch.base)
    const r = xform(fromEdit(patch.pos, patch.del, patch.ins, patch.pseq), keep, true)
    this.pending = r.b
    if (patch.pseq !== undefined) this.pseq = patch.pseq
    return r.a
  }
}

export function applyPrim(text, p) {
  if (p.kind === 'ins') {
    if (p.pos > text.length) throw new RangeError('insert out of range')
    return text.slice(0, p.pos) + p.text + text.slice(p.pos)
  }
  if (p.pos + p.len > text.length) throw new RangeError('delete out of range')
  return text.slice(0, p.pos) + text.slice(p.pos + p.len)
}

export function applyPrims(text, prims) {
  for (const p of prims) text = applyPrim(text, p)
  return text
}

// Applies { pos, del, ins } to a string.
export function applyEdit(text, e) {
  if (e.pos < 0 || e.del < 0 || e.pos + e.del > text.length) throw new RangeError('edit out of range')
  return text.slice(0, e.pos) + e.ins + text.slice(e.pos + e.del)
}

// Splits a CodeMirror transaction's changes into sequential edits:
// `changes` is a list of { fromA, toA, inserted } in ascending, non-overlapping
// order on the OLD document; each returned edit applies to the text left by
// the previous one.
export function sequentialEdits(changes) {
  const out = []
  let offset = 0
  for (const c of changes) {
    const d = c.toA - c.fromA
    out.push({ pos: c.fromA + offset, del: d, ins: c.inserted })
    offset += c.inserted.length - d
  }
  return out
}
