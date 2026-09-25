// The note editor: CodeMirror 6 on markdown source.
//
// - Every local change becomes §1 `edit` requests (UTF-16 positions, which is
//   what CodeMirror uses), numbered with the note's seq.
// - Remote `patch` events are transformed over our edits the engine had not
//   seen (OtClient, a port of src/core/ot.zig) and applied with
//   `addToHistory: false`, so undo only ever reverts our own edits
//   (CodeMirror maps its history over the remote changes).
// - Paste/drop: images and files become attachments, HTML becomes markdown.
import { EditorState, Transaction, Annotation, EditorSelection } from '@codemirror/state'
import { EditorView, keymap, placeholder, drawSelection, highlightActiveLine, ViewPlugin, Decoration, MatchDecorator } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap, indentMore, indentLess } from '@codemirror/commands'
import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { syntaxHighlighting, HighlightStyle } from '@codemirror/language'
import { tags as t } from '@lezer/highlight'
import { OtClient, sequentialEdits } from './patch.js'
import { htmlToMarkdown, dataImageRefs } from './html2md.js'
import { noteWidgets } from './widgets.js'

const remote = Annotation.define()

const highlight = HighlightStyle.define([
  { tag: t.heading1, class: 'md-h md-h1' },
  { tag: t.heading2, class: 'md-h md-h2' },
  { tag: [t.heading3, t.heading4, t.heading5, t.heading6], class: 'md-h md-h3' },
  { tag: t.strong, class: 'md-strong' },
  { tag: t.emphasis, class: 'md-em' },
  { tag: t.strikethrough, class: 'md-strike' },
  { tag: [t.link, t.url], class: 'md-link' },
  { tag: t.monospace, class: 'md-code' },
  { tag: t.quote, class: 'md-quote' },
  { tag: [t.processingInstruction, t.contentSeparator, t.labelName], class: 'md-mark' },
])

// #hashtags, same rule as the engine (start of line or after whitespace).
const tagMatcher = new MatchDecorator({
  regexp: /(?<=^|\s)#[\p{L}\p{N}_\-/]*[\p{L}_][\p{L}\p{N}_\-/]*/gu,
  decoration: Decoration.mark({ class: 'md-tag' }),
})
const hashtags = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = tagMatcher.createDeco(view) }
  update(u) { this.decorations = tagMatcher.updateDeco(u, this.decorations) }
}, { decorations: v => v.decorations })

function wrapSelection(mark) {
  return (view) => {
    view.dispatch(view.state.changeByRange(range => {
      const text = view.state.sliceDoc(range.from, range.to)
      if (text.startsWith(mark) && text.endsWith(mark) && text.length >= 2 * mark.length) {
        const inner = text.slice(mark.length, text.length - mark.length)
        return { changes: { from: range.from, to: range.to, insert: inner },
          range: EditorSelection.range(range.from, range.from + inner.length) }
      }
      return { changes: { from: range.from, to: range.to, insert: mark + text + mark },
        range: EditorSelection.range(range.from + mark.length, range.to + mark.length) }
    }))
    return true
  }
}

// Toggles "- [ ] " on every selected line (Apple Notes' checklist button).
export function toggleChecklist(view) {
  const { state } = view
  const lines = new Set()
  for (const r of state.selection.ranges) {
    for (let pos = r.from; pos <= r.to;) {
      const line = state.doc.lineAt(pos)
      lines.add(line.number)
      pos = line.to + 1
    }
  }
  const changes = []
  const all = [...lines].map(n => state.doc.line(n))
  const allTasks = all.every(l => /^\s*[-*+] \[[ xX]\] /.test(l.text))
  for (const line of all) {
    const m = /^(\s*)(?:[-*+] (?:\[[ xX]\] )?)?/.exec(line.text)
    const indent = m[1]
    const insert = allTasks ? indent : indent + '- [ ] '
    changes.push({ from: line.from, to: line.from + m[0].length, insert })
  }
  view.dispatch({ changes })
  view.focus()
  return true
}

export class NoteEditor {
  // host: { replica, attach(file) → Promise<markdown>, onDocChanged(text), onError(msg) }
  constructor(parent, host) {
    this.host = host
    this.note = null
    this.seq = 0
    this.ot = new OtClient()
    this.view = new EditorView({ parent, state: this.makeState('') })
  }

  makeState(doc) {
    return EditorState.create({
      doc,
      extensions: [
        history(),
        drawSelection(),
        highlightActiveLine(),
        EditorView.lineWrapping,
        markdown({ base: markdownLanguage, addKeymap: true }),
        syntaxHighlighting(highlight),
        hashtags,
        noteWidgets(this.host.resolveAttachment || (n => 'api/blobs/' + n)),
        placeholder('Start typing. The first line is the title.'),
        keymap.of([
          { key: 'Mod-b', run: wrapSelection('**') },
          { key: 'Mod-i', run: wrapSelection('*') },
          { key: 'Mod-Shift-l', run: toggleChecklist },
          { key: 'Tab', run: indentMore },
          { key: 'Shift-Tab', run: indentLess },
          ...historyKeymap,
          ...defaultKeymap,
        ]),
        EditorView.contentAttributes.of({ autocapitalize: 'sentences', autocorrect: 'on', spellcheck: 'true' }),
        EditorView.updateListener.of((u) => this.onUpdate(u)),
        EditorView.domEventHandlers({
          paste: (e, view) => this.onPaste(e, view),
          drop: (e, view) => this.onDrop(e, view),
        }),
      ],
    })
  }

  // Shows a note. `text`, `seq` and `pseq` come from the §1 `open` reply.
  // Edits carry the last applied `pseq` as `ack`, so the engine can transform
  // them over patches we had not applied yet (with the synchronous wasm
  // engine that never happens, but the protocol is the same everywhere).
  load(note, text, seq, pseq = 0) {
    this.note = note
    this.seq = seq
    this.ot.reset(pseq)
    this.view.setState(this.makeState(text))
  }

  unload() {
    this.note = null
    this.ot.reset()
    this.view.setState(this.makeState(''))
  }

  get text() {
    return this.view.state.doc.toString()
  }

  onUpdate(u) {
    if (!u.docChanged) return
    for (const tr of u.transactions) {
      if (!tr.docChanged || tr.annotation(remote) || !this.note) continue
      const changes = []
      tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) =>
        changes.push({ fromA, toA, inserted: inserted.toString() }))
      for (const e of sequentialEdits(changes)) {
        const seq = ++this.seq
        const reply = this.host.replica.call('edit', { note: this.note, seq, ack: this.ot.pseq, ...e })
        if (!reply.ok) {
          this.host.onError('edit failed: ' + reply.error)
          this.host.reload()
          return
        }
        this.ot.local(seq, e)
      }
    }
    this.host.onDocChanged(this.text)
  }

  // §1 `patch` event for the open note.
  applyPatch(ev) {
    if (ev.note !== this.note) return
    for (const p of this.ot.remote(ev)) {
      const len = this.view.state.doc.length
      const end = p.pos + (p.kind === 'del' ? p.len : 0)
      if (p.pos < 0 || end > len) {
        this.host.onError('patch out of range; reloading the note')
        this.host.reload()
        return
      }
      this.view.dispatch({
        changes: p.kind === 'ins' ? { from: p.pos, insert: p.text } : { from: p.pos, to: end },
        annotations: [remote.of(true), Transaction.addToHistory.of(false), Transaction.remote.of(true)],
      })
    }
    this.host.onDocChanged(this.text)
  }

  // Replaces the selection with text as a local edit (goes through onUpdate).
  // Block content (images, files, multi-line pastes) gets a line of its own.
  insert(text, block = false) {
    const { doc } = this.view.state
    const { from, to } = this.view.state.selection.main
    let ins = text
    if (block) {
      if (from > 0 && doc.sliceString(from - 1, from) !== '\n') ins = '\n' + ins
      // After a list item or quote, markdown would swallow the block as a
      // continuation line; a blank line keeps it a block of its own.
      const atLineStart = from === 0 || doc.sliceString(from - 1, from) === '\n'
      const prev = from === 0 ? '' : atLineStart ? doc.lineAt(from - 1).text : doc.lineAt(from).text
      if (/^\s*([-*+]|\d+[.)])\s|^\s*>/.test(prev)) ins = '\n' + ins
      if (to >= doc.length || doc.sliceString(to, to + 1) !== '\n') ins += '\n'
    }
    this.view.dispatch({ changes: { from, to, insert: ins }, selection: { anchor: from + ins.length }, scrollIntoView: true })
    this.view.focus()
  }

  // Applies a local edit given in source positions (e.g. a preview checkbox).
  edit({ pos, del, ins }) {
    this.view.dispatch({ changes: { from: pos, to: pos + del, insert: ins } })
  }

  async insertFiles(files) {
    const parts = []
    for (const f of files) {
      try {
        parts.push(await this.host.attach(f))
      } catch (e) {
        this.host.onError('attaching ' + (f.name || 'file') + ' failed: ' + e.message)
      }
    }
    if (parts.length) this.insert(parts.join('\n'), true)
  }

  onPaste(e, view) {
    const data = e.clipboardData
    if (!data || !this.note) return false
    const files = [...data.files]
    if (files.length) {
      e.preventDefault()
      this.insertFiles(files)
      return true
    }
    const html = data.getData('text/html')
    if (html && /<[a-z]/i.test(html)) {
      e.preventDefault()
      this.pasteHtml(html, data.getData('text/plain'))
      return true
    }
    return false // plain text: CodeMirror's default
  }

  async pasteHtml(html, plain) {
    let md = htmlToMarkdown(html)
    if (!md.trim()) md = plain || ''
    for (const ref of dataImageRefs(md)) {
      try {
        const blob = await (await fetch(ref.src)).blob()
        const link = await this.host.attach(new File([blob], ref.alt || 'image', { type: blob.type }))
        md = md.replace(ref.match, link)
      } catch {
        md = md.replace(ref.match, '')
      }
    }
    this.insert(md, md.includes('\n') || /^!\[/.test(md))
  }

  onDrop(e) {
    const files = [...(e.dataTransfer?.files || [])]
    if (!files.length || !this.note) return false
    e.preventDefault()
    this.view.dispatch({ selection: { anchor: this.view.posAtCoords({ x: e.clientX, y: e.clientY }) ?? this.view.state.selection.main.head } })
    this.insertFiles(files)
    return true
  }

  focus(atEnd = false) {
    if (atEnd) this.view.dispatch({ selection: { anchor: this.view.state.doc.length } })
    this.view.focus()
  }

  checklist() {
    toggleChecklist(this.view)
  }
}
