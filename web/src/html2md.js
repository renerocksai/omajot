// Pasted HTML → markdown. A tolerant tokenizer and tree builder, so it runs
// in node tests as well as the browser, and ignores the inline-style noise
// Chromium puts on every element (see spikes/paste/REPORT.md).
//
// Handles headings, paragraphs, line breaks, emphasis, strong, strikethrough,
// inline code, pre blocks, links, images, nested lists, checkbox inputs
// (→ task lists), quotes, tables and rules. Google Docs marks bold/italic with
// `style` on spans; that is honoured.

const VOID = new Set(['br', 'img', 'input', 'hr', 'meta', 'link', 'col', 'wbr', 'source', 'area', 'base'])
const SKIP = new Set(['script', 'style', 'head', 'title', 'template', 'noscript', 'svg', 'math'])
const BLOCK = new Set(['p', 'div', 'section', 'article', 'header', 'footer', 'main', 'aside', 'nav',
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'blockquote', 'pre', 'table', 'thead', 'tbody',
  'tfoot', 'tr', 'td', 'th', 'hr', 'figure', 'figcaption', 'dl', 'dt', 'dd', 'address', 'details', 'summary'])
// Opening one of these implicitly closes an open <p>.
const CLOSES_P = new Set([...BLOCK].filter(t => !['td', 'th', 'tr', 'li', 'thead', 'tbody', 'tfoot'].includes(t)))

const NAMED = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ndash: '–', mdash: '—',
  hellip: '…', laquo: '«', raquo: '»', lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”', bull: '•', middot: '·',
  copy: '©', reg: '®', trade: '™', euro: '€', auml: 'ä', ouml: 'ö', uuml: 'ü', Auml: 'Ä', Ouml: 'Ö', Uuml: 'Ü', szlig: 'ß' }

export function decodeEntities(s) {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+\d*);?/gi, (m, e) => {
    if (e[0] === '#') {
      const code = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)
      return code > 0 && code < 0x110000 ? String.fromCodePoint(code) : m
    }
    return Object.hasOwn(NAMED, e) ? NAMED[e] : m
  })
}

function parseAttrs(src) {
  const attrs = {}
  const re = /([^\s=\/>"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g
  let m
  while ((m = re.exec(src))) attrs[m[1].toLowerCase()] = decodeEntities(m[2] ?? m[3] ?? m[4] ?? '')
  return attrs
}

// Builds { tag, attrs, children } nodes; text nodes are { text }.
export function parseHtml(html) {
  const root = { tag: '#root', attrs: {}, children: [] }
  const stack = [root]
  const top = () => stack[stack.length - 1]
  const closeTo = (tag) => {
    for (let k = stack.length - 1; k > 0; k--) {
      if (stack[k].tag === tag) { stack.length = k; return true }
    }
    return false
  }
  const re = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<![^>]*>|<\/?([a-zA-Z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>|[^<]+|</g
  let m
  let skipping = null
  while ((m = re.exec(html))) {
    const tok = m[0]
    if (skipping) {
      if (tok.toLowerCase().startsWith('</' + skipping)) skipping = null
      continue
    }
    if (tok.startsWith('<!')) continue
    if (m[1]) {
      const tag = m[1].toLowerCase()
      if (tok[1] === '/') {
        if (tag === 'p' && !stack.some(n => n.tag === 'p')) continue
        closeTo(tag)
        continue
      }
      if (SKIP.has(tag)) {
        if (!tok.endsWith('/>')) skipping = tag
        continue
      }
      if (CLOSES_P.has(tag)) closeTo('p') // implicit </p>
      if (tag === 'li') {
        // A new <li> closes the previous one in the same list.
        for (let k = stack.length - 1; k > 0; k--) {
          if (stack[k].tag === 'ul' || stack[k].tag === 'ol') break
          if (stack[k].tag === 'li') { stack.length = k; break }
        }
      }
      if (tag === 'tr' || tag === 'td' || tag === 'th') {
        for (let k = stack.length - 1; k > 0; k--) {
          const t = stack[k].tag
          if (t === 'table') break
          if (t === tag || (tag !== 'tr' && (t === 'td' || t === 'th')) || (tag === 'tr' && (t === 'td' || t === 'th' || t === 'tr'))) {
            stack.length = k
            break
          }
        }
      }
      const node = { tag, attrs: parseAttrs(m[2] || ''), children: [] }
      top().children.push(node)
      if (!VOID.has(tag) && !tok.endsWith('/>')) stack.push(node)
      continue
    }
    top().children.push({ text: decodeEntities(tok) })
  }
  return root
}

// ---------------------------------------------------------------- converter

function styleFlags(node) {
  const style = (node.attrs.style || '').toLowerCase()
  const weight = /font-weight\s*:\s*(bold|[6-9]00)/.test(style)
  const normal = /font-weight\s*:\s*(normal|[1-4]00)/.test(style)
  const italic = /font-style\s*:\s*italic/.test(style)
  const strike = /text-decoration[^;]*line-through/.test(style)
  return { weight, normal, italic, strike }
}

function escapeText(s) {
  return s.replace(/([\\`*_\[\]])/g, '\\$1')
}

function inlineOf(node, ctx) {
  if (node.text !== undefined) {
    if (ctx.pre) return node.text
    return escapeText(node.text.replace(/[\s ]+/g, m => (m.includes(' ') && !/[\t\n\r ]/.test(m) ? ' ' : ' ')))
  }
  const kids = () => node.children.map(c => inlineOf(c, ctx)).join('')
  const wrap = (mark, inner) => {
    const m = /^(\s*)([\s\S]*?)(\s*)$/.exec(inner)
    return m[2] ? m[1] + mark + m[2] + mark + m[3] : inner
  }
  switch (node.tag) {
    case 'br': return '\n'
    case 'img': {
      const src = node.attrs.src || ''
      return src ? `![${escapeText(node.attrs.alt || '')}](${src.replace(/\s/g, '%20')})` : ''
    }
    case 'input':
      return node.attrs.type === 'checkbox' ? ('checked' in node.attrs ? '[x] ' : '[ ] ') : ''
    case 'a': {
      const inner = kids()
      const href = node.attrs.href || ''
      if (!href || href.startsWith('javascript:')) return inner
      if (!inner.trim()) return ''
      return `[${inner.trim()}](${href.replace(/\s/g, '%20')})`
    }
    case 'code': case 'kbd': case 'samp': case 'tt': {
      if (ctx.pre) return kids()
      const raw = textOf(node)
      const ticks = raw.includes('`') ? '``' : '`'
      return raw ? ticks + (ticks.length > 1 ? ' ' + raw + ' ' : raw) + ticks : ''
    }
    case 'b': case 'strong': {
      const f = styleFlags(node)
      return f.normal ? kids() : wrap('**', kids())
    }
    case 'i': case 'em': case 'cite': case 'var': return wrap('*', kids())
    case 's': case 'del': case 'strike': return wrap('~~', kids())
    case 'span': case 'font': case 'mark': case 'u': case 'sup': case 'sub': case 'small': case 'big': case 'abbr': case 'label': case 'time': {
      const f = styleFlags(node)
      let inner = kids()
      if (f.strike) inner = wrap('~~', inner)
      if (f.italic) inner = wrap('*', inner)
      if (f.weight) inner = wrap('**', inner)
      return inner
    }
    default:
      return kids()
  }
}

function textOf(node) {
  if (node.text !== undefined) return node.text
  return node.children.map(textOf).join('')
}

function isBlockNode(n) {
  return n.tag !== undefined && BLOCK.has(n.tag)
}

// Renders a node's children as blocks; inline runs become paragraphs.
function blocksOf(node, ctx) {
  const out = []
  let run = []
  const flush = () => {
    if (!run.length) return
    const text = run.map(c => inlineOf(c, ctx)).join('')
      .split('\n').map(l => l.replace(/^ +| +$/g, '')).join('\n').replace(/^\n+|\n+$/g, '')
    if (text.trim()) out.push(text)
    run = []
  }
  for (const child of node.children) {
    if (isBlockNode(child)) {
      flush()
      const b = blockOf(child, ctx)
      if (b !== null && b.trim() !== '') out.push(b)
    } else {
      run.push(child)
    }
  }
  flush()
  return out
}

function blockOf(node, ctx) {
  switch (node.tag) {
    case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': {
      const text = node.children.map(c => inlineOf(c, ctx)).join('').replace(/\s+/g, ' ').trim()
        .replace(/^\*\*([\s\S]*)\*\*$/, '$1')
      return text ? '#'.repeat(+node.tag[1]) + ' ' + text : ''
    }
    case 'hr': return '---'
    case 'pre': {
      const code = textOf(node).replace(/\n$/, '')
      const fence = code.includes('```') ? '~~~' : '```'
      const cls = node.children.find(c => c.tag === 'code')?.attrs.class || node.attrs.class || ''
      const lang = /language-([\w+-]+)/.exec(cls)?.[1] || ''
      return fence + lang + '\n' + code + '\n' + fence
    }
    case 'blockquote':
      return blocksOf(node, ctx).join('\n\n').split('\n').map(l => (l ? '> ' + l : '>')).join('\n')
    case 'ul': case 'ol': return listOf(node, ctx)
    case 'table': return tableOf(node, ctx)
    case 'li': return listOf({ tag: 'ul', attrs: {}, children: [node] }, ctx)
    default:
      return blocksOf(node, ctx).join('\n\n')
  }
}

function listOf(node, ctx) {
  const ordered = node.tag === 'ol'
  let n = parseInt(node.attrs.start || '1', 10) || 1
  const items = []
  for (const li of node.children) {
    if (li.tag !== 'li') {
      if (li.tag === 'ul' || li.tag === 'ol') items.push(indent(listOf(li, ctx), ordered ? '   ' : '  '))
      continue
    }
    const marker = ordered ? `${n++}. ` : '- '
    const blocks = blocksOf(li, ctx)
    let body = blocks.join('\n').replace(/^\s+/, '')
    // A checkbox rendered first becomes a task marker.
    body = body.replace(/^\\?\[([ x])\\?\]\s*/, (_, c) => `[${c}] `)
    const pad = ' '.repeat(marker.length)
    items.push(marker + body.split('\n').map((l, i) => (i === 0 || !l ? l : pad + l)).join('\n'))
  }
  return items.join('\n')
}

function indent(text, pad) {
  return text.split('\n').map(l => (l ? pad + l : l)).join('\n')
}

function tableOf(node, ctx) {
  const rows = []
  const walk = (n) => {
    for (const c of n.children || []) {
      if (c.tag === 'tr') rows.push(c)
      else if (c.tag && c.tag !== 'table') walk(c)
    }
  }
  walk(node)
  if (!rows.length) return ''
  const cells = rows.map(r => r.children.filter(c => c.tag === 'td' || c.tag === 'th')
    .map(c => blocksOf(c, ctx).join(' ').replace(/\n+/g, ' ').replace(/\|/g, '\\|').trim()))
  const width = Math.max(...cells.map(r => r.length))
  if (width === 0) return ''
  const line = (r) => '| ' + Array.from({ length: width }, (_, k) => r[k] || '').join(' | ') + ' |'
  return [line(cells[0]), '|' + ' --- |'.repeat(width), ...cells.slice(1).map(line)].join('\n')
}

export function htmlToMarkdown(html) {
  // Clipboard HTML from Windows apps wraps the fragment in markers.
  const frag = /<!--StartFragment-->([\s\S]*?)<!--EndFragment-->/.exec(html)
  const root = parseHtml(frag ? frag[1] : html)
  const body = findBody(root)
  return blocksOf(body, { pre: false }).join('\n\n').replace(/\n{3,}/g, '\n\n').trim()
}

function findBody(node) {
  if (node.tag === 'body') return node
  for (const c of node.children || []) {
    const b = c.tag ? findBody(c) : null
    if (b) return b
  }
  return node.tag === '#root' ? node : null
}

// Image references in converted markdown that the app should turn into
// attachments: data: URIs (decoded and uploaded). Returns [{ match, src }].
export function dataImageRefs(md) {
  const refs = []
  const re = /!\[([^\]]*)\]\((data:image\/[a-z+.-]+;base64,[A-Za-z0-9+/=]+)\)/g
  let m
  while ((m = re.exec(md))) refs.push({ match: m[0], alt: m[1], src: m[2] })
  return refs
}
