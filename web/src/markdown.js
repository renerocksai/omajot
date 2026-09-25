// A small markdown → HTML renderer for the note preview.
//
// Covers what notes use: headings, paragraphs (single newlines are line
// breaks, as in Apple Notes), emphasis, strong, strikethrough, inline code,
// fenced code, links, autolinks, images, nested lists, task lists, quotes,
// GFM tables, rules and inline #hashtags. Everything else is escaped text.
//
// Two omajot specifics:
// - `attachments/<sha256>.<ext>` image and link targets are mapped through
//   `resolveAttachment(name)` (the PWA serves them from `api/blobs/<name>`).
// - Task checkboxes carry `data-off`, the UTF-16 offset of the `[` in the
//   source, so a click can toggle the source text with one edit.

const ATTACHMENT = /^attachments\/([0-9a-f]{64}\.[a-z0-9]+)$/

export function attachmentName(src) {
  const m = ATTACHMENT.exec(src)
  return m ? m[1] : null
}

export function defaultResolve(name) {
  return 'api/blobs/' + name
}

export function escapeHtml(s) {
  return s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
}

function safeUrl(url, resolve) {
  const name = attachmentName(url)
  if (name) return resolve(name)
  const trimmed = url.trim()
  if (/^(https?:|mailto:|#|\/|\.{0,2}\/)/i.test(trimmed)) return trimmed
  if (/^data:image\/(png|jpe?g|gif|webp);base64,/i.test(trimmed)) return trimmed
  if (!/^[a-z][a-z0-9+.-]*:/i.test(trimmed)) return trimmed // relative
  return '#'
}

// ---------------------------------------------------------------- inline

const TAG = /(^|[\s(])#([\p{L}\p{N}_\-/]*[\p{L}_][\p{L}\p{N}_\-/]*)/gu

export function renderInline(text, opts = {}) {
  const resolve = opts.resolveAttachment || defaultResolve
  const slots = []
  const hold = (html) => '\u0000' + (slots.push(html) - 1) + '\u0000'

  let s = text
  // Backslash escapes.
  s = s.replace(/\\([\\`*_{}\[\]()#+\-.!~|<>])/g, (_, c) => hold(escapeHtml(c)))
  // Code spans.
  s = s.replace(/(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/g, (_, _t, code) =>
    hold('<code>' + escapeHtml(code.replace(/^ (.*) $/, '$1')) + '</code>'))
  // Images.
  s = s.replace(/!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"([^"]*)")?\s*\)/g, (_, alt, url, title) =>
    hold('<img src="' + escapeHtml(safeUrl(url, resolve)) + '" alt="' + escapeHtml(alt) + '"'
      + (title ? ' title="' + escapeHtml(title) + '"' : '') + ' loading="lazy">'))
  // Links (text is rendered recursively).
  s = s.replace(/\[([^\]]+)\]\(\s*<?([^)\s>]+)>?(?:\s+"([^"]*)")?\s*\)/g, (_, label, url, title) =>
    hold('<a href="' + escapeHtml(safeUrl(url, resolve)) + '"'
      + (title ? ' title="' + escapeHtml(title) + '"' : '')
      + ' target="_blank" rel="noopener">' + renderInline(label, opts) + '</a>'))
  // Autolinks and bare URLs.
  s = s.replace(/<(https?:\/\/[^>\s]+)>/g, (_, url) =>
    hold('<a href="' + escapeHtml(url) + '" target="_blank" rel="noopener">' + escapeHtml(url) + '</a>'))
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)]+[^\s<).,;:!?'"])/g, (_, pre, url) =>
    pre + hold('<a href="' + escapeHtml(url) + '" target="_blank" rel="noopener">' + escapeHtml(url) + '</a>'))

  s = escapeHtml(s)
  s = s.replace(/(\*\*|__)(?=\S)([\s\S]*?\S)\1/g, '<strong>$2</strong>')
  s = s.replace(/(^|[^\w*])\*(?=\S)([\s\S]*?\S)\*(?!\*)/g, '$1<em>$2</em>')
  s = s.replace(/(^|[^\w])_(?=\S)([\s\S]*?\S)_(?!\w)/g, '$1<em>$2</em>')
  s = s.replace(/~~(?=\S)([\s\S]*?\S)~~/g, '<del>$1</del>')
  s = s.replace(TAG, (_, pre, tag) => pre + '<span class="tag">#' + tag + '</span>')
  // Hard breaks inside a paragraph.
  s = s.replace(/\n/g, '<br>')

  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => slots[+i])
}

// ---------------------------------------------------------------- blocks

const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([\w+-]*)\s*$/
const HEADING = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/
const RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/
const QUOTE = /^ {0,3}> ?/
const ITEM = /^( *)([-*+]|\d{1,9}[.)])([ \t]+|$)/
const TABLE_SEP = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/

function indentOf(text) {
  return text.length - text.trimStart().length
}

function isBlank(line) {
  return line.text.trim() === ''
}

function startsBlock(lines, i) {
  const t = lines[i].text
  return FENCE.test(t) || HEADING.test(t) || RULE.test(t) || QUOTE.test(t) || ITEM.test(t)
    || (t.includes('|') && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1].text))
}

function splitRow(text) {
  let t = text.trim()
  if (t.startsWith('|')) t = t.slice(1)
  if (t.endsWith('|') && !t.endsWith('\\|')) t = t.slice(0, -1)
  return t.split(/(?<!\\)\|/).map(c => c.trim())
}

// lines: [{ text, off }] where off is the UTF-16 source offset of text[0].
function renderBlocks(lines, opts, tight = false) {
  let html = ''
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    const t = line.text
    if (isBlank(line)) { i++; continue }

    let m
    if ((m = FENCE.exec(t))) {
      const fence = m[1]
      const lang = m[2]
      const body = []
      i++
      while (i < lines.length && !(lines[i].text.trim().startsWith(fence[0].repeat(fence.length))
        && lines[i].text.trim().replace(new RegExp('^' + (fence[0] === '`' ? '`' : '~') + '+'), '') === '')) {
        body.push(lines[i].text)
        i++
      }
      i++ // closing fence (or end)
      html += '<pre><code' + (lang ? ' class="language-' + escapeHtml(lang) + '"' : '') + '>'
        + escapeHtml(body.join('\n')) + '</code></pre>'
      continue
    }
    if ((m = HEADING.exec(t))) {
      const level = m[1].length
      html += '<h' + level + '>' + renderInline(m[2] || '', opts) + '</h' + level + '>'
      i++
      continue
    }
    if (RULE.test(t) && !ITEM.test(t.replace(/^( *)[-*] (?=[^-*\s])/, ''))) {
      html += '<hr>'
      i++
      continue
    }
    if (QUOTE.test(t)) {
      const inner = []
      while (i < lines.length && !isBlank(lines[i]) && (QUOTE.test(lines[i].text) || inner.length)) {
        const q = QUOTE.exec(lines[i].text)
        if (q) inner.push({ text: lines[i].text.slice(q[0].length), off: lines[i].off + q[0].length })
        else if (startsBlock(lines, i)) break
        else inner.push(lines[i]) // lazy continuation
        i++
      }
      html += '<blockquote>' + renderBlocks(inner, opts) + '</blockquote>'
      continue
    }
    if (ITEM.test(t)) {
      const r = renderList(lines, i, opts)
      html += r.html
      i = r.next
      continue
    }
    if (t.includes('|') && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1].text)) {
      const head = splitRow(t)
      const aligns = splitRow(lines[i + 1].text).map(c =>
        c.startsWith(':') && c.endsWith(':') ? 'center' : c.endsWith(':') ? 'right' : c.startsWith(':') ? 'left' : '')
      const cell = (tag, c, k) => '<' + tag + (aligns[k] ? ' style="text-align:' + aligns[k] + '"' : '') + '>'
        + renderInline(c, opts) + '</' + tag + '>'
      html += '<table><thead><tr>' + head.map((c, k) => cell('th', c, k)).join('') + '</tr></thead><tbody>'
      i += 2
      while (i < lines.length && !isBlank(lines[i]) && lines[i].text.includes('|')) {
        const row = splitRow(lines[i].text)
        html += '<tr>' + head.map((_, k) => cell('td', row[k] || '', k)).join('') + '</tr>'
        i++
      }
      html += '</tbody></table>'
      continue
    }
    // Paragraph.
    const para = [t.trim()]
    i++
    while (i < lines.length && !isBlank(lines[i]) && !startsBlock(lines, i)) {
      para.push(lines[i].text.trim())
      i++
    }
    const inner = renderInline(para.join('\n'), opts)
    html += tight ? inner : '<p>' + inner + '</p>'
  }
  return html
}

function renderList(lines, start, opts) {
  const first = ITEM.exec(lines[start].text)
  const baseIndent = first[1].length
  const ordered = /\d/.test(first[2])
  const startNum = ordered ? parseInt(first[2], 10) : 1
  const items = []
  let loose = false
  let i = start
  let sawBlank = false

  while (i < lines.length) {
    const line = lines[i]
    if (isBlank(line)) { sawBlank = true; i++; continue }
    const m = ITEM.exec(line.text)
    const indent = indentOf(line.text)
    if (m && m[1].length <= baseIndent + 1 && m[1].length >= baseIndent - 1 && (/\d/.test(m[2]) === ordered)) {
      if (sawBlank && items.length) loose = true
      sawBlank = false
      const contentIndent = m[0].length
      const content = line.text.slice(contentIndent)
      items.push({ lines: [{ text: content, off: line.off + contentIndent }], contentIndent })
      i++
      continue
    }
    if (!items.length) break
    const item = items[items.length - 1]
    if (indent >= Math.min(item.contentIndent, baseIndent + 2)) {
      // Child content (nested list or continuation), de-indented.
      const cut = Math.min(indent, item.contentIndent)
      if (sawBlank) { item.lines.push({ text: '', off: line.off }); loose = true }
      sawBlank = false
      item.lines.push({ text: line.text.slice(cut), off: line.off + cut })
      i++
      continue
    }
    if (!sawBlank && !startsBlock(lines, i)) {
      item.lines.push(line) // lazy continuation
      i++
      continue
    }
    break
  }
  // Leave trailing blank lines for the caller.
  while (i > start && isBlank(lines[i - 1])) i--

  let html = ordered ? '<ol' + (startNum !== 1 ? ' start="' + startNum + '"' : '') + '>' : '<ul>'
  for (const item of items) {
    const head = item.lines[0]
    const task = /^\[([ xX])\](?=\s|$)/.exec(head.text)
    let body = item.lines
    let prefix = ''
    let cls = ''
    if (task) {
      const checked = task[1] !== ' '
      prefix = '<input type="checkbox" class="task" data-off="' + head.off + '"' + (checked ? ' checked' : '') + '> '
      cls = ' class="task-item' + (checked ? ' done' : '') + '"'
      const rest = head.text.slice(3).replace(/^\s/, '')
      body = [{ text: rest, off: head.off + (head.text.length - rest.length) }, ...item.lines.slice(1)]
    }
    html += '<li' + cls + '>' + prefix + renderBlocks(body, opts, !loose) + '</li>'
  }
  html += ordered ? '</ol>' : '</ul>'
  return { html, next: i }
}

export function renderMarkdown(src, opts = {}) {
  const lines = []
  let off = 0
  // Offsets must stay exact, so no CRLF normalisation here (a lone \r stays
  // in the text and renders as whitespace). Leading tabs count as 4 spaces;
  // `off` is shifted back by the expansion, so `off + k` is exact for any
  // index past the leading whitespace, which is where offsets are taken.
  for (const text of src.split('\n')) {
    const lead = /^[ \t]*/.exec(text)[0]
    const expanded = lead.replace(/\t/g, '    ')
    lines.push({ text: expanded + text.slice(lead.length), off: off - (expanded.length - lead.length) })
    off += text.length + 1
  }
  return renderBlocks(lines, opts)
}

// Toggles the task checkbox whose `[` is at `off`. Returns the edit
// { pos, del, ins } for the source, or null when there is no checkbox there.
export function toggleTaskEdit(src, off) {
  const box = src.slice(off, off + 3)
  if (box === '[ ]') return { pos: off + 1, del: 1, ins: 'x' }
  if (box === '[x]' || box === '[X]') return { pos: off + 1, del: 1, ins: ' ' }
  return null
}
