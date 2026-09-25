import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import "../Model.mjs" as Model

// Markdown source editor for one note, with an optional preview beside it or
// instead of it. Any number of editors may show the same note: the service
// holds the one document and tells every view what changed.
//
// The editor never lets Qt's own undo run: it would also revert remote
// patches (spikes/qml/REPORT.md). Undo, redo, paste, list continuation and
// Ctrl+B/I all go through the service as edits.
Item {
  id: root

  property var service: null
  property string noteId: ""
  // "source" | "preview" | "split"
  property string mode: "source"
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property string monoFamily: "monospace"
  property real fontSize: Style.font.bodySmall
  property string placeholder: "Start typing…  The first line is the title."

  readonly property bool editorFocused: textArea.activeFocus
  readonly property bool loaded: root.loadedNote === root.noteId && root.noteId !== ""
  readonly property string currentText: root.previewText

  // Esc inside the editor: the owner decides (back to the list, close…).
  signal escapePressed()

  property string loadedNote: ""
  property bool applying: false
  property string previewText: ""
  // Identity passed as `origin` so this view skips its own changes.
  readonly property var token: root

  function focusEditor(atEnd) {
    if (root.mode === "preview") return
    textArea.forceActiveFocus()
    if (atEnd) textArea.cursorPosition = textArea.length
  }

  function syncPreview() { previewTimer.restart() }

  // --- document plumbing ------------------------------------------------------

  onNoteIdChanged: attach()
  onServiceChanged: attach()

  property string attachedNote: ""
  function attach() {
    if (root.attachedNote !== "" && root.service) root.service.closeDoc(root.attachedNote)
    root.attachedNote = ""
    root.loadedNote = ""
    root.applying = true
    textArea.text = ""
    root.applying = false
    root.previewText = ""
    if (!root.service || root.noteId === "") return
    root.attachedNote = root.noteId
    root.service.openDoc(root.noteId)
  }

  Component.onDestruction: {
    if (root.attachedNote !== "" && root.service) root.service.closeDoc(root.attachedNote)
  }

  function setWholeText(text) {
    var caret = textArea.cursorPosition
    root.applying = true
    textArea.text = text
    root.applying = false
    textArea.cursorPosition = Math.min(caret, textArea.length)
  }

  Connections {
    target: root.service
    function onDocReset(note, text) {
      if (note !== root.noteId) return
      root.setWholeText(text)
      root.loadedNote = note
      root.previewText = text
    }
    function onDocPatched(note, pieces, origin, caret) {
      if (note !== root.noteId || origin === root.token || !root.loaded) return
      root.applying = true
      for (var i = 0; i < pieces.length; i++) {
        var piece = pieces[i]
        if (piece.del > 0) textArea.remove(piece.pos, piece.pos + piece.del)
        if (piece.ins.length > 0) textArea.insert(piece.pos, piece.ins)
      }
      root.applying = false
      // Belt and braces: a view that somehow diverged takes the document's text.
      var expected = root.service.docText(root.noteId)
      if (textArea.text !== expected) root.setWholeText(expected)
      root.syncPreview()
    }
  }

  Timer {
    id: previewTimer
    interval: 120
    onTriggered: root.previewText = textArea.text
  }

  // --- helpers that edit through the service ------------------------------------

  function editAndPlace(edit, caret) {
    var where = root.service.applyEdit(root.noteId, edit, caret)
    if (where >= 0) textArea.cursorPosition = Math.min(where, textArea.length)
  }

  function wrap(marker) {
    var r = Model.wrapSelection(textArea.text, textArea.selectionStart, textArea.selectionEnd, marker)
    root.service.applyEdit(root.noteId, r.edit, r.selEnd)
    textArea.select(r.selStart, r.selEnd)
  }

  function history(forward) {
    var caret = forward ? root.service.redo(root.noteId) : root.service.undo(root.noteId)
    if (caret >= 0) textArea.cursorPosition = Math.min(caret, textArea.length)
  }

  function paste() {
    root.service.paste(root.noteId, textArea.selectionStart, textArea.selectionEnd, function(caret) {
      if (caret >= 0) textArea.cursorPosition = Math.min(caret, textArea.length)
    })
  }

  function toggleTask(line) {
    var edit = Model.toggleTaskAtLine(root.service.docText(root.noteId), line)
    if (edit) root.service.applyEdit(root.noteId, edit, textArea.cursorPosition)
  }

  // --- tag completion ---------------------------------------------------------

  property var completions: []
  function refreshCompletions() {
    if (!textArea.activeFocus || textArea.selectedText !== "") {
      completions = []
      return
    }
    var prefix = Model.tagPrefixAt(textArea.text, textArea.cursorPosition)
    completions = prefix === null || prefix === "" ? []
      : Model.tagCompletions(prefix, root.service ? root.service.tagList : [], 5)
  }

  function acceptCompletion(tag) {
    var prefix = Model.tagPrefixAt(textArea.text, textArea.cursorPosition)
    if (prefix === null) return
    var pos = textArea.cursorPosition
    root.editAndPlace({ pos: pos, del: 0, ins: tag.slice(prefix.length) + " " })
    completions = []
  }

  // --- layout -----------------------------------------------------------------

  readonly property bool showSource: root.mode !== "preview"
  readonly property bool showPreview: root.mode !== "source"

  ScrollView {
    id: sourceScroll
    visible: root.showSource
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    width: root.showPreview ? Math.floor((parent.width - Style.space(12)) / 2) : parent.width
    clip: true
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

    TextArea {
      id: textArea
      enabled: root.loaded
      wrapMode: TextEdit.Wrap
      textFormat: TextEdit.PlainText
      color: root.foreground
      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
      selectedTextColor: root.foreground
      placeholderText: root.loaded ? root.placeholder : ""
      placeholderTextColor: Qt.darker(root.foreground, 1.8)
      font.family: root.monoFamily
      font.pixelSize: root.fontSize
      leftPadding: Style.space(4)
      rightPadding: Style.space(4)
      topPadding: Style.space(2)
      background: null
      persistentSelection: true
      // Qt's context menu would offer its own undo, which must not run.
      ContextMenu.menu: null

      onTextChanged: {
        if (root.applying || !root.loaded) return
        root.service.localChange(root.noteId, text, cursorPosition, root.token)
        root.syncPreview()
        root.refreshCompletions()
      }
      onCursorPositionChanged: root.refreshCompletions()
      onActiveFocusChanged: if (!activeFocus) root.completions = []

      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0
        if (ctrl && event.key === Qt.Key_Z) {
          root.history(shift)
          event.accepted = true
        } else if (ctrl && event.key === Qt.Key_Y) {
          root.history(true)
          event.accepted = true
        } else if ((ctrl && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert)) {
          root.paste()
          event.accepted = true
        } else if (ctrl && event.key === Qt.Key_B) {
          root.wrap("**")
          event.accepted = true
        } else if (ctrl && event.key === Qt.Key_I) {
          root.wrap("*")
          event.accepted = true
        } else if (event.key === Qt.Key_Tab && root.completions.length > 0) {
          root.acceptCompletion(root.completions[0])
          event.accepted = true
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                   && !ctrl && !shift && textArea.selectedText === "") {
          var r = Model.continueList(textArea.text, textArea.cursorPosition)
          if (r) {
            root.editAndPlace(r.edit, r.caret)
            event.accepted = true
          }
        } else if (event.key === Qt.Key_Escape) {
          if (root.completions.length > 0) root.completions = []
          else root.escapePressed()
          event.accepted = true
        }
      }
    }
  }

  // Tag suggestions just below the caret.
  Row {
    id: suggestions
    visible: root.completions.length > 0 && root.showSource
    z: 10
    spacing: Style.space(4)
    x: Math.min(sourceScroll.x + textArea.cursorRectangle.x, sourceScroll.x + sourceScroll.width - width)
    y: sourceScroll.y + textArea.cursorRectangle.y + textArea.cursorRectangle.height
      - (sourceScroll.contentItem ? sourceScroll.contentItem.contentY : 0) + Style.space(4)

    Repeater {
      model: root.completions
      delegate: Rectangle {
        required property var modelData
        required property int index
        radius: Style.cornerRadius
        color: index === 0 ? Style.selectedFillFor(root.foreground, root.accent) : Color.background
        border.width: 1
        border.color: Style.normalBorderFor(root.foreground, root.accent)
        width: chip.implicitWidth + Style.space(12)
        height: chip.implicitHeight + Style.space(6)
        Text {
          id: chip
          anchors.centerIn: parent
          text: "#" + modelData + (index === 0 ? "  ⇥" : "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          onClicked: root.acceptCompletion(modelData)
        }
      }
    }
  }

  Rectangle {
    visible: root.showSource && root.showPreview
    anchors.left: sourceScroll.right
    anchors.leftMargin: Style.space(6)
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: 1
    color: Qt.darker(root.foreground, 3)
  }

  NotePreview {
    id: preview
    visible: root.showPreview
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    width: root.showSource ? sourceScroll.width : parent.width
    text: root.previewText
    dataDir: root.service ? root.service.dataDir : ""
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: root.fontSize
    onTaskToggled: function(line) { root.toggleTask(line) }
  }

  Text {
    anchors.centerIn: parent
    visible: root.noteId !== "" && !root.loaded
    text: "Opening…"
    color: Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
