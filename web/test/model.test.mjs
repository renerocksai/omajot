import { test } from 'node:test'
import assert from 'node:assert/strict'
import { notesFor, sections, tagCounts, folderTree, folderCounts, syncLine } from '../src/model.js'

const NOW = new Date('2026-09-25T15:00:00').getTime()
const DAY = 86400000
const n = (id, fields) => ({ id, title: id, snippet: '', folder: null, tags: [], pinned: false, trashed: false, created: 0, updated: NOW, ...fields })

const folders = [
  { id: 'f-a', name: 'Work', parent: null },
  { id: 'f-b', name: 'Clients', parent: 'f-a' },
  { id: 'f-c', name: 'Home', parent: null },
]
const notes = [
  n('n1', { folder: 'f-a', tags: ['todo'], updated: NOW - 1000 }),
  n('n2', { folder: 'f-b', tags: ['todo', 'acme'], updated: NOW - 2 * DAY }),
  n('n3', { pinned: true, updated: NOW - 40 * DAY }),
  n('n4', { trashed: true, tags: ['todo'] }),
  n('n5', { folder: 'f-c', updated: NOW - 1 * DAY - 1000 }),
]

test('notesFor filters by source and keeps trash separate', () => {
  const ids = (src) => notesFor(notes, src, folders).map(x => x.id)
  assert.deepEqual(ids({ kind: 'all' }), ['n3', 'n1', 'n5', 'n2'])
  assert.deepEqual(ids({ kind: 'none' }), ['n3'])
  assert.deepEqual(ids({ kind: 'folder', id: 'f-a' }), ['n1', 'n2']) // includes subfolders
  assert.deepEqual(ids({ kind: 'tag', tag: 'todo' }), ['n1', 'n2'])
  assert.deepEqual(ids({ kind: 'trash' }), ['n4'])
})

test('sections follow Apple Notes grouping', () => {
  const s = sections(notesFor(notes, { kind: 'all' }, folders), NOW, 'en-US')
  assert.deepEqual(s.map(x => [x.label, x.notes.map(y => y.id)]), [
    ['Pinned', ['n3']], ['Today', ['n1']], ['Yesterday', ['n5']], ['Previous 7 Days', ['n2']],
  ])
})

test('tag counts skip trashed notes', () => {
  assert.deepEqual(tagCounts(notes), [{ tag: 'acme', count: 1 }, { tag: 'todo', count: 2 }])
})

test('folder tree is ordered with depth and survives cycles', () => {
  assert.deepEqual(folderTree(folders).map(f => [f.name, f.depth]), [['Home', 0], ['Work', 0], ['Clients', 1]])
  const cyclic = [{ id: 'x', name: 'X', parent: 'y' }, { id: 'y', name: 'Y', parent: 'x' }]
  assert.equal(folderTree(cyclic).length, 2)
  assert.deepEqual(Object.fromEntries(folderCounts(notes, folders)), { 'f-a': 2, 'f-b': 1, 'f-c': 1 })
})

test('sync status line', () => {
  assert.deepEqual(syncLine({ state: 'online', pending: 0 }), { text: 'Up to date', tone: 'ok' })
  assert.equal(syncLine({ state: 'online', pending: 3 }).text, 'Syncing 3 changes…')
  assert.equal(syncLine({ state: 'offline', pending: 1 }).text, 'Offline · 1 change waiting')
})
