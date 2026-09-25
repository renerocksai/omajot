import { test } from 'node:test'
import assert from 'node:assert/strict'
import { renderMarkdown, renderInline, attachmentName, toggleTaskEdit } from '../src/markdown.js'

const SHA = 'a'.repeat(64)

test('headings, emphasis, code, links', () => {
  assert.equal(renderMarkdown('# Title'), '<h1>Title</h1>')
  assert.equal(renderInline('**b** *i* _j_ ~~s~~ `c*d`'), '<strong>b</strong> <em>i</em> <em>j</em> <del>s</del> <code>c*d</code>')
  assert.match(renderInline('[x](https://e.com)'), /<a href="https:\/\/e.com" target="_blank" rel="noopener">x<\/a>/)
  assert.match(renderInline('see https://e.com/a.'), /href="https:\/\/e.com\/a"/)
})

test('escapes html and rejects javascript urls', () => {
  assert.equal(renderInline('<script>'), '&lt;script&gt;')
  assert.match(renderInline('[x](javascript:alert(1))'), /href="#"/)
})

test('attachments map to blob urls, in images and links', () => {
  assert.equal(attachmentName(`attachments/${SHA}.png`), `${SHA}.png`)
  assert.equal(attachmentName('attachments/nope.png'), null)
  const html = renderMarkdown(`![shot](attachments/${SHA}.png)`)
  assert.match(html, new RegExp(`<img src="api/blobs/${SHA}.png" alt="shot"`))
  const custom = renderMarkdown(`[pdf](attachments/${SHA}.pdf)`, { resolveAttachment: n => 'blob:x/' + n })
  assert.match(custom, new RegExp(`href="blob:x/${SHA}.pdf"`))
})

test('single newlines are line breaks, blank lines split paragraphs', () => {
  assert.equal(renderMarkdown('a\nb\n\nc'), '<p>a<br>b</p><p>c</p>')
})

test('hashtags render, headings and code do not', () => {
  assert.equal(renderInline('hi #work and #äpfel'), 'hi <span class="tag">#work</span> and <span class="tag">#äpfel</span>')
  assert.equal(renderInline('no#tag #123'), 'no#tag #123')
  assert.equal(renderInline('`#code`'), '<code>#code</code>')
  assert.equal(renderMarkdown('## Heading'), '<h2>Heading</h2>')
})

test('nested lists and ordered lists', () => {
  const html = renderMarkdown('- one\n  - nested\n- two\n\n1. a\n2. b')
  assert.equal(html, '<ul><li>one<ul><li>nested</li></ul></li><li>two</li></ul><ol><li>a</li><li>b</li></ol>')
})

test('task list checkboxes carry the source offset of [', () => {
  const src = '# T\n\n- [ ] open\n- [x] done\n  - [ ] child'
  const html = renderMarkdown(src)
  const offs = [...html.matchAll(/data-off="(\d+)"/g)].map(m => +m[1])
  assert.equal(offs.length, 3)
  for (const off of offs) assert.match(src.slice(off, off + 3), /^\[[ x]\]$/)
  assert.match(html, /<li class="task-item done"><input type="checkbox" class="task" data-off="\d+" checked> done/)
})

test('task offsets survive tabs, quotes and emoji before them', () => {
  const src = '🎉 intro\n\n> - [ ] quoted\n\n-\t[ ] tabbed\n\t- [x] tab nested'
  const offs = [...renderMarkdown(src).matchAll(/data-off="(\d+)"/g)].map(m => +m[1])
  assert.equal(offs.length, 3)
  for (const off of offs) assert.match(src.slice(off, off + 3), /^\[[ x]\]$/, `offset ${off}`)
})

test('toggleTaskEdit', () => {
  const src = '- [ ] a\n- [x] b'
  assert.deepEqual(toggleTaskEdit(src, 2), { pos: 3, del: 1, ins: 'x' })
  assert.deepEqual(toggleTaskEdit(src, 10), { pos: 11, del: 1, ins: ' ' })
  assert.equal(toggleTaskEdit(src, 0), null)
})

test('fenced code, quotes, rules, tables', () => {
  assert.equal(renderMarkdown('```zig\nconst a = 1 < 2;\n```'), '<pre><code class="language-zig">const a = 1 &lt; 2;</code></pre>')
  assert.equal(renderMarkdown('> quoted\n> more'), '<blockquote><p>quoted<br>more</p></blockquote>')
  assert.equal(renderMarkdown('a\n\n---\n\nb'), '<p>a</p><hr><p>b</p>')
  const table = renderMarkdown('| A | B |\n| :- | -: |\n| 1 | **2** |')
  assert.equal(table, '<table><thead><tr><th style="text-align:left">A</th><th style="text-align:right">B</th></tr></thead>'
    + '<tbody><tr><td style="text-align:left">1</td><td style="text-align:right"><strong>2</strong></td></tr></tbody></table>')
})

test('title option: only the first line is the title', () => {
  const opts = { title: true }
  assert.equal(renderMarkdown('Shopping list\nmilk #groceries', opts),
    '<p class="title">Shopping list</p><p>milk <span class="tag">#groceries</span></p>')
  assert.equal(renderMarkdown('Title only', opts), '<p class="title">Title only</p>')
  assert.equal(renderMarkdown('\n\nAfter blanks\nbody', opts), '<p class="title">After blanks</p><p>body</p>')
  assert.equal(renderMarkdown('# Heading title\nbody', opts), '<h1>Heading title</h1><p>body</p>')
  // Only the note's own first block, never a later paragraph or one inside a list.
  assert.equal(renderMarkdown('- item\n\npara\nmore', opts), '<ul><li>item</li></ul><p>para<br>more</p>')
  // Without the option nothing changes.
  assert.equal(renderMarkdown('a\nb'), '<p>a<br>b</p>')
})

test('an ATX heading is one line; the next line is a paragraph', () => {
  assert.equal(renderMarkdown('# Shopping list\nmilk #groceries'), '<h1>Shopping list</h1><p>milk <span class="tag">#groceries</span></p>')
  assert.equal(renderMarkdown('## H\n- item'), '<h2>H</h2><ul><li>item</li></ul>')
  assert.equal(renderMarkdown('# H #\ntext'), '<h1>H</h1><p>text</p>')
})

test('setext headings', () => {
  assert.equal(renderMarkdown('Title\n===\nnext'), '<h1>Title</h1><p>next</p>')
  assert.equal(renderMarkdown('Sub\n---\n\n---'), '<h2>Sub</h2><hr>')
  assert.equal(renderMarkdown('two\nlines\n=='), '<h1>two<br>lines</h1>')
  // --- after a list item is a rule, not a setext underline.
  assert.equal(renderMarkdown('- a\n---'), '<ul><li>a</li></ul><hr>')
})

test('blocks end cleanly before following text', () => {
  assert.equal(renderMarkdown('```\ncode\n```\ntext'), '<pre><code>code</code></pre><p>text</p>')
  assert.equal(renderMarkdown('> q\n\ntext'), '<blockquote><p>q</p></blockquote><p>text</p>')
  assert.equal(renderMarkdown('- a\n\ntext'), '<ul><li>a</li></ul><p>text</p>')
  assert.equal(renderMarkdown('| A |\n| - |\n| 1 |\n\ntext'),
    '<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table><p>text</p>')
})

test('hard breaks, escapes and link targets with parentheses', () => {
  assert.equal(renderMarkdown('a\\\nb'), '<p>a<br>b</p>')
  assert.equal(renderMarkdown('a  \nb'), '<p>a<br>b</p>')
  assert.equal(renderInline('\\*not em\\* \\# \\[x\\]'), '*not em* # [x]')
  assert.match(renderInline('[Zig](https://en.wikipedia.org/wiki/Zig_(language))'),
    /href="https:\/\/en.wikipedia.org\/wiki\/Zig_\(language\)"[^>]*>Zig<\/a>$/)
  assert.match(renderInline('![i](pic(1).png "t")'), /<img src="pic\(1\).png" alt="i" title="t"/)
  assert.equal(renderInline('snake_case_name'), 'snake_case_name')
  assert.equal(renderInline('`a ``b`` c`'), '<code>a ``b`` c</code>')
})

test('ordered list start, nested tasks, loose lists', () => {
  assert.equal(renderMarkdown('3. c\n4. d'), '<ol start="3"><li>c</li><li>d</li></ol>')
  assert.equal(renderMarkdown('- a\n\n- b'), '<ul><li><p>a</p></li><li><p>b</p></li></ul>')
  assert.match(renderMarkdown('- [ ] top\n  - [x] sub'), /<li class="task-item">.*top<ul><li class="task-item done">.*sub<\/li><\/ul><\/li>/)
})
