import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "../Model.mjs" as Model

// The bar dropdown: quick capture and quick edits. Pinned and recent notes on
// the left (or search results), the selected note editable on the right.
// Everything else lives in the main window (Panel.qml).
Panel {
  id: root
  moduleName: "io.github.renerocksai.omajot"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color mutedForeground: Qt.darker(contentForeground, 1.5)
  property real editorFontSize: Style.font.bodySmall

  property string query: ""
  property var bodyMatches: ({})
  property string selectedNoteId: ""
  property bool previewing: false
  property date now: new Date()

  readonly property var allNotes: service ? service.sortedNotes : []
  readonly property var visibleNotes: {
    var live = Model.notesForSource(root.allNotes, Model.SOURCE_ALL, "", [])
    if (root.query.trim() !== "") return Model.filterNotes(live, root.query, root.bodyMatches)
    return live.slice(0, 40)
  }
  readonly property var selectedNote: Model.findNote(root.allNotes, root.selectedNoteId)

  function indexOfNote(id) {
    for (var i = 0; i < visibleNotes.length; i++) if (visibleNotes[i].id === id) return i
    return -1
  }

  function selectNote(id) { selectedNoteId = String(id || "") }

  function moveSelection(delta) {
    if (visibleNotes.length === 0) return
    var current = indexOfNote(selectedNoteId)
    var next = current < 0 ? 0 : Math.max(0, Math.min(visibleNotes.length - 1, current + delta))
    selectNote(visibleNotes[next].id)
  }

  function editSelected() {
    if (selectedNoteId === "") return
    editor.focusEditor(true)
  }

  // Quick capture: a fresh note, focused, in the dropdown.
  function capture() {
    if (!opened) open()
    if (!service) return
    service.createNote(null, "", function(id) {
      if (id === "") return
      searchField.text = ""
      root.selectNote(id)
      focusWhenLoaded.restart()
    })
  }

  Timer {
    id: focusWhenLoaded
    interval: 40
    repeat: true
    property int attempts: 0
    onTriggered: {
      attempts += 1
      if (editor.loaded || attempts > 50) {
        stop()
        attempts = 0
        editor.focusEditor(true)
      }
    }
  }

  function openWindow() {
    close()
    if (hostWidget) hostWidget.openWindow(selectedNoteId)
  }

  Timer {
    id: searchDebounce
    interval: 160
    onTriggered: {
      if (!root.service || root.query.trim() === "") {
        root.bodyMatches = ({})
        return
      }
      root.service.search(root.query, function(ids) { root.bodyMatches = ids })
    }
  }

  onVisibleNotesChanged: {
    if (visibleNotes.length === 0) return
    if (indexOfNote(selectedNoteId) < 0 && !(selectedNote && !selectedNote.trashed)) selectNote(visibleNotes[0].id)
  }

  onOpenedChanged: if (opened) {
    now = new Date()
    searchField.text = ""
    if (selectedNoteId === "" && visibleNotes.length > 0) selectNote(visibleNotes[0].id)
    keyCatcher.forceActiveFocus()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(820))
    contentHeight: panel.fittedContentHeight(Style.space(500))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: editor.editorFocused || searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveSelection(dy)
        if (dx > 0) root.editSelected()
      }
      onActivateRequested: root.editSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "n") root.capture()
        else if (text === "/") searchField.forceActiveFocus()
        else if (text === "o") root.openWindow()
        else if (text === "p") root.previewing = !root.previewing
        else if (text === "q") root.close()
      }

      // --- header -----------------------------------------------------------

      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(headingLabel.height, searchField.height, newButton.height)

        Text {
          id: headingLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "OMAJOT"
          color: root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
          font.bold: true
        }

        Text {
          anchors.left: headingLabel.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.service ? root.service.syncText : ""
          color: root.service && root.service.daemonState !== "ready" ? Color.urgent : root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        TextField {
          id: searchField
          anchors.right: previewButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(170)
          foreground: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(2)
          placeholderText: "Search…  /"
          onTextChanged: {
            root.query = text
            searchDebounce.restart()
          }
          Keys.onEscapePressed: {
            text = ""
            keyCatcher.forceActiveFocus()
          }
          Keys.onReturnPressed: root.editSelected()
          Keys.onDownPressed: { root.moveSelection(1); keyCatcher.forceActiveFocus() }
        }

        PanelActionButton {
          id: previewButton
          anchors.right: newButton.left
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.previewing ? Model.GLYPH.source : Model.GLYPH.preview
          tooltipText: root.previewing ? "Edit markdown  ·  p" : "Preview  ·  p"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onClicked: root.previewing = !root.previewing
        }

        PanelActionButton {
          id: newButton
          anchors.right: windowButton.left
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.GLYPH.newNote
          tooltipText: "New note  ·  n"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onClicked: root.capture()
        }

        PanelActionButton {
          id: windowButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.GLYPH.window
          tooltipText: "Open omajot  ·  o"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onClicked: root.openWindow()
        }
      }

      // --- body -------------------------------------------------------------

      Item {
        id: body
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        ListView {
          id: noteList
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          width: Style.space(240)
          clip: true
          model: root.visibleNotes
          spacing: Style.space(1)
          boundsBehavior: Flickable.StopAtBounds
          currentIndex: root.indexOfNote(root.selectedNoteId)
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          delegate: NoteRow {
            required property var modelData
            width: noteList.width
            note: modelData
            now: root.now
            selected: modelData.id === root.selectedNoteId
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: {
              root.selectNote(modelData.id)
              keyCatcher.forceActiveFocus()
            }
            onDoubleClicked: {
              root.selectNote(modelData.id)
              root.editSelected()
            }
          }

          Text {
            anchors.centerIn: parent
            visible: noteList.count === 0
            text: root.query.trim() !== "" ? "No match" : "No notes yet · n"
            color: root.mutedForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator {
          id: separator
          anchors.left: noteList.right
          anchors.leftMargin: Style.space(8)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: 1
          foreground: root.contentForeground
        }

        NoteEditor {
          id: editor
          anchors.left: separator.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          service: root.service
          noteId: root.opened ? root.selectedNoteId : ""
          mode: root.previewing ? "preview" : "source"
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: root.editorFontSize
          onEscapePressed: keyCatcher.forceActiveFocus()
        }

        Text {
          anchors.centerIn: editor
          visible: root.selectedNoteId === ""
          text: "Select a note, or press n"
          color: root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
