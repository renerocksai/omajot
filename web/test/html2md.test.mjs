import { test } from 'node:test'
import assert from 'node:assert/strict'
import { htmlToMarkdown, dataImageRefs, decodeEntities } from '../src/html2md.js'

const NOISE = 'style="color: rgb(0, 0, 0); font-family: &quot;Times New Roman&quot;; font-style: normal; font-weight: 400;"'

test('Chromium select-all copy (from spikes/paste) converts cleanly', () => {
  const html = `<h1 ${NOISE}>Paste test</h1><p ${NOISE}>Some<span> </span><b>bold</b>,<span> </span><i>italic</i>,<span> </span><code>code</code><span> </span>and a<span> </span><a href="https://example.com/x">link</a>. Umlaut: Grüße 🎉</p>`
    + `<ul ${NOISE}><li>one<ul><li>nested</li></ul></li><li><input type="checkbox" checked=""><span> </span>done task</li><li><input type="checkbox"><span> </span>open task</li></ul>`
    + `<ol ${NOISE}><li>first</li><li>second</li></ol><blockquote ${NOISE}>A quote</blockquote>`
    + `<pre ${NOISE}><code>fn main() void {}</code></pre>`
    + `<table><tbody><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></tbody></table>`
    + `<p>Inline data image: <img src="data:image/png;base64,iVBORw0KGgo=" alt="dataimg"></p>`
  assert.equal(htmlToMarkdown(html), [
    '# Paste test',
    '',
    'Some **bold**, *italic*, `code` and a [link](https://example.com/x). Umlaut: Grüße 🎉',
    '',
    '- one\n  - nested\n- [x] done task\n- [ ] open task',
    '',
    '1. first\n2. second',
    '',
    '> A quote',
    '',
    '```\nfn main() void {}\n```',
    '',
    '| A | B |\n| --- | --- |\n| 1 | 2 |',
    '',
    'Inline data image: ![dataimg](data:image/png;base64,iVBORw0KGgo=)',
  ].join('\n'))
})

test('Chromium "Copy image" html', () => {
  assert.equal(htmlToMarkdown('<img src="https://e.com/a.png">'), '![](https://e.com/a.png)')
})

test('Google Docs style spans', () => {
  const html = '<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1"><p dir="ltr"><span style="font-weight:700;">Bold</span><span style="font-weight:400;"> and </span><span style="font-style:italic;">it</span></p></b>'
  assert.equal(htmlToMarkdown(html), '**Bold** and *it*')
})

test('whitespace, entities, br, escapes', () => {
  assert.equal(htmlToMarkdown('<p>a\n   b&nbsp;&amp;&lt;c&gt;<br>next *star*</p>'), 'a b &<c>\nnext \\*star\\*')
  assert.equal(decodeEntities('&#x1F389;&#228;&unknown;'), '🎉ä&unknown;')
})

test('unclosed tags, html wrapper, scripts and styles skipped', () => {
  const html = '<html><head><style>p{color:red}</style><title>x</title></head><body><p>one<p>two<script>alert(1)</script><ul><li>a<li>b</ul></body></html>'
  assert.equal(htmlToMarkdown(html), 'one\n\ntwo\n\n- a\n- b')
})

test('StartFragment markers', () => {
  assert.equal(htmlToMarkdown('<html><body>junk<!--StartFragment--><b>x</b><!--EndFragment--></body></html>'), '**x**')
})

test('dataImageRefs finds data: images', () => {
  const refs = dataImageRefs('a ![x](data:image/png;base64,AAAA) b ![y](https://e.com/y.png)')
  assert.deepEqual(refs.map(r => r.alt), ['x'])
})
