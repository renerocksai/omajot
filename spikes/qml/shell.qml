// Spike 0c: QML TextArea as the omajot editor.
// Run: qs -p spikes/qml/shell.qml   (standalone, not inside omarchy-shell)
// Questions: speed on a 200 KB note, delta extraction by diffing,
// remote patches via insert()/remove() without cursor jumps, undo behaviour,
// markdown preview with a relative image.
import QtQuick
import QtQuick.Controls
import Quickshell

ShellRoot {
  id: root

  property string lastText: ""
  property bool applyingRemote: false
  property int localOps: 0
  property real diffMsTotal: 0

  function log(msg) { console.log("SPIKE " + msg) }

  // Common prefix/suffix diff: the whole change as one {pos, del, ins}.
  function diff(a, b) {
    let start = 0
    const max = Math.min(a.length, b.length)
    while (start < max && a.charCodeAt(start) === b.charCodeAt(start)) start++
    let endA = a.length, endB = b.length
    while (endA > start && endB > start && a.charCodeAt(endA - 1) === b.charCodeAt(endB - 1)) { endA--; endB-- }
    return { pos: start, del: endA - start, ins: b.slice(start, endB) }
  }

  function bigNote() {
    const para = "## Heading\n\nSome **bold** text with a [link](https://example.com) and #tag, Grüße 🎉.\n- [ ] task\n- [x] done\n\n"
    let s = "# Big note\n\n"
    while (s.length < 200000) s += para
    return s
  }

  FloatingWindow {
    id: win
    visible: true
    title: "omajot-spike"
    implicitWidth: 1000
    implicitHeight: 700
    color: "#1e1e2e"

    Row {
      anchors.fill: parent
      ScrollView {
        width: parent.width / 2; height: parent.height
        TextArea {
          id: editor
          objectName: "editor"
          font.family: "monospace"
          color: "#cdd6f4"
          wrapMode: TextEdit.Wrap
          focus: true
          // Built-in undo would also revert remote patches (verified), so
          // undo/redo must be omajot's own, driven by the local op history.
          Keys.onPressed: function(event) {
            if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Z || event.key === Qt.Key_Y)) {
              root.log("intercepted " + (event.key === Qt.Key_Z ? "undo" : "redo"))
              event.accepted = true
            }
          }
          onTextChanged: {
            if (root.applyingRemote) return
            const t0 = Date.now()
            const t = text
            const d = root.diff(root.lastText, t)
            root.lastText = t
            const ms = Date.now() - t0
            root.localOps++
            root.diffMsTotal += ms
            root.log("local op #" + root.localOps + " pos=" + d.pos + " del=" + d.del
                     + " ins=" + JSON.stringify(d.ins).slice(0, 40) + " diffMs=" + ms)
          }
        }
      }
      ScrollView {
        width: parent.width / 2; height: parent.height
        Text {
          id: preview
          width: parent.width
          textFormat: Text.MarkdownText
          color: "#cdd6f4"
          wrapMode: Text.Wrap
          baseUrl: Qt.resolvedUrl("pic.png").toString().replace(/pic\.png$/, "")  // must end with "/"
          text: "# Preview\n\nRelative image below:\n\n![pic](pic.png)\n\n- [x] done\n- [ ] open\n\nGrüße 🎉 #tag"
        }
      }
    }
  }

  Timer {
    interval: 800; running: true; repeat: false
    onTriggered: {
      // 1. Load 200 KB.
      let t0 = Date.now()
      root.applyingRemote = true
      editor.text = root.bigNote()
      root.applyingRemote = false
      root.lastText = editor.text
      log("load chars=" + editor.length + " ms=" + (Date.now() - t0))

      // 2. Cost of reading .text (a QString copy each time).
      t0 = Date.now()
      let n = 0
      for (let i = 0; i < 50; i++) n += editor.text.length
      log("read text x50 ms=" + (Date.now() - t0) + " perRead=" + ((Date.now() - t0) / 50).toFixed(2))

      // 3. Diff cost on 200 KB, change near the end (worst case for prefix scan).
      const a = editor.text
      const b = a.slice(0, a.length - 10) + "X" + a.slice(a.length - 10)
      t0 = Date.now()
      for (let i = 0; i < 20; i++) root.diff(a, b)
      log("diff 200KB x20 ms=" + (Date.now() - t0) + " perDiff=" + ((Date.now() - t0) / 20).toFixed(2))

      // 4. Remote patches before the cursor, with a selection.
      editor.forceActiveFocus()
      editor.select(150000, 150005)
      root.applyingRemote = true
      editor.insert(10, "REMOTE")
      const afterInsert = [editor.cursorPosition, editor.selectionStart, editor.selectionEnd]
      editor.remove(0, 2)
      const afterRemove = [editor.cursorPosition, editor.selectionStart, editor.selectionEnd]
      root.applyingRemote = false
      root.lastText = editor.text
      log("remote insert(10,6 chars): cursor/sel " + afterInsert + " expected 150011,150006,150011")
      log("remote remove(0,2): cursor/sel " + afterRemove + " expected 150009,150004,150009")
      log("canUndo after remote-only edits=" + editor.canUndo)

      // 5. Remote patch after the cursor must not move it.
      editor.cursorPosition = 100
      root.applyingRemote = true
      editor.insert(1000, "LATER")
      root.applyingRemote = false
      root.lastText = editor.text
      log("remote insert after cursor: cursor=" + editor.cursorPosition + " expected 100")
      editor.cursorPosition = 0
      log("ready-for-typing")
    }
  }

  // Report typing stats and undo behaviour once the driver has typed.
  Timer {
    interval: 1000; running: true; repeat: true
    onTriggered: if (root.localOps > 0) log("typing stats ops=" + root.localOps
                   + " avgDiffMs=" + (root.diffMsTotal / root.localOps).toFixed(2)
                   + " head=" + JSON.stringify(editor.text.slice(0, 40)))
  }
}
