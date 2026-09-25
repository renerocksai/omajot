// Apple Notes touches inside the markdown source editor:
// - `- [ ]` / `- [x]` show as real checkboxes; a tap toggles the source
//   (an ordinary local edit, so it syncs and undoes like typing);
// - `![alt](attachments/<sha>.<ext>)` shows the picture itself.
// Both are atomic: the cursor steps over them and Backspace removes them whole.
import { EditorView, ViewPlugin, Decoration, WidgetType } from '@codemirror/view'
import { RangeSetBuilder } from '@codemirror/state'

const TASK = /^(\s*[-*+][ \t]+)\[([ xX])\](?=[ \t]|$)/
const IMAGE = /!\[([^\]\n]*)\]\((attachments\/([0-9a-f]{64}\.[a-z0-9]+))\)/g

class CheckboxWidget extends WidgetType {
  constructor(checked, pos) {
    super()
    this.checked = checked
    this.pos = pos
  }
  eq(other) { return other.checked === this.checked && other.pos === this.pos }
  toDOM(view) {
    const box = document.createElement('span')
    box.className = 'cm-task' + (this.checked ? ' done' : '')
    box.setAttribute('role', 'checkbox')
    box.setAttribute('aria-checked', String(this.checked))
    box.addEventListener('mousedown', (e) => {
      e.preventDefault()
      const pos = this.pos + 1
      view.dispatch({ changes: { from: pos, to: pos + 1, insert: this.checked ? ' ' : 'x' } })
    })
    return box
  }
  ignoreEvent() { return true }
}

class ImageWidget extends WidgetType {
  constructor(src, alt) {
    super()
    this.src = src
    this.alt = alt
  }
  eq(other) { return other.src === this.src && other.alt === this.alt }
  toDOM() {
    const img = document.createElement('img')
    img.className = 'cm-image'
    img.src = this.src
    img.alt = this.alt
    img.loading = 'lazy'
    return img
  }
  ignoreEvent() { return false }
}

export function noteWidgets(resolveAttachment) {
  const build = (view) => {
    const builder = new RangeSetBuilder()
    for (const { from, to } of view.visibleRanges) {
      for (let pos = from; pos <= to;) {
        const line = view.state.doc.lineAt(pos)
        const items = []
        const task = TASK.exec(line.text)
        if (task) {
          const at = line.from + task[1].length
          const checked = task[2] !== ' '
          if (checked) items.push([line.from, line.from, Decoration.line({ class: 'cm-task-done' })])
          items.push([at, at + 3, Decoration.replace({ widget: new CheckboxWidget(checked, at) })])
        }
        IMAGE.lastIndex = 0
        for (let m; (m = IMAGE.exec(line.text));) {
          const start = line.from + m.index
          items.push([start, start + m[0].length,
            Decoration.replace({ widget: new ImageWidget(resolveAttachment(m[3]), m[1]) })])
        }
        for (const [a, b, d] of items) builder.add(a, b, d)
        pos = line.to + 1
      }
    }
    return builder.finish()
  }

  const plugin = ViewPlugin.fromClass(class {
    constructor(view) { this.decorations = build(view) }
    update(u) { if (u.docChanged || u.viewportChanged) this.decorations = build(u.view) }
  }, { decorations: v => v.decorations })

  return [
    plugin,
    EditorView.atomicRanges.of(view => view.plugin(plugin)?.decorations || Decoration.none),
  ]
}
