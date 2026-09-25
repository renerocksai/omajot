// Pure view logic over NoteSummary / Folder (docs/PROTOCOL.md §1): which
// notes a sidebar entry shows, in what order and sections, tag counts, the
// folder tree, and the sync status line.

// source: { kind: 'all' } | { kind: 'none' } | { kind: 'folder', id } | { kind: 'tag', tag } | { kind: 'trash' }
export function notesFor(notes, source, folders = []) {
  const list = []
  const inFolder = source.kind === 'folder' ? descendants(folders, source.id) : null
  for (const n of notes) {
    if (source.kind === 'trash') { if (n.trashed) list.push(n); continue }
    if (n.trashed) continue
    if (source.kind === 'all') list.push(n)
    else if (source.kind === 'none') { if (!n.folder) list.push(n) }
    else if (source.kind === 'folder') { if (inFolder.has(n.folder)) list.push(n) }
    else if (source.kind === 'tag') { if (n.tags.includes(source.tag)) list.push(n) }
  }
  return list.sort(byPinnedThenUpdated)
}

export function byPinnedThenUpdated(a, b) {
  if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
  return b.updated - a.updated || (a.id < b.id ? -1 : 1)
}

// A folder and all folders below it.
export function descendants(folders, id) {
  const out = new Set([id])
  let grew = true
  while (grew) {
    grew = false
    for (const f of folders) {
      if (f.parent && out.has(f.parent) && !out.has(f.id)) { out.add(f.id); grew = true }
    }
  }
  return out
}

// Apple Notes-style sections: Pinned, Today, Yesterday, Previous 7 Days,
// Previous 30 Days, then one per month ("September 2026").
export function sections(sorted, now = Date.now(), locale = undefined) {
  const out = []
  const day = 86400000
  const start = new Date(now)
  start.setHours(0, 0, 0, 0)
  const today = start.getTime()
  const label = (n) => {
    if (n.pinned) return 'Pinned'
    if (n.updated >= today) return 'Today'
    if (n.updated >= today - day) return 'Yesterday'
    if (n.updated >= today - 7 * day) return 'Previous 7 Days'
    if (n.updated >= today - 30 * day) return 'Previous 30 Days'
    return new Date(n.updated).toLocaleDateString(locale, { month: 'long', year: 'numeric' })
  }
  for (const n of sorted) {
    const l = label(n)
    if (!out.length || out[out.length - 1].label !== l) out.push({ label: l, notes: [] })
    out[out.length - 1].notes.push(n)
  }
  return out
}

export function tagCounts(notes) {
  const counts = new Map()
  for (const n of notes) {
    if (n.trashed) continue
    for (const t of n.tags) counts.set(t, (counts.get(t) || 0) + 1)
  }
  return [...counts].sort((a, b) => (a[0] < b[0] ? -1 : 1)).map(([tag, count]) => ({ tag, count }))
}

// Folder tree as a flat, ordered list with depth, children sorted by name.
// Folders whose parent is missing (or that sit in a cycle) show at the root.
export function folderTree(folders) {
  const byParent = new Map()
  const ids = new Set(folders.map(f => f.id))
  for (const f of folders) {
    const p = f.parent && ids.has(f.parent) ? f.parent : null
    if (!byParent.has(p)) byParent.set(p, [])
    byParent.get(p).push(f)
  }
  for (const list of byParent.values()) list.sort((a, b) => a.name.localeCompare(b.name))
  const out = []
  const seen = new Set()
  const walk = (parent, depth) => {
    for (const f of byParent.get(parent) || []) {
      if (seen.has(f.id)) continue
      seen.add(f.id)
      out.push({ ...f, depth })
      walk(f.id, depth + 1)
    }
  }
  walk(null, 0)
  for (const f of folders) if (!seen.has(f.id)) out.push({ ...f, depth: 0 }) // cycles
  return out
}

export function folderCounts(notes, folders) {
  const direct = new Map()
  for (const n of notes) if (!n.trashed && n.folder) direct.set(n.folder, (direct.get(n.folder) || 0) + 1)
  const counts = new Map()
  for (const f of folders) {
    let c = 0
    for (const id of descendants(folders, f.id)) c += direct.get(id) || 0
    counts.set(f.id, c)
  }
  return counts
}

export function syncLine(s) {
  if (!s) return { text: 'Starting…', tone: 'muted' }
  const waiting = s.pending === 1 ? '1 change waiting' : `${s.pending} changes waiting`
  let r
  if (s.state === 'offline') r = { text: s.pending ? `Offline · ${waiting}` : 'Offline', tone: 'warn' }
  else if (s.state === 'conflict') r = { text: s.pending ? `Sync conflict · ${waiting}` : 'Sync conflict', tone: 'warn' }
  else if (s.state === 'connecting') r = { text: s.pending ? `Connecting · ${waiting}` : 'Connecting…', tone: 'muted' }
  else if (s.pending) r = { text: `Syncing ${s.pending === 1 ? '1 change' : s.pending + ' changes'}…`, tone: 'muted' }
  else r = { text: 'Up to date', tone: 'ok' }
  return r
}

export function shortDate(ms, now = Date.now(), locale = undefined) {
  const d = new Date(ms)
  const today = new Date(now)
  today.setHours(0, 0, 0, 0)
  if (ms >= today.getTime()) return d.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' })
  if (ms >= today.getTime() - 6 * 86400000) return d.toLocaleDateString(locale, { weekday: 'long' })
  return d.toLocaleDateString(locale, { day: 'numeric', month: 'numeric', year: '2-digit' })
}
