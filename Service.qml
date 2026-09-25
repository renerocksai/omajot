import QtQuick
import Quickshell
import Quickshell.Io
import "Model.mjs" as Model

// Shared state for omajot: one `omajot daemon` child speaking the JSON-lines
// client protocol (docs/PROTOCOL.md §1), the note index it reports, and one
// document per open note that every view of that note shares.
//
// The daemon owns the replica, the CRDT and sync. This file only relays: a
// view's text change becomes an `edit`, a `patch` event becomes pieces every
// view applies with insert()/remove(). Model.mjs does the arithmetic.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // --- configuration (pushed by the bar widget, which owns the settings) ----

  property string hubUrl: ""
  // The hub the daemon actually syncs with (its hello reply): the URL phones open.
  property string activeHub: ""
  property string dataDirSetting: ""
  property string daemonSetting: ""
  property bool configured: false
  // Presentation settings for the main window, which cannot read the bar
  // widget's settings itself.
  property string previewMode: "split"
  property real editorFontSize: 0

  readonly property string dataDir: Model.dataDirectory(
    dataDirSetting, Quickshell.env("HOME"), Quickshell.env("XDG_DATA_HOME"))
  readonly property string dataDirUrl: Model.directoryUrl(dataDir)

  // resolvedUrl percent-encodes; argv wants the bytes.
  function pluginPath(relative) {
    return decodeURIComponent(String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, ""))
  }

  function configure(hub, dataDirValue, daemonPath) {
    // Empty stays empty: the daemon then reads ~/.config/omajot/config.json.
    var nextHub = String(hub || "").trim() === "" ? "" : Model.normalizeHubUrl(hub)
    var nextData = String(dataDirValue || "")
    var nextDaemon = String(daemonPath || "")
    var changed = !configured || nextHub !== hubUrl || nextData !== dataDirSetting
      || nextDaemon !== daemonSetting
    hubUrl = nextHub
    dataDirSetting = nextData
    daemonSetting = nextDaemon
    configured = true
    if (changed) restartDaemon()
  }

  // --- state ------------------------------------------------------------------

  // "starting" | "ready" | "missing" | "crashed"
  property string daemonState: "starting"
  property string lastError: ""
  property string replica: ""
  property string syncState: ""
  property int syncPending: 0
  property int syncHead: 0

  property var notes: []
  property var folders: []
  readonly property var sortedNotes: Model.sortNotes(notes)
  readonly property var tagList: Model.tagCounts(notes)
  readonly property var tree: Model.folderTree(folders, notes)
  readonly property string syncText: daemonState === "missing"
    ? "No daemon" : (daemonState === "crashed" ? "Daemon stopped" : Model.syncLabel(syncState, syncPending))

  // id -> doc (Model.newDoc) and id -> number of views holding it.
  property var docs: ({})
  property var docRefs: ({})

  // A view applies `pieces` unless it is `origin` (which already shows them).
  // `caret`, when >= 0, is where the view that asked should put its caret.
  signal docPatched(string note, var pieces, var origin, int caret)
  // The whole text was replaced (open, reopen after restart, resync).
  signal docReset(string note, string text)
  signal noteCreated(string note)

  // --- requests ---------------------------------------------------------------

  property int nextId: 1
  property var callbacks: ({})
  // Bumped on every downloaded attachment, so failed image loads retry.
  property int attachmentStamp: 0

  function request(cmd, fields, callback) {
    if (!daemon.running) {
      if (callback) callback({ ok: false, error: "daemon not running" })
      return
    }
    var id = nextId++
    if (callback) callbacks[id] = callback
    daemon.write(Model.requestLine(id, cmd, fields))
  }

  function handleLine(line) {
    var msg = Model.parseLine(line)
    if (!msg) return
    if (msg.re !== undefined) {
      var cb = callbacks[msg.re]
      delete callbacks[msg.re]
      if (msg.ok === false && !cb) lastError = String(msg.error || "request failed")
      if (cb) cb(msg)
      return
    }
    switch (msg.ev) {
    case "notes":
      notes = Model.upsertNotes(notes, msg.upsert || [])
      break
    case "folders":
      folders = msg.folders || []
      break
    case "patch":
      applyPatch(msg)
      break
    case "sync":
      syncState = String(msg.state || "")
      syncPending = Number(msg.pending) || 0
      syncHead = Number(msg.head) || 0
      break
    case "attachment":
      // A missing image arrived: previews reload their images (NotePreview).
      attachmentStamp += 1
      break
    case "error":
      lastError = String(msg.error || "")
      console.warn("omajot daemon:", lastError)
      break
    }
  }

  // --- documents --------------------------------------------------------------

  function openDoc(note) {
    if (!note) return
    var refs = docRefs[note] || 0
    docRefs[note] = refs + 1
    if (docs[note]) {
      var text = docs[note].text
      Qt.callLater(function() { root.docReset(note, text) })
      return
    }
    if (refs === 0) loadDoc(note)
  }

  function loadDoc(note) {
    request("open", { note: note }, function(reply) {
      if (!reply.ok) {
        lastError = String(reply.error || "could not open note")
        return
      }
      if (!root.docRefs[note]) return
      var existing = root.docs[note]
      if (existing) Model.docReset(existing, reply.text, reply.seq, reply.pseq)
      else root.docs[note] = Model.newDoc(note, reply.text, reply.seq, reply.pseq)
      root.docReset(note, String(reply.text || ""))
    })
  }

  function closeDoc(note) {
    if (!note || !docRefs[note]) return
    docRefs[note] -= 1
    if (docRefs[note] > 0) return
    delete docRefs[note]
    delete docs[note]
    request("close", { note: note }, null)
  }

  function docText(note) {
    return docs[note] ? docs[note].text : ""
  }

  function sendEdit(doc, edit) {
    request("edit", {
      note: doc.note, seq: edit.seq, ack: edit.ack, pos: edit.pos, del: edit.del, ins: edit.ins
    }, function(reply) {
      if (reply.ok) Model.docAck(doc, edit.seq)
      else root.resync(doc.note)
    })
    verifyTimer.restart()
  }

  // A view's text changed by typing. It already shows the change.
  function localChange(note, newText, caret, origin) {
    var doc = docs[note]
    if (!doc) return
    var edit = Model.docLocalEdit(doc, newText, Date.now(), caret)
    if (!edit) return
    sendEdit(doc, edit)
    docPatched(note, [{ pos: edit.pos, del: edit.del, ins: edit.ins }], origin, -1)
  }

  // An edit decided by code (list continuation, toggles, paste). No view has
  // applied it yet; `caret` tells the asking view where to go afterwards.
  // Returns where the asking view should put its caret, or -1.
  function applyEdit(note, edit, caret) {
    var doc = docs[note]
    if (!doc) return -1
    var out = Model.docApplyLocal(doc, edit, Date.now())
    if (!out) return -1
    sendEdit(doc, out)
    var where = caret === undefined ? out.pos + out.ins.length : caret
    docPatched(note, [{ pos: out.pos, del: out.del, ins: out.ins }], null, where)
    return where
  }

  function undo(note) { return runHistory(note, false) }
  function redo(note) { return runHistory(note, true) }

  function runHistory(note, forward) {
    var doc = docs[note]
    if (!doc) return -1
    var out = forward ? Model.docRedo(doc) : Model.docUndo(doc)
    if (!out) return -1
    sendEdit(doc, out)
    docPatched(note, [{ pos: out.pos, del: out.del, ins: out.ins }], null, out.caret)
    return out.caret
  }

  function applyPatch(msg) {
    var doc = docs[msg.note]
    if (!doc) return
    var result = Model.docApplyPatch(doc, msg, Date.now())
    if (result.resync) {
      resync(msg.note)
      return
    }
    if (result.pieces.length > 0) docPatched(msg.note, result.pieces, null, -1)
    verifyTimer.restart()
  }

  function resync(note) {
    if (docRefs[note]) loadDoc(note)
  }

  // After remote activity settles, compare with the daemon's text. A mismatch
  // (a transform the engine resolved differently) reloads the note instead of
  // letting two copies drift.
  Timer {
    id: verifyTimer
    interval: 1500
    onTriggered: {
      for (var note in root.docs) {
        var doc = root.docs[note]
        if (doc.pending.length > 0 || doc.patches === 0) continue
        root.verify(doc)
      }
    }
  }

  function verify(doc) {
    var expected = doc.text
    var seqAtAsk = doc.seq
    request("open", { note: doc.note }, function(reply) {
      if (!reply.ok || root.docs[doc.note] !== doc) return
      // Something was typed meanwhile; the next quiet moment checks again.
      if (doc.seq !== seqAtAsk || doc.text !== expected) return
      if (String(reply.text) === expected) return
      console.warn("omajot: note " + doc.note + " drifted from the daemon; reloading")
      Model.docReset(doc, reply.text, reply.seq, reply.pseq)
      root.docReset(doc.note, String(reply.text || ""))
    })
  }

  // --- notes and folders --------------------------------------------------------

  function createNote(folder, text, callback) {
    request("create", { folder: folder || null, text: text || "" }, function(reply) {
      if (reply.ok) root.noteCreated(reply.note)
      if (callback) callback(reply.ok ? reply.note : "")
    })
  }

  function setNote(note, fields) {
    var f = fields || {}
    f.note = note
    request("set", f, null)
  }

  function createFolder(name, parent, callback) {
    request("folder.create", { name: name, parent: parent || null }, function(reply) {
      if (callback) callback(reply.ok ? reply.folder : "")
    })
  }
  function renameFolder(folder, name) { request("folder.rename", { folder: folder, name: name }, null) }
  function moveFolder(folder, parent) { request("folder.move", { folder: folder, parent: parent || null }, null) }
  function deleteFolder(folder) { request("folder.delete", { folder: folder }, null) }

  // The module matrix for `text`: { size, rows: ["0101…"] }, or null.
  function qrCode(text, callback) {
    request("qr", { text: String(text || "") }, function(reply) {
      callback(reply.ok ? { size: reply.size, rows: reply.rows, footer: String(reply.footer || ""), loopback: reply.loopback === true } : null)
    })
  }

  // How to run a hub and reach it with Tailscale: { title, steps, footer }.
  function invite(callback) {
    request("invite", {}, function(reply) {
      callback(reply.ok ? { title: String(reply.title), steps: reply.steps || [], footer: String(reply.footer || "") } : null)
    })
  }

  function search(query, callback) {
    request("search", { q: query }, function(reply) {
      callback(reply.ok ? Model.idSet(reply.ids) : ({}))
    })
  }

  // Clipboard → markdown (images become attachments), then an ordinary edit
  // replacing the selection.
  function paste(note, selStart, selEnd, callback) {
    request("paste", { note: note, pos: selStart }, function(reply) {
      if (!reply.ok || !reply.ins) return
      var a = Math.min(selStart, selEnd)
      var b = Math.max(selStart, selEnd)
      // The view may have moved on to another note meanwhile.
      if (!root.docs[note] || b > root.docs[note].text.length) return
      var caret = root.applyEdit(note, { pos: a, del: b - a, ins: String(reply.ins) })
      if (callback) callback(caret)
    })
  }

  // --- the daemon process -----------------------------------------------------

  property int restartAttempt: 0
  property string daemonBinary: ""
  property bool stopping: false

  function restartDaemon() {
    restartTimer.stop()
    if (daemon.running) {
      stopping = true
      daemon.running = false
    }
    locateTimer.restart()
  }

  // Explicit setting, then a release binary, then a local build.
  Process {
    id: locate
    running: false
    stdout: StdioCollector { id: locateOut; waitForEnd: true }
    onExited: function(exitCode) {
      var path = String(locateOut.text || "").trim().split("\n")[0]
      if (exitCode !== 0 || path === "") {
        root.daemonState = "missing"
        root.lastError = "omajot binary not found (bin/omajot or zig-out/bin/omajot)"
        return
      }
      root.daemonBinary = path
      root.startDaemon()
    }
  }

  Timer {
    id: locateTimer
    interval: 50
    onTriggered: {
      if (locate.running) return
      var candidates = []
      if (root.daemonSetting !== "") candidates.push(root.daemonSetting)
      candidates.push(root.pluginPath("bin/omajot"), root.pluginPath("zig-out/bin/omajot"))
      var script = "for f in \"$@\"; do if [ -x \"$f\" ]; then echo \"$f\"; exit 0; fi; done; exit 1"
      locate.command = ["sh", "-c", script, "omajot-locate"].concat(candidates)
      locate.running = true
    }
  }

  function startDaemon() {
    daemon.command = Model.daemonArgv(daemonBinary, hubUrl, dataDir)
    daemonState = "starting"
    stopping = false
    daemon.running = true
  }

  Process {
    id: daemon
    running: false
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { if (String(line).trim() !== "") console.log("omajot daemon:", line) }
    }
    onStarted: root.handshake()
    onExited: function(exitCode) {
      // Outstanding callbacks will never be answered.
      var pending = root.callbacks
      root.callbacks = ({})
      for (var id in pending) pending[id]({ ok: false, error: "daemon exited" })
      if (root.stopping) {
        root.stopping = false
        return
      }
      root.daemonState = "crashed"
      root.lastError = "omajot daemon exited (" + exitCode + ")"
      restartTimer.interval = Model.restartDelay(root.restartAttempt)
      root.restartAttempt += 1
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    onTriggered: if (!daemon.running) root.startDaemon()
  }

  function handshake() {
    request("hello", { client: "qml" }, function(reply) {
      if (!reply.ok) {
        root.lastError = String(reply.error || "hello failed")
        return
      }
      root.replica = String(reply.replica || "")
      root.activeHub = String(reply.hub || "")
      root.daemonState = "ready"
      root.restartAttempt = 0
      root.lastError = ""
      root.refreshIndex()
      // Views that were open before a restart get their text again.
      for (var note in root.docRefs) root.loadDoc(note)
      root.request("status", {}, function(status) {
        if (!status.ok) return
        root.syncState = String(status.sync || "")
        root.syncPending = Number(status.pending) || 0
        root.syncHead = Number(status.head) || 0
      })
    })
  }

  function refreshIndex() {
    request("list", {}, function(reply) {
      if (!reply.ok) return
      root.notes = reply.notes || []
      root.folders = reply.folders || []
    })
  }

  // Configuration normally arrives from the bar widget within moments; a
  // service whose widget is not on the bar still starts with the defaults.
  Timer {
    interval: 1500
    running: true
    onTriggered: if (!root.configured) root.configure(root.hubUrl, root.dataDirSetting, root.daemonSetting)
  }

  Component.onDestruction: {
    stopping = true
    daemon.running = false
  }
}
