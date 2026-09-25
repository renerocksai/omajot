import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import * as M from "../Model.mjs"

// --- settings ---------------------------------------------------------------

test("hub url falls back to the default for anything that is not http(s)", () => {
  assert.equal(M.normalizeHubUrl(""), M.DEFAULT_HUB_URL)
  assert.equal(M.normalizeHubUrl("ftp://x"), M.DEFAULT_HUB_URL)
  assert.equal(M.normalizeHubUrl("https://user@evil.example"), M.DEFAULT_HUB_URL)
  assert.equal(M.normalizeHubUrl(" https://h.ts.net:8443/ "), "https://h.ts.net:8443")
})

test("data directory honours the setting, then XDG, then ~/.local/share", () => {
  assert.equal(M.dataDirectory("", "/home/u", ""), "/home/u/.local/share/omajot")
  assert.equal(M.dataDirectory("", "/home/u", "/xdg"), "/xdg/omajot")
  assert.equal(M.dataDirectory("~/notes/", "/home/u", "/xdg"), "/home/u/notes")
  assert.equal(M.dataDirectory("relative", "/home/u", ""), "/home/u/.local/share/omajot")
  assert.equal(M.directoryUrl("/a b/c"), "file:///a%20b/c/")
})

test("daemon argv carries hub and data dir", () => {
  // An invalid setting means no --hub (the daemon's config decides), never someone else's hub.
  assert.deepEqual(M.daemonArgv("/p/omajot", "x", "/d"), ["/p/omajot", "daemon", "--data", "/d"])
  // Empty: the daemon reads ~/.config/omajot/config.json instead.
  assert.deepEqual(M.daemonArgv("/p/omajot", "", "/d"), ["/p/omajot", "daemon", "--data", "/d"])
  assert.deepEqual(M.daemonArgv("/p/omajot", "  ", "/d"), ["/p/omajot", "daemon", "--data", "/d"])
  assert.deepEqual(M.daemonArgv("/p/omajot", "https://h.ts.net:8443", "/d"),
    ["/p/omajot", "daemon", "--hub", "https://h.ts.net:8443", "--data", "/d"])
})

test("restart delay backs off and caps", () => {
  assert.equal(M.restartDelay(0), 500)
  assert.equal(M.restartDelay(99), 30000)
})

test("parseLine ignores noise", () => {
  assert.equal(M.parseLine("log: hi"), null)
  assert.equal(M.parseLine("{bad"), null)
  assert.equal(M.parseLine("[1]"), null)
  assert.deepEqual(M.parseLine('{"re":1,"ok":true}'), { re: 1, ok: true })
  assert.equal(M.requestLine(3, "open", { note: "n-1", id: 9 }), '{"id":3,"cmd":"open","note":"n-1"}\n')
})

// --- diffs ------------------------------------------------------------------

test("diffText finds the single change and never splits surrogates", () => {
  assert.equal(M.diffText("abc", "abc"), null)
  assert.deepEqual(M.diffText("abc", "abXc"), { pos: 2, del: 0, ins: "X" })
  assert.deepEqual(M.diffText("abc", "ac"), { pos: 1, del: 1, ins: "" })
  // 🎉 is 🎉; replacing it with 🎊 (🎊) shares the high half.
  assert.deepEqual(M.diffText("a🎉b", "a🎊b"), { pos: 1, del: 2, ins: "🎊" })
  // The caret resolves an ambiguous run towards where the user typed.
  assert.deepEqual(M.diffText("aa", "aaa", 1), { pos: 0, del: 0, ins: "a" })
  assert.deepEqual(M.diffText("aa", "aaa"), { pos: 2, del: 0, ins: "a" })
})

// --- transform (mirrors src/core/ot.zig) ------------------------------------

function rng(seed) {
  let s = seed >>> 0
  return function () {
    s = (s * 1664525 + 1013904223) >>> 0
    return s / 4294967296
  }
}

test("concurrent inserts at one position: the winner goes first on both sides", () => {
  const p = M.insPrim(1, "P", 0)
  const l = M.insPrim(1, "L", 0)
  const r = M.xformPrim(p, l, true)
  let server = M.applyPrim("ab", p)
  for (const x of r.b) server = M.applyPrim(server, x)
  let client = M.applyPrim("ab", l)
  for (const x of r.a) client = M.applyPrim(client, x)
  assert.equal(server, "aPLb")
  assert.equal(client, server)
})

test("insert inside a concurrent delete survives and splits the delete", () => {
  const r = M.xformPrim(M.insPrim(3, "X", 0), M.delPrim(1, 4, 7), false)
  assert.equal(r.a[0].pos, 1)
  assert.equal(r.b.length, 2)
  assert.equal(r.b[1].tag, 7)
})

// The ot.zig property test, with the client side running through the real
// document model: a server making patches and a client typing, with random
// in-flight delays both ways, must end with identical text.
function randomPrimFor(rand, len, tag) {
  const alphabet = ["x", "y", "ü", "🎉"]
  if (len > 0 && rand() < 0.5) {
    const pos = Math.floor(rand() * len)
    const n = 1 + Math.floor(rand() * Math.min(len - pos, 4))
    return M.delPrim(pos, n, tag)
  }
  return M.insPrim(Math.floor(rand() * (len + 1)), alphabet[Math.floor(rand() * 4)], tag)
}

function splitsSurrogate(text, pos) {
  const c = text.charCodeAt(pos)
  return pos > 0 && pos < text.length && c >= 0xdc00 && c <= 0xdfff
}

test("jupiter convergence under random delays, client through docApplyPatch", () => {
  for (let seed = 1; seed <= 400; seed++) {
    const rand = rng(seed)
    let server = "hello"
    const doc = M.newDoc("n", "hello", 0, 0)
    let lastSeq = 0
    let pseq = 0
    let unacked = []
    const toClient = []
    const toServer = []
    for (let step = 0; step < 60 || toClient.length > 0 || toServer.length > 0; step++) {
      const choice = step < 60 ? Math.floor(rand() * 4) : 2 + Math.floor(rand() * 2)
      if (choice === 0) {
        pseq += 1
        const p = randomPrimFor(rand, server.length, pseq)
        server = M.applyPrim(server, p)
        unacked.push(p)
        toClient.push({ note: "n", base: lastSeq, pseq: pseq, pos: p.pos,
          del: p.kind === "del" ? p.len : 0, ins: p.kind === "ins" ? p.text : "" })
      } else if (choice === 1) {
        const e = randomPrimFor(rand, doc.text.length, 0)
        const edit = e.kind === "ins" ? { pos: e.pos, del: 0, ins: e.text } : { pos: e.pos, del: e.len, ins: "" }
        const out = M.docApplyLocal(doc, edit, 1000 + step)
        toServer.push(out)
      } else if (choice === 2 && toServer.length > 0) {
        const m = toServer.shift()
        const keep = unacked.filter(p => p.tag > m.ack)
        const r = M.xform(M.primsFromEdit(m.pos, m.del, m.ins, m.seq), keep, false)
        unacked = r.b
        for (const p of r.a) server = M.applyPrim(server, p)
        lastSeq = m.seq
      } else if (choice === 3 && toClient.length > 0) {
        const result = M.docApplyPatch(doc, toClient.shift(), step)
        assert.equal(result.resync, false, "seed " + seed)
      }
    }
    assert.equal(doc.text, server, "seed " + seed)
  }
})

test("patch pieces reproduce the document text in a view", () => {
  const rand = rng(99)
  for (let round = 0; round < 500; round++) {
    const doc = M.newDoc("n", "The quick brown fox", 0, 0)
    let view = doc.text
    for (let i = 0; i < 3; i++) {
      const e = randomPrimFor(rand, doc.text.length, 0)
      const edit = e.kind === "ins" ? { pos: e.pos, del: 0, ins: e.text } : { pos: e.pos, del: e.len, ins: "" }
      M.docApplyLocal(doc, edit, 0)
      view = M.applyEdit(view, edit)
    }
    const p = randomPrimFor(rand, 19, 1)
    const result = M.docApplyPatch(doc, { base: 0, pseq: 1, pos: p.pos,
      del: p.kind === "del" ? p.len : 0, ins: p.kind === "ins" ? p.text : "" })
    for (const piece of result.pieces) view = M.applyEdit(view, piece)
    assert.equal(view, doc.text, "round " + round)
  }
})

test("mapThroughPrim", () => {
  assert.equal(M.mapThroughPrim(3, M.insPrim(3, "ab"), false), 3)
  assert.equal(M.mapThroughPrim(3, M.insPrim(3, "ab"), true), 5)
  assert.equal(M.mapThroughPrim(4, M.delPrim(2, 4), false), 2)
  assert.equal(M.mapThroughPrim(7, M.delPrim(2, 4), false), 3)
})

// --- documents --------------------------------------------------------------

test("doc: typing produces numbered edits carrying ack", () => {
  const doc = M.newDoc("n-1", "hi", 4, 2)
  const e = M.docLocalEdit(doc, "hi!", 1000, 3)
  assert.deepEqual(e, { seq: 5, ack: 2, pos: 2, del: 0, ins: "!" })
  assert.equal(doc.text, "hi!")
  assert.equal(doc.pending.length, 1)
  M.docAck(doc, 5)
  assert.equal(doc.pending.length, 0)
})

test("doc: a patch computed before our edits is transformed over them", () => {
  const doc = M.newDoc("n-1", "hello", 0, 0)
  M.docLocalEdit(doc, "hello world", 1000, 11)     // seq 1, not yet seen by the engine
  const result = M.docApplyPatch(doc, { note: "n-1", base: 0, pseq: 1, pos: 0, del: 0, ins: ">> " })
  assert.equal(result.resync, false)
  assert.equal(doc.text, ">> hello world")
  assert.deepEqual(result.pieces, [{ pos: 0, del: 0, ins: ">> " }])
  assert.equal(doc.ack, 1)
  assert.equal(M.docLocalEdit(doc, ">> hello world!", 1100).ack, 1)
  // A later patch that includes our edits (base 2) applies unchanged.
  const r2 = M.docApplyPatch(doc, { note: "n-1", base: 2, pseq: 2, pos: 0, del: 3, ins: "" })
  assert.equal(doc.text, "hello world!")
  assert.equal(r2.pieces[0].pos, 0)
})

test("doc: remote wins a tie at the same position", () => {
  const doc = M.newDoc("n-1", "ab", 0, 0)
  M.docApplyLocal(doc, { pos: 1, del: 0, ins: "L" }, 0)
  M.docApplyPatch(doc, { base: 0, pseq: 1, pos: 1, del: 0, ins: "P" })
  assert.equal(doc.text, "aPLb")
})

test("doc: a patch that cannot fit asks for a resync", () => {
  const doc = M.newDoc("n-1", "abc", 0, 0)
  assert.equal(M.docApplyPatch(doc, { base: 0, pseq: 1, pos: 2, del: 5, ins: "" }).resync, true)
})

test("doc: undo reverts only local steps, never remote text", () => {
  const doc = M.newDoc("n-1", "", 0, 0)
  let t = 1000
  for (const ch of "one two") M.docLocalEdit(doc, doc.text + ch, t += 50)
  M.docApplyPatch(doc, { base: 7, pseq: 1, pos: 0, del: 0, ins: "REMOTE " }, t)
  assert.equal(doc.text, "REMOTE one two")
  const u1 = M.docUndo(doc)
  assert.equal(doc.text, "REMOTE one ")
  assert.equal(u1.caret, 11)
  M.docUndo(doc)
  assert.equal(doc.text, "REMOTE ")
  assert.equal(M.docUndo(doc), null)          // nothing local left; remote stays
  assert.equal(doc.text, "REMOTE ")
  M.docRedo(doc)
  assert.equal(doc.text, "REMOTE one ")
})

test("doc: an undo step touched by a remote edit is skipped", () => {
  const doc = M.newDoc("n-1", "", 0, 0)
  M.docLocalEdit(doc, "abc", 1000)
  M.docApplyPatch(doc, { base: 1, pseq: 1, pos: 1, del: 1, ins: "" }, 1100)
  assert.equal(doc.text, "ac")
  assert.equal(M.docUndo(doc), null)
})

// --- editing helpers --------------------------------------------------------

test("continueList continues bullets, numbers and checkboxes", () => {
  assert.deepEqual(M.continueList("- a", 3), { edit: { pos: 3, del: 0, ins: "\n- " }, caret: 6 })
  assert.deepEqual(M.continueList("  3. x", 6), { edit: { pos: 6, del: 0, ins: "\n  4. " }, caret: 12 })
  assert.deepEqual(M.continueList("- [x] done", 10).edit.ins, "\n- [ ] ")
  // Empty item ends the list.
  assert.deepEqual(M.continueList("a\n- ", 4), { edit: { pos: 2, del: 2, ins: "" }, caret: 2 })
  assert.equal(M.continueList("plain", 5), null)
  assert.equal(M.continueList("- item", 1), null)
})

test("toggleTaskAtLine flips one checkbox", () => {
  const text = "# T\n- [ ] a\n- [x] b"
  assert.deepEqual(M.toggleTaskAtLine(text, 1), { pos: 7, del: 1, ins: "x" })
  assert.deepEqual(M.toggleTaskAtLine(text, 2), { pos: 15, del: 1, ins: " " })
  assert.equal(M.toggleTaskAtLine(text, 0), null)
  assert.equal(M.toggleTaskAtLine(text, 9), null)
})

test("wrapSelection wraps and unwraps", () => {
  assert.deepEqual(M.wrapSelection("a word b", 2, 6, "**"),
    { edit: { pos: 2, del: 4, ins: "**word**" }, selStart: 4, selEnd: 8 })
  assert.deepEqual(M.wrapSelection("a **word** b", 4, 8, "**"),
    { edit: { pos: 2, del: 8, ins: "word" }, selStart: 2, selEnd: 6 })
  assert.deepEqual(M.wrapSelection("ab", 1, 1, "*").edit, { pos: 1, del: 0, ins: "**" })
})

test("extractTags follows the Apple Notes rules", () => {
  const text = "# Heading\n## Sub\n#Work and #home/garden, no#tag\n`#code` #Grüße #123\n```\n#fenced\n```\n#🎉 #end-"
  assert.deepEqual(M.extractTags(text), ["end", "grüße", "home/garden", "work"])
})

test("tag prefix and completions", () => {
  assert.equal(M.tagPrefixAt("see #pro", 8), "pro")
  assert.equal(M.tagPrefixAt("see pro", 7), null)
  assert.equal(M.tagPrefixAt("#", 1), "")
  assert.deepEqual(M.tagCompletions("pr", [{ tag: "project" }, { tag: "private" }, { tag: "home" }]), ["project", "private"])
  assert.deepEqual(M.tagCompletions(null, [{ tag: "a" }]), [])
})

// --- index ------------------------------------------------------------------

const notes = [
  { id: "n-1", title: "Alpha", snippet: "first", folder: "f-a", tags: ["x"], pinned: false, trashed: false, updated: 10 },
  { id: "n-2", title: "Beta", snippet: "second body", folder: "f-b", tags: ["x", "y"], pinned: true, trashed: false, updated: 5 },
  { id: "n-3", title: "", snippet: "", folder: null, tags: [], pinned: false, trashed: false, updated: 20 },
  { id: "n-4", title: "Gone", snippet: "", folder: "f-a", tags: ["y"], pinned: false, trashed: true, updated: 30 }
]
const folders = [
  { id: "f-a", name: "Work", parent: null },
  { id: "f-b", name: "Projects", parent: "f-a" },
  { id: "f-c", name: "Loop1", parent: "f-d" },
  { id: "f-d", name: "Loop2", parent: "f-c" }
]

test("sorting, titles and upserts", () => {
  assert.deepEqual(M.sortNotes(notes).map(n => n.id), ["n-2", "n-4", "n-3", "n-1"])
  assert.equal(M.noteTitle(notes[2]), "New note")
  const up = M.upsertNotes(notes, [{ id: "n-3", title: "Now named" }, { id: "n-9", title: "New" }])
  assert.equal(up.length, 5)
  assert.equal(up[2].title, "Now named")
})

test("folder tree nests, counts subtrees, and breaks cycles", () => {
  const tree = M.folderTree(folders, notes)
  assert.deepEqual(tree.map(f => [f.name, f.depth, f.count, f.total]),
    [["Loop1", 0, 0, 0], ["Loop2", 0, 0, 0], ["Work", 0, 1, 2], ["Projects", 1, 1, 1]])
  assert.deepEqual(Object.keys(M.folderSubtree(tree, "f-a")).sort(), ["f-a", "f-b"])
})

test("sources and filtering", () => {
  const tree = M.folderTree(folders, notes)
  assert.deepEqual(M.notesForSource(notes, M.SOURCE_ALL, "", tree).map(n => n.id), ["n-1", "n-2", "n-3"])
  assert.deepEqual(M.notesForSource(notes, M.SOURCE_FOLDER, "f-a", tree).map(n => n.id), ["n-1", "n-2"])
  assert.deepEqual(M.notesForSource(notes, M.SOURCE_TAG, "y", tree).map(n => n.id), ["n-2"])
  assert.deepEqual(M.notesForSource(notes, M.SOURCE_TRASH, "", tree).map(n => n.id), ["n-4"])
  assert.deepEqual(M.notesForSource(notes, M.SOURCE_PINNED, "", tree).map(n => n.id), ["n-2"])
  assert.deepEqual(M.notesForSource(notes, M.SOURCE_UNFILED, "", tree).map(n => n.id), ["n-3"])
  assert.deepEqual(M.filterNotes(notes, "body", {}).map(n => n.id), ["n-2"])
  assert.deepEqual(M.filterNotes(notes, "zzz", { "n-3": true }).map(n => n.id), ["n-3"])
  assert.deepEqual(M.tagCounts(notes), [{ tag: "x", count: 2 }, { tag: "y", count: 1 }])
})

test("formatting", () => {
  assert.equal(M.formatUpdated(Date.now() - 30000, Date.now()), "just now")
  assert.equal(M.formatUpdated(Date.now() - 3 * 3600000, Date.now()), "3h ago")
  assert.equal(M.syncLabel("offline", 2), "Offline · 2 unsent")
  assert.equal(M.syncLabel("online", 0), "Synced")
})

// --- preview ----------------------------------------------------------------

const sha = "a".repeat(64)

test("splitPreview lifts attachment images and links tasks", () => {
  const text = "# T\n- [ ] todo\ntext ![shot](attachments/" + sha + ".png) after\n```\n- [ ] in code\n```"
  const segments = M.splitPreview(text, "/data")
  assert.equal(segments.length, 3)
  assert.ok(segments[0].text.includes("[" + M.GLYPH.taskOpen + "](task:1) todo"))
  assert.deepEqual(segments[1], { kind: "image", url: "file:///data/attachments/" + sha + ".png", title: "shot" })
  assert.match(segments[2].text, /after/)
  assert.match(segments[2].text, /- \[ \] in code/)
})

test("attachment urls only for well-formed names", () => {
  assert.equal(M.attachmentUrl("/d", "attachments/../x.png"), "")
  assert.equal(M.attachmentUrl("/d", "attachments/" + sha + ".png"), "file:///d/attachments/" + sha + ".png")
})

test("links and tasks from the preview", () => {
  assert.equal(M.externalLinkUrl("https://ok.example/x"), "https://ok.example/x")
  assert.equal(M.externalLinkUrl("https://a@b.example"), "")
  assert.equal(M.externalLinkUrl("file:///etc/passwd"), "")
  assert.equal(M.externalLinkUrl("javascript:alert(1)"), "")
  assert.equal(M.taskLine("task:12"), 12)
  assert.equal(M.taskLine("task:x"), -1)
})

test("styleMarkdown themes links, keeps task links neutral, drops remote embeds", () => {
  const out = M.styleMarkdown("[a](https://x.example) [☐](task:3) ![r](https://evil.example/p.png) <img src=x alt=y>",
    { linkColor: "#ff0000", fontSizePx: 13, tableBorderColor: "#333333" })
  assert.match(out, /<a href="https:\/\/x.example" style="color:#ff0000">a<\/a>/)
  assert.match(out, /<a href="task:3" style="text-decoration:none;color:#[0-9a-fA-F]+">☐<\/a>/)
  assert.doesNotMatch(out, /!\[/)
  assert.doesNotMatch(out, /<img/)
})

// --- manifest ---------------------------------------------------------------

test("manifest defaults survive the model's normalisation", () => {
  const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url)))
  assert.equal(manifest.id, M.PLUGIN_ID)
  const defaults = manifest.barWidget.defaults
  // Empty means "let the daemon read ~/.config/omajot/config.json": no --hub at all.
  assert.equal(defaults.hubUrl, "")
  assert.ok(!M.daemonArgv("/b", defaults.hubUrl, "/d").includes("--hub"))
  for (const entry of manifest.barWidget.schema) assert.ok(entry.key in defaults, entry.key)
})

// --- bare URLs in the preview ----------------------------------------------------

test("bare URLs become themed links, including ones md4c misses", () => {
  const style = { linkColor: "#ff0000", fontSizePx: 13, tableBorderColor: "#333333" }
  const text = "https://a.example/x/ee02-06\n\nhttps://b.example/v/ek2aqM#dmVwPVZp=\n\nsee https://c.example/p_q_r."
  const out = M.styleMarkdown(text, style)
  assert.match(out, /<a href="https:\/\/a\.example\/x\/ee02-06" style="color:#ff0000">/)
  assert.match(out, /<a href="https:\/\/b\.example\/v\/ek2aqM#dmVwPVZp=" style="color:#ff0000">/)
  // Trailing punctuation stays outside; underscores cannot turn into emphasis.
  assert.match(out, /href="https:\/\/c\.example\/p_q_r" style="color:#ff0000">https:\/\/c\.example\/p\\_q\\_r<\/a>\./)
})

test("URLs that are already links or autolinks are not linked twice", () => {
  const style = { linkColor: "#ff0000", fontSizePx: 13, tableBorderColor: "#333333" }
  const out = M.styleMarkdown("[site](https://a.example/) and [https://b.example/](https://b.example/) <https://c.example/>", style)
  assert.equal((out.match(/<a /g) || []).length, 2)
  assert.equal((out.match(/href="https:\/\/b\.example\/"/g) || []).length, 1)
  assert.match(out, /<https:\/\/c\.example\/>/)
})

test("task boxes use the theme's text and accent colours, not link blue", () => {
  const style = { linkColor: "#ff0000", textColor: "#eeeeee", fontSizePx: 13, tableBorderColor: "#333333" }
  const out = M.styleMarkdown(M.splitPreview("- [ ] open\n- [x] done", "/d")[0].text, style)
  assert.match(out, new RegExp('style="text-decoration:none;color:#eeeeee">' + M.GLYPH.taskOpen + "</a>"))
  assert.match(out, new RegExp('style="text-decoration:none;color:#ff0000">' + M.GLYPH.taskDone + "</a>"))
})
