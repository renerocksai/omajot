// omajot web app: folders + tags → note list → editor, Apple Notes style.
// Narrow screens show one pane at a time; wide screens show all three.
import { Replica } from './replica.js'
import { NoteEditor } from './editor.js'
import { renderMarkdown, toggleTaskEdit, escapeHtml } from './markdown.js'
import { Attachments } from './attach.js'
import { icon } from './icons.js'
import { qrSvg } from './qr.js'
import { notesFor, sections, tagCounts, folderTree, folderCounts, syncLine, shortDate } from './model.js'

const $ = (sel, root = document) => root.querySelector(sel)
const store = {
  get(k, d) { try { return localStorage.getItem('omajot.' + k) ?? d } catch { return d } },
  set(k, v) { try { localStorage.setItem('omajot.' + k, v) } catch { /* private mode */ } },
}

const state = {
  notes: new Map(),
  folders: [],
  source: { kind: 'all' },
  query: '',
  searchIds: null,
  current: null,
  createdHere: new Set(),
  mode: store.get('mode', 'edit'), // edit | preview | split
  sync: null,
}

let replica, editor, attachments
let app

// ------------------------------------------------------------------ shell

function shell() {
  document.body.innerHTML = `
  <div class="app" data-view="list" data-mode="${state.mode}">
    <aside class="pane p-folders" aria-label="Folders">
      <header class="bar">
        <h1>Folders</h1>
        <button class="icon-btn" data-act="phone" title="Show on phone" aria-label="Show on phone">${icon('phone')}</button>
        <button class="icon-btn" data-act="new-folder" title="New folder">${icon('folderPlus')}</button>
      </header>
      <nav class="folders scroll"></nav>
      <footer class="status"><span class="dot"></span><span class="status-text">Starting…</span></footer>
    </aside>
    <section class="pane p-list" aria-label="Notes">
      <header class="bar">
        <button class="back" data-act="to-folders">${icon('back')}<span>Folders</span></button>
        <button class="icon-btn only-mid" data-act="toggle-sidebar" title="Folders">${icon('sidebar')}</button>
        <h1 class="list-title">Notes</h1>
        <button class="icon-btn accent" data-act="new-note" title="New note">${icon('compose')}</button>
      </header>
      <label class="search">${icon('search')}<input type="search" placeholder="Search" enterkeyhint="search" autocomplete="off"></label>
      <div class="notes scroll" role="list"></div>
      <footer class="list-foot"><span class="count"></span></footer>
    </section>
    <section class="pane p-editor" aria-label="Note">
      <header class="bar">
        <button class="back" data-act="to-list">${icon('back')}<span class="back-label">Notes</span></button>
        <span class="crumb"></span>
        <div class="actions">
          <button class="icon-btn" data-act="pin" title="Pin">${icon('pin')}</button>
          <button class="icon-btn" data-act="move" title="Move to folder">${icon('move')}</button>
          <button class="icon-btn" data-act="trash" title="Delete">${icon('trash')}</button>
          <button class="icon-btn mode-btn" data-act="mode" title="Preview">${icon('eye')}</button>
        </div>
      </header>
      <div class="trash-banner" hidden>This note is in Trash. <button data-act="restore">Restore</button></div>
      <div class="doc">
        <div class="cm-host"></div>
        <article class="preview md"></article>
      </div>
      <div class="empty-editor">${icon('note')}<p>No note selected</p></div>
      <footer class="toolbar">
        <button class="icon-btn" data-act="checklist" title="Checklist">${icon('checklist')}</button>
        <button class="icon-btn" data-act="camera" title="Add photo">${icon('camera')}</button>
        <button class="icon-btn mode-btn" data-act="mode" title="Preview">${icon('eye')}</button>
        <span class="spacer"></span>
        <button class="icon-btn accent" data-act="new-note" title="New note">${icon('compose')}</button>
      </footer>
    </section>
    <div class="scrim" data-act="close-sidebar"></div>
  </div>
  <div class="modal-root"></div>
  <div class="toasts" aria-live="polite"></div>
  <input class="file-input" type="file" accept="image/*" multiple hidden>`
  app = $('.app')
}

// --------------------------------------------------------------- navigation

const narrow = () => matchMedia('(max-width: 759px)').matches

function go(view, push = true) {
  const prev = app.dataset.view
  app.dataset.view = view
  const depth = { folders: 0, list: 1, editor: 2 }
  if (push && narrow() && depth[view] > depth[prev]) history.pushState({ view }, '')
}

addEventListener('popstate', () => {
  if (!narrow()) return
  if (app.dataset.view === 'editor') leaveEditor()
  else if (app.dataset.view === 'list') go('folders', false)
})

function back(to) {
  if (narrow() && history.state?.view) history.back()
  else if (to === 'list') leaveEditor()
  else go(to, false)
}

// ------------------------------------------------------------------ render

// Replaces markup only when it changed, so frequent renders (sync state,
// remote edits) never swap out a row under the user's finger.
function setHtml(el, html) {
  if (el._html === html) return
  el._html = html
  el.innerHTML = html
}

let frame = 0
function render() {
  if (frame) return
  frame = requestAnimationFrame(() => {
    frame = 0
    renderFolders()
    renderList()
    renderEditorChrome()
  })
}

function sourceTitle(src) {
  if (src.kind === 'all') return 'All Notes'
  if (src.kind === 'none') return 'Notes'
  if (src.kind === 'trash') return 'Trash'
  if (src.kind === 'tag') return '#' + src.tag
  return state.folders.find(f => f.id === src.id)?.name || 'Folder'
}

const sameSource = (a, b) => a.kind === b.kind && a.id === b.id && a.tag === b.tag

function renderFolders() {
  const all = [...state.notes.values()]
  const live = all.filter(n => !n.trashed)
  const counts = folderCounts(all, state.folders)
  const row = (src, iconName, label, count, depth = 0, menu = false) => `
    <div class="frow ${sameSource(src, state.source) ? 'sel' : ''}" style="--depth:${depth}" data-src='${escapeHtml(JSON.stringify(src))}'>
      ${icon(iconName)}<span class="fname">${escapeHtml(label)}</span><span class="fcount">${count}</span>
      ${menu ? `<button class="icon-btn fmenu" data-act="folder-menu" title="Folder actions">${icon('more')}</button>` : ''}
    </div>`
  let html = '<div class="group">'
  html += row({ kind: 'all' }, 'inbox', 'All Notes', live.length)
  html += row({ kind: 'none' }, 'folder', 'Notes', live.filter(n => !n.folder).length)
  for (const f of folderTree(state.folders)) html += row({ kind: 'folder', id: f.id }, 'folder', f.name, counts.get(f.id) || 0, f.depth + 1, true)
  const trashed = all.length - live.length
  if (trashed) html += row({ kind: 'trash' }, 'trash', 'Trash', trashed)
  html += '</div>'
  const tags = tagCounts(all)
  if (tags.length) {
    html += '<h2 class="caption">Tags</h2><div class="tags">'
    for (const t of tags) {
      const sel = state.source.kind === 'tag' && state.source.tag === t.tag
      html += `<button class="chip ${sel ? 'sel' : ''}" data-src='${escapeHtml(JSON.stringify({ kind: 'tag', tag: t.tag }))}'>#${escapeHtml(t.tag)}<span>${t.count}</span></button>`
    }
    html += '</div>'
  }
  setHtml($('.p-folders .folders'), html)
  const line = syncLine(state.sync)
  $('.status-text').textContent = line.text
  $('.status').dataset.tone = line.tone
}

function visibleNotes() {
  const all = [...state.notes.values()]
  if (state.searchIds) {
    return state.searchIds.map(id => state.notes.get(id)).filter(n => n && !n.trashed)
  }
  return notesFor(all, state.source, state.folders)
}

function renderList() {
  $('.list-title').textContent = state.searchIds ? 'Search' : sourceTitle(state.source)
  $('.back-label').textContent = state.searchIds ? 'Search' : sourceTitle(state.source)
  const notes = visibleNotes()
  const showFolder = state.source.kind === 'all' || state.source.kind === 'tag' || state.searchIds
  const folderName = (id) => state.folders.find(f => f.id === id)?.name || 'Notes'
  const rowHtml = (n) => `
    <div class="nrow ${n.id === state.current ? 'sel' : ''}" role="listitem" data-id="${escapeHtml(n.id)}" tabindex="0">
      <div class="ntitle">${n.pinned ? icon('pin', 'pinned') : ''}${escapeHtml(n.title || 'New Note')}</div>
      <div class="nmeta"><span class="ndate">${escapeHtml(shortDate(n.updated))}</span>
        <span class="nsnip">${escapeHtml(n.snippet || 'No additional text')}</span></div>
      ${showFolder ? `<div class="nfolder">${icon('folder')}${escapeHtml(folderName(n.folder))}</div>` : ''}
    </div>`
  let html = ''
  if (state.searchIds) {
    html = `<div class="section"><h2 class="caption">Top Hits</h2><div class="card">${notes.map(rowHtml).join('')}</div></div>`
  } else {
    for (const s of sections(notes)) {
      html += `<div class="section"><h2 class="caption">${escapeHtml(s.label)}</h2><div class="card">${s.notes.map(rowHtml).join('')}</div></div>`
    }
  }
  if (!notes.length) html = `<p class="empty">${state.searchIds ? 'No results' : 'No Notes'}</p>`
  setHtml($('.p-list .notes'), html)
  const count = notes.length === 1 ? '1 Note' : `${notes.length} Notes`
  const line = syncLine(state.sync)
  $('.p-list .count').textContent = line.tone === 'ok' ? count : `${count} · ${line.text}`
  $('.list-foot').dataset.tone = line.tone
}

function renderEditorChrome() {
  const n = state.current && state.notes.get(state.current)
  app.classList.toggle('has-note', !!n)
  $('.trash-banner').hidden = !(n && n.trashed)
  if (!n) return
  const folder = state.folders.find(f => f.id === n.folder)?.name || 'Notes'
  $('.crumb').textContent = `${folder} · ${new Date(n.updated).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })}`
  $('[data-act="pin"]').classList.toggle('on', n.pinned)
  $('[data-act="pin"]').title = n.pinned ? 'Unpin' : 'Pin'
}

function setMode(mode) {
  if (mode === 'split' && narrow()) mode = 'preview'
  state.mode = mode
  app.dataset.mode = mode
  store.set('mode', mode)
  for (const b of document.querySelectorAll('.mode-btn')) {
    const next = nextMode()
    b.innerHTML = icon(next === 'edit' ? 'pencil' : next === 'split' ? 'split' : 'eye')
    b.title = next === 'edit' ? 'Edit' : next === 'split' ? 'Side by side' : 'Preview'
  }
  renderPreview()
}

function nextMode() {
  if (narrow()) return state.mode === 'edit' ? 'preview' : 'edit'
  return { edit: 'split', split: 'preview', preview: 'edit' }[state.mode] || 'edit'
}

let previewTimer = 0
function renderPreview(delay = 0) {
  clearTimeout(previewTimer)
  if (state.mode === 'edit' || !state.current) return
  previewTimer = setTimeout(() => {
    $('.preview').innerHTML = renderMarkdown(editor.text, { resolveAttachment: attachments.resolve, title: true })
  }, delay)
}

// ------------------------------------------------------------------ actions

function selectSource(src) {
  state.source = src
  state.query = ''
  state.searchIds = null
  $('.search input').value = ''
  render()
  go('list')
  closeSidebar()
}

function openNote(id, { focus = false } = {}) {
  if (state.current && state.current !== id) closeCurrent()
  const reply = replica.call('open', { note: id })
  if (!reply.ok) return toast('Could not open the note: ' + reply.error)
  state.current = id
  editor.load(id, reply.text, reply.seq, reply.pseq)
  render()
  renderPreview()
  go('editor')
  if (focus) setTimeout(() => editor.focus(), 50)
}

// Closes the open note; a note created here and left empty goes to Trash.
function closeCurrent() {
  const id = state.current
  if (!id) return
  if (state.createdHere.has(id) && editor.text.trim() === '') replica.call('set', { note: id, trashed: true })
  replica.call('close', { note: id })
  state.current = null
  editor.unload()
}

function leaveEditor() {
  closeCurrent()
  render()
  go('list', false)
}

function newNote() {
  const folder = state.source.kind === 'folder' ? state.source.id : null
  const text = state.source.kind === 'tag' ? `\n\n#${state.source.tag}` : ''
  const { note } = replica.request('create', { folder, text })
  state.createdHere.add(note)
  if (state.source.kind === 'trash') state.source = { kind: 'all' }
  if (state.searchIds) { state.searchIds = null; state.query = ''; $('.search input').value = '' }
  openNote(note, { focus: true })
  if (state.mode === 'preview') setMode('edit')
}

async function newFolder(parent = null) {
  const name = await ask({ title: parent ? 'New Subfolder' : 'New Folder', input: '', placeholder: 'Name', ok: 'Save' })
  if (!name) return
  const { folder } = replica.request('folder.create', { name, parent })
  selectSource({ kind: 'folder', id: folder })
}

async function folderMenu(id) {
  const f = state.folders.find(x => x.id === id)
  if (!f) return
  const choice = await ask({ title: f.name, buttons: [
    { label: 'Rename', value: 'rename' }, { label: 'New Subfolder', value: 'sub' },
    { label: 'Delete Folder', value: 'delete', danger: true }] })
  if (choice === 'rename') {
    const name = await ask({ title: 'Rename Folder', input: f.name, ok: 'Save' })
    if (name && name !== f.name) replica.request('folder.rename', { folder: id, name })
  } else if (choice === 'sub') {
    await newFolder(id)
  } else if (choice === 'delete') {
    const ok = await ask({ title: `Delete “${f.name}”?`, message: 'Its notes move to Notes; subfolders move up one level.',
      buttons: [{ label: 'Delete', value: 'yes', danger: true }] })
    if (ok === 'yes') {
      replica.request('folder.delete', { folder: id })
      if (state.source.kind === 'folder' && state.source.id === id) state.source = { kind: 'all' }
    }
  }
  render()
}

async function moveNote() {
  const n = state.notes.get(state.current)
  if (!n) return
  const buttons = [{ label: 'Notes', value: '' }, ...folderTree(state.folders).map(f =>
    ({ label: ' '.repeat(f.depth) + f.name, value: f.id, current: f.id === n.folder }))]
  const choice = await ask({ title: 'Move to Folder', buttons })
  if (choice === null || choice === undefined) return
  replica.request('set', { note: n.id, folder: choice || null })
}

function togglePin() {
  const n = state.notes.get(state.current)
  if (n) replica.request('set', { note: n.id, pinned: !n.pinned })
}

function trashNote() {
  const n = state.notes.get(state.current)
  if (!n) return
  if (n.trashed) return toast('Already in Trash')
  replica.request('set', { note: n.id, trashed: true })
  state.createdHere.delete(n.id)
  toast('Moved to Trash', { label: 'Undo', run: () => replica.request('set', { note: n.id, trashed: false }) })
  back('list')
}

let searchTimer = 0
function onSearch(q) {
  state.query = q
  clearTimeout(searchTimer)
  searchTimer = setTimeout(() => {
    state.searchIds = q.trim() ? replica.request('search', { q: q.trim() }).ids : null
    render()
  }, 120)
}

// ---------------------------------------------------------------- dialogs

// ask({ title, message, input, placeholder, ok, buttons }) → string | null
// This app's address as a QR code, for opening omajot on a phone. The matrix
// comes from the core (the same encoder as `omajot qr` and the plugin).
// Plain URLs in already-escaped text as links (the footer names tailscale.com).
function linkify(escaped) {
  return escaped.replace(/https:\/\/[^\s<]+[^\s<.,;:!?]/g, (u) => `<a href="${u}" target="_blank" rel="noopener">${u}</a>`)
}

function showOnPhone() {
  const url = location.origin + '/'
  let svg, footer = ''
  try {
    const code = replica.request('qr', { text: url })
    svg = qrSvg(code, 'QR code for ' + url)
    footer = code.footer || ''
  } catch (e) {
    return toast('No QR code: ' + e.message)
  }
  const root = $('.modal-root')
  root.innerHTML = `
    <div class="modal-scrim"></div>
    <div class="modal qr-modal" role="dialog" aria-modal="true" aria-label="Show on phone">
      <h2>Open omajot on your phone</h2>
      <div class="qr-box">${svg}</div>
      <p class="qr-url">${escapeHtml(url)}</p>
      <p>Scan with your phone's camera, then Share → Add to Home Screen.</p>
      ${footer ? `<p class="qr-footer">${linkify(escapeHtml(footer))}</p>` : ''}
      <div class="modal-buttons"><button data-cancel>Close</button></div>
    </div>`
  root.classList.add('open')
  const close = () => {
    root.classList.remove('open')
    root.innerHTML = ''
    document.removeEventListener('keydown', onKey, true)
  }
  const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); close() } }
  document.addEventListener('keydown', onKey, true)
  root.onclick = (e) => {
    if (e.target.classList.contains('modal-scrim') || e.target.closest('[data-cancel]')) close()
  }
  $('[data-cancel]', root).focus()
}

function ask(opts) {
  return new Promise((resolve) => {
    const root = $('.modal-root')
    const input = opts.input !== undefined
    root.innerHTML = `
      <div class="modal-scrim"></div>
      <div class="modal" role="dialog" aria-modal="true" aria-label="${escapeHtml(opts.title)}">
        <h2>${escapeHtml(opts.title)}</h2>
        ${opts.message ? `<p>${escapeHtml(opts.message)}</p>` : ''}
        ${input ? `<input class="modal-input" value="${escapeHtml(opts.input)}" placeholder="${escapeHtml(opts.placeholder || '')}" autocapitalize="words">` : ''}
        <div class="modal-buttons ${opts.buttons ? 'list' : ''}">
          ${(opts.buttons || []).map((b, i) => `<button data-i="${i}" class="${b.danger ? 'danger' : ''} ${b.current ? 'current' : ''}">${escapeHtml(b.label)}</button>`).join('')}
          <button data-cancel>Cancel</button>
          ${input ? `<button data-ok class="strong">${escapeHtml(opts.ok || 'OK')}</button>` : ''}
        </div>
      </div>`
    root.classList.add('open')
    const finish = (v) => {
      root.classList.remove('open')
      root.innerHTML = ''
      resolve(v)
    }
    const field = $('.modal-input', root)
    if (field) {
      field.focus()
      field.select()
      field.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') finish(field.value.trim() || null)
        if (e.key === 'Escape') finish(null)
      })
    }
    root.onclick = (e) => {
      const b = e.target.closest('button')
      if (e.target.classList.contains('modal-scrim') || (b && 'cancel' in b.dataset)) return finish(null)
      if (b && 'ok' in b.dataset) return finish(field.value.trim() || null)
      if (b && b.dataset.i !== undefined) return finish(opts.buttons[+b.dataset.i].value)
    }
  })
}

function toast(text, action) {
  const el = document.createElement('div')
  el.className = 'toast'
  el.innerHTML = `<span>${escapeHtml(text)}</span>${action ? `<button>${escapeHtml(action.label)}</button>` : ''}`
  if (action) el.querySelector('button').onclick = () => { action.run(); el.remove() }
  $('.toasts').append(el)
  setTimeout(() => el.remove(), action ? 6000 : 3500)
}

// ---------------------------------------------------------------- sidebar (mid widths)

function toggleSidebar() { app.classList.toggle('sidebar-open') }
function closeSidebar() { app.classList.remove('sidebar-open') }

// ------------------------------------------------------------------ events

function wire() {
  app.addEventListener('click', (e) => {
    const src = e.target.closest('[data-src]')
    const act = e.target.closest('[data-act]')?.dataset.act
    if (act === 'folder-menu') {
      e.stopPropagation()
      return folderMenu(JSON.parse(e.target.closest('[data-src]').dataset.src).id)
    }
    if (src && !act) return selectSource(JSON.parse(src.dataset.src))
    const row = e.target.closest('.nrow')
    if (row) return openNote(row.dataset.id)
    switch (act) {
      case 'new-note': return newNote()
      case 'new-folder': return newFolder()
      case 'to-folders': return back('folders')
      case 'to-list': return back('list')
      case 'pin': return togglePin()
      case 'move': return moveNote()
      case 'trash': return trashNote()
      case 'restore': return state.current && replica.request('set', { note: state.current, trashed: false })
      case 'mode': return setMode(nextMode())
      case 'checklist': return editor.checklist()
      case 'camera': return $('.file-input').click()
      case 'toggle-sidebar': return toggleSidebar()
      case 'close-sidebar': return closeSidebar()
      case 'phone': return showOnPhone()
    }
  })
  app.addEventListener('keydown', (e) => {
    const row = e.target.closest?.('.nrow')
    if (row && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); openNote(row.dataset.id) }
  })
  $('.search input').addEventListener('input', (e) => onSearch(e.target.value))
  $('.file-input').addEventListener('change', async (e) => {
    const files = [...e.target.files]
    e.target.value = ''
    if (files.length && state.current) {
      if (state.mode === 'preview') setMode(narrow() ? 'edit' : 'split')
      await editor.insertFiles(files)
    }
  })
  $('.preview').addEventListener('click', (e) => {
    const box = e.target.closest('input.task')
    if (!box) return
    e.preventDefault()
    const edit = toggleTaskEdit(editor.text, +box.dataset.off)
    if (edit) editor.edit(edit)
  })
  document.addEventListener('keydown', (e) => {
    if ($('.modal-root.open')) return
    const inText = e.target.closest?.('.cm-editor, input, textarea')
    if (e.key === '/' && !inText) { e.preventDefault(); $('.search input').focus() }
    if (e.key === 'Escape' && app.dataset.view === 'editor' && narrow()) back('list')
    if ((e.metaKey || e.ctrlKey) && e.altKey && e.key.toLowerCase() === 'n') { e.preventDefault(); newNote() }
  })
  addEventListener('pagehide', () => replica.flushOps())
  document.addEventListener('visibilitychange', () => { if (document.hidden) replica.flushOps() })
  addEventListener('online', () => replica.sync.online())
  addEventListener('offline', () => replica.sync.offline())
  matchMedia('(max-width: 759px)').addEventListener('change', () => setMode(state.mode))

  // Keep the editor toolbar above the on-screen keyboard (iOS overlays it).
  const vv = window.visualViewport
  if (vv) {
    const fit = () => {
      document.documentElement.style.setProperty('--vvh', vv.height + 'px')
      document.documentElement.style.setProperty('--vvtop', vv.offsetTop + 'px')
    }
    vv.addEventListener('resize', fit)
    vv.addEventListener('scroll', fit)
    fit()
  }
}

function onEvent(ev) {
  switch (ev.ev) {
    case 'notes':
      for (const n of ev.upsert) state.notes.set(n.id, n)
      if (state.searchIds && state.query) onSearch(state.query)
      return render()
    case 'folders':
      state.folders = ev.folders
      return render()
    case 'patch':
      editor.applyPatch(ev)
      return
    case 'sync':
      state.sync = ev
      return render()
    case 'error':
      return toast(ev.error)
  }
}

// ------------------------------------------------------------------ one instance

// Two live instances on one device would share a replica id and reuse op
// counters, so the replica is guarded by a Web Lock held for the page's
// lifetime. A second tab waits briefly, then offers to take over.
function acquireReplicaLock() {
  if (!navigator.locks) return Promise.resolve()
  return new Promise((resolve) => {
    let granted = false
    const request = (steal) => navigator.locks.request('omajot-replica', steal ? { steal: true } : {}, () => {
      granted = true
      blocker(null)
      resolve()
      return new Promise(() => {}) // held until the page goes away
    }).catch(() => {
      if (granted) lostReplicaLock()
    })
    request(false)
    setTimeout(() => {
      if (!granted) blocker('omajot is open in another tab or window.', 'Use here', () => request(true))
    }, 1500)
  })
}

function lostReplicaLock() {
  replica?.stop()
  blocker('omajot is now open in another tab or window.', 'Reload', () => location.reload())
}

function blocker(text, label, action) {
  document.querySelector('.blocker')?.remove()
  if (!text) return
  const el = document.createElement('div')
  el.className = 'blocker'
  el.innerHTML = `<div class="modal"><h2>${escapeHtml(text)}</h2><div class="modal-buttons"><button class="strong">${escapeHtml(label)}</button></div></div>`
  el.querySelector('button').onclick = () => action()
  document.body.append(el)
}

// ------------------------------------------------------------------ start

// iOS Safari (not the home-screen app) floats its toolbar over the bottom of
// the page, and the safe-area inset does not cover it.
function markIosBrowser() {
  const ios = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
  const standalone = navigator.standalone || matchMedia('(display-mode: standalone)').matches
  document.documentElement.classList.toggle('ios-browser', ios && !standalone)
}

async function main() {
  markIosBrowser()
  shell()
  app.classList.add('loading')
  await acquireReplicaLock()
  try {
    replica = await Replica.open()
  } catch (e) {
    app.classList.remove('loading')
    app.classList.add('failed')
    $('.status-text').textContent = 'Could not start: ' + e.message
    $('.empty-editor p').textContent = 'omajot could not start: ' + e.message
    throw e
  }
  attachments = new Attachments(replica.store, () => replica.sync.schedule(0))
  await attachments.restore()
  editor = new NoteEditor($('.cm-host'), {
    replica,
    attach: (file) => attachments.add(file),
    resolveAttachment: (name) => attachments.resolve(name),
    onDocChanged: () => renderPreview(150),
    onError: (msg) => toast(msg),
    reload: () => state.current && openNote(state.current),
  })
  replica.on(onEvent)
  const { notes, folders } = replica.request('list')
  for (const n of notes) state.notes.set(n.id, n)
  state.folders = folders
  wire()
  setMode(state.mode)
  if (!narrow()) {
    const first = notesFor(notes, state.source, folders)[0]
    if (first) openNote(first.id)
  }
  render()
  app.classList.remove('loading')
  await replica.start()

  if ('serviceWorker' in navigator && location.protocol !== 'file:') {
    navigator.serviceWorker.register('sw.js').catch((e) => console.warn('service worker:', e))
    let reloadOffered = !!navigator.serviceWorker.controller
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      if (reloadOffered) toast('omajot was updated', { label: 'Reload', run: () => location.reload() })
      reloadOffered = true
    })
  }
  window.omajot = { replica, state, editor } // for debugging and the e2e tests
}

main()
