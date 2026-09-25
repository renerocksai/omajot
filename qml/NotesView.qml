import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "../Model.mjs" as Model

// The omajot notes view: sources (all notes, folders, tags, trash) │ notes │
// the editor with its preview. Used by the main window (Panel.qml) and the bar
// dropdown (QuickPanel.qml), so both look and behave the same.
FocusScope {
  id: root

  property var service: null
  // Load the selected note into the editor only while the view is on screen.
  property bool active: false
  property bool showWindowButton: false
  property real sidebarWidth: Style.space(210)
  property real listWidth: Style.space(270)
  property real contentMargin: Style.space(14)

  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  readonly property color muted: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.resolvedFamily || Style.font.family
  property real editorFontSize: service && service.editorFontSize > 0
    ? service.editorFontSize : Style.font.body

  signal closeRequested()
  signal openWindowRequested(string noteId)
  signal tabRequested(int direction)

  // --- selection state ----------------------------------------------------------

  property string sourceKind: Model.SOURCE_ALL
  property string sourceId: ""
  property string selectedNoteId: ""
  property string query: ""
  property var bodyMatches: ({})
  property string mode: service && service.previewMode ? service.previewMode : "split"
  // 0 = sources, 1 = notes. The editor is reached with Enter / l.
  property int activePane: 1
  property date now: new Date()

  // Inline folder rename, and the folder picker ("move note / folder to…").
  property string renamingFolder: ""
  // The "open on your phone" QR overlay.
  property bool phoneOpen: false
  property var phoneQr: null
  // Without a hub: how to set one up (steps from the engine).
  property var phoneInvite: null

  function showPhone() {
    if (!service) return
    phoneOpen = true
    phoneQr = null
    phoneInvite = null
    var showInvite = function(note) {
      root.service.invite(function(invite) {
        if (invite) invite.note = note
        root.phoneInvite = invite
      })
    }
    if (service.activeHub === "") return showInvite("")
    service.qrCode(service.activeHub, function(code) {
      // A loopback hub URL works only on this computer: invite, don't show a useless code.
      if (code && code.loopback) showInvite("This hub address works only on this computer. A phone cannot open it: " + root.service.activeHub)
      else root.phoneQr = code
    })
  }
  property var picker: null   // { kind: "note"|"folder", id, title }
  property string confirmDeleteFolder: ""

  readonly property var allNotes: service ? service.sortedNotes : []
  readonly property var tree: service ? service.tree : []
  readonly property var tags: service ? service.tagList : []

  readonly property var sourceItems: {
    var live = Model.notesForSource(root.allNotes, Model.SOURCE_ALL, "", [])
    var items = [
      { kind: Model.SOURCE_ALL, id: "", title: "All notes", glyph: Model.GLYPH.all, depth: 0, count: live.length },
      { kind: Model.SOURCE_PINNED, id: "", title: "Pinned", glyph: Model.GLYPH.pin, depth: 0,
        count: Model.notesForSource(root.allNotes, Model.SOURCE_PINNED, "", []).length },
      { kind: Model.SOURCE_UNFILED, id: "", title: "Notes", glyph: Model.GLYPH.unfiled, depth: 0,
        count: Model.notesForSource(root.allNotes, Model.SOURCE_UNFILED, "", []).length },
      { kind: "header", id: "folders", title: "FOLDERS", depth: 0, count: -1 }
    ]
    for (var i = 0; i < root.tree.length; i++) {
      var f = root.tree[i]
      items.push({ kind: Model.SOURCE_FOLDER, id: f.id, title: f.name, glyph: Model.GLYPH.folder,
        depth: f.depth, count: f.total })
    }
    if (root.tags.length > 0) {
      items.push({ kind: "header", id: "tags", title: "TAGS", depth: 0, count: -1 })
      for (var j = 0; j < root.tags.length; j++) {
        items.push({ kind: Model.SOURCE_TAG, id: root.tags[j].tag, title: root.tags[j].tag,
          glyph: Model.GLYPH.tag, depth: 0, count: root.tags[j].count })
      }
    }
    items.push({ kind: "header", id: "", title: "", depth: 0, count: -1 })
    items.push({ kind: Model.SOURCE_TRASH, id: "", title: "Trash", glyph: Model.GLYPH.trash, depth: 0,
      count: Model.notesForSource(root.allNotes, Model.SOURCE_TRASH, "", []).length })
    return items
  }

  readonly property var visibleNotes: Model.filterNotes(
    Model.notesForSource(root.allNotes, root.sourceKind, root.sourceId, root.tree),
    root.query, root.bodyMatches)
  readonly property var selectedNote: Model.findNote(root.allNotes, root.selectedNoteId)
  readonly property string sourceTitle: {
    for (var i = 0; i < sourceItems.length; i++) {
      var item = sourceItems[i]
      if (item.kind === sourceKind && item.id === sourceId)
        return item.kind === Model.SOURCE_TAG ? "#" + item.title : item.title
    }
    return "Notes"
  }
  readonly property string selectedFolderName: {
    if (!selectedNote || !selectedNote.folder) return "Notes"
    for (var i = 0; i < tree.length; i++) if (tree[i].id === selectedNote.folder) return tree[i].name
    return "Notes"
  }

  // --- host ---------------------------------------------------------------------

  // Called when the view comes on screen; `payloadJson` may name a note.
  function show(payloadJson) {
    now = new Date()
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (error) { payload = {} }
    if (payload.note) {
      sourceKind = Model.SOURCE_ALL
      sourceId = ""
      selectNote(String(payload.note))
    } else if (selectedNoteId === "") {
      selectFirstNote()
    }
    Qt.callLater(function() { root.forceActiveFocus() })
  }

  // Quick capture: a fresh note without a folder, focused.
  function capture() {
    sourceKind = Model.SOURCE_ALL
    sourceId = ""
    searchField.text = ""
    newNote()
  }

  // --- selection ----------------------------------------------------------------

  function indexOfSource(kind, id) {
    for (var i = 0; i < sourceItems.length; i++)
      if (sourceItems[i].kind === kind && sourceItems[i].id === id) return i
    return 0
  }

  function indexOfNote(id) {
    for (var i = 0; i < visibleNotes.length; i++) if (visibleNotes[i].id === id) return i
    return -1
  }

  function selectSource(item) {
    if (!item || item.kind === "header") return
    sourceKind = item.kind
    sourceId = String(item.id || "")
    selectFirstNote()
  }

  function selectFirstNote() { selectNote(visibleNotes.length > 0 ? visibleNotes[0].id : "") }
  function selectNote(id) { selectedNoteId = String(id || "") }

  function moveSourceSelection(delta) {
    var step = delta > 0 ? 1 : -1
    var index = indexOfSource(sourceKind, sourceId)
    var next = index + step
    while (next >= 0 && next < sourceItems.length && sourceItems[next].kind === "header") next += step
    if (next < 0 || next >= sourceItems.length) return
    selectSource(sourceItems[next])
  }

  function moveNoteSelection(delta) {
    if (visibleNotes.length === 0) return
    var current = indexOfNote(selectedNoteId)
    var next = current < 0 ? 0 : Math.max(0, Math.min(visibleNotes.length - 1, current + delta))
    selectNote(visibleNotes[next].id)
  }

  function reconcileSelection() {
    if (visibleNotes.length === 0) {
      if (selectedNoteId !== "" && !(selectedNote && Model.notesForSource([selectedNote], sourceKind, sourceId, tree).length))
        selectNote("")
      return
    }
    if (indexOfNote(selectedNoteId) < 0) selectFirstNote()
  }
  onVisibleNotesChanged: Qt.callLater(root.reconcileSelection)

  // --- actions ------------------------------------------------------------------

  function newNote() {
    if (!service) return
    var folder = sourceKind === Model.SOURCE_FOLDER ? sourceId : null
    var text = sourceKind === Model.SOURCE_TAG ? "\n\n#" + sourceId : ""
    if (sourceKind === Model.SOURCE_TRASH) {
      sourceKind = Model.SOURCE_ALL
      sourceId = ""
    }
    service.createNote(folder, text, function(id) {
      if (id === "") return
      if (root.sourceKind === Model.SOURCE_PINNED) {
        root.sourceKind = Model.SOURCE_ALL
        root.sourceId = ""
      }
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
        editor.focusEditor(false)
      }
    }
  }

  function togglePin() {
    if (selectedNote) service.setNote(selectedNote.id, { pinned: !selectedNote.pinned })
  }

  function trashOrRestore() {
    if (!selectedNote) return
    var index = indexOfNote(selectedNote.id)
    service.setNote(selectedNote.id, { trashed: !selectedNote.trashed })
    // Land on the neighbour, as a list does when a row leaves it.
    var neighbour = visibleNotes[index + 1] || visibleNotes[index - 1]
    selectNote(neighbour ? neighbour.id : "")
  }

  function cycleMode() {
    mode = mode === "split" ? "source" : (mode === "source" ? "preview" : "split")
  }

  function newFolder() {
    var parent = sourceKind === Model.SOURCE_FOLDER ? sourceId : null
    service.createFolder("New folder", parent, function(id) {
      if (id === "") return
      root.sourceKind = Model.SOURCE_FOLDER
      root.sourceId = id
      root.renamingFolder = id
    })
  }

  function pickFolder(target) {
    if (!picker) return
    if (picker.kind === "note") service.setNote(picker.id, { folder: target || null })
    else if (picker.kind === "folder" && target !== picker.id) service.moveFolder(picker.id, target || null)
    picker = null
    root.forceActiveFocus()
  }

  // Folders a folder may move into: not itself, not its own subtree.
  function pickerTargets() {
    var excluded = picker && picker.kind === "folder" ? Model.folderSubtree(tree, picker.id) : ({})
    var out = [{ id: "", name: picker && picker.kind === "folder" ? "Top level" : "Notes (no folder)", depth: 0 }]
    for (var i = 0; i < tree.length; i++) if (!excluded[tree[i].id]) out.push(tree[i])
    return out
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

  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.now = date
  }

  // --- view -------------------------------------------------------------------

  readonly property bool typing: editor.editorFocused || searchField.activeFocus || renameField.activeFocus

  Keys.onPressed: function(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (ctrl && event.key === Qt.Key_N) { root.newNote(); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_F) { searchField.forceActiveFocus(); searchField.selectAll(); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_E) { root.cycleMode(); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_P) { root.togglePin(); event.accepted = true; return }
    if (root.typing) return
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.tabRequested(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Escape) {
      if (root.phoneOpen) root.phoneOpen = false
      else if (root.picker) root.picker = null
      else if (root.confirmDeleteFolder !== "") root.confirmDeleteFolder = ""
      else root.closeRequested()
      event.accepted = true
      return
    }
    if (root.picker || root.phoneOpen) return
    var text = event.text
    if (event.key === Qt.Key_Down || text === "j") root.activePane === 0 ? root.moveSourceSelection(1) : root.moveNoteSelection(1)
    else if (event.key === Qt.Key_Up || text === "k") root.activePane === 0 ? root.moveSourceSelection(-1) : root.moveNoteSelection(-1)
    else if (event.key === Qt.Key_Left || text === "h") root.activePane = 0
    else if (event.key === Qt.Key_Right || text === "l") {
      if (root.activePane === 0) root.activePane = 1
      else editor.focusEditor(false)
    }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) editor.focusEditor(false)
    else if (text === "/") { searchField.forceActiveFocus(); searchField.selectAll() }
    else if (text === "n") root.newNote()
    else if (text === "p") root.togglePin()
    else if (text === "x" || event.key === Qt.Key_Delete) root.trashOrRestore()
    else if (text === "m" && root.selectedNote) root.picker = { kind: "note", id: root.selectedNote.id, title: Model.noteTitle(root.selectedNote) }
    else if (text === "e") root.cycleMode()
    else if (text === "q") root.closeRequested()
    else if (text === "o" && root.showWindowButton) root.openWindowRequested(root.selectedNoteId)
    else return
    event.accepted = true
  }

  Item {
    id: content
    anchors.fill: parent
    anchors.margins: root.contentMargin

    // ----------------------------------------------------------- sources

    Item {
      id: sidebar
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      width: root.sidebarWidth

      Text {
        id: brand
        anchors.top: parent.top
        anchors.left: parent.left
        text: "omajot"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      PanelActionButton {
        id: phoneButton
        anchors.right: parent.right
        anchors.verticalCenter: brand.verticalCenter
        size: Style.space(22)
        fontSize: Style.font.bodySmall
        visible: root.service !== null && root.service.daemonState === "ready"
        iconText: Model.GLYPH.phone
        tooltipText: root.service && root.service.activeHub !== "" ? "Open omajot on your phone" : "Use omajot on your phone"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.showPhone()
      }

      Text {
        anchors.left: brand.right
        anchors.leftMargin: Style.space(8)
        anchors.baseline: brand.baseline
        text: root.service ? root.service.syncText : ""
        color: root.service && root.service.daemonState !== "ready" ? Color.urgent : root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      ListView {
        id: sourceList
        anchors.top: brand.bottom
        anchors.topMargin: Style.space(12)
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        model: root.sourceItems
        spacing: Style.space(1)
        boundsBehavior: Flickable.StopAtBounds
        currentIndex: root.indexOfSource(root.sourceKind, root.sourceId)
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

        delegate: Rectangle {
          id: sourceRow
          required property var modelData
          required property int index
          readonly property bool isHeader: modelData.kind === "header"
          readonly property bool isFolder: modelData.kind === Model.SOURCE_FOLDER
          readonly property bool selected: !isHeader && modelData.kind === root.sourceKind && modelData.id === root.sourceId
          readonly property bool renaming: isFolder && root.renamingFolder === modelData.id

          width: sourceList.width
          height: isHeader ? Style.space(modelData.title === "" ? 10 : 24) : Style.space(26)
          radius: Style.cornerRadius
          color: {
            if (selected) return Style.selectedFillFor(root.foreground, root.accent)
            if (rowMouse.containsMouse && !isHeader) return Style.hoverFillFor(root.foreground, root.accent)
            return "transparent"
          }
          border.width: selected && root.activePane === 0 ? 1 : 0
          border.color: Style.focusBorderFor(root.foreground, root.accent)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            visible: sourceRow.isHeader
            text: sourceRow.modelData.title
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
            font.bold: true
          }

          PanelActionButton {
            visible: sourceRow.isHeader && sourceRow.modelData.id === "folders"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            size: Style.space(20)
            fontSize: Style.font.caption
            iconText: Model.GLYPH.add
            tooltipText: "New folder"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.newFolder()
          }

          Text {
            id: sourceGlyph
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6) + sourceRow.modelData.depth * Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(16)
            visible: !sourceRow.isHeader
            text: sourceRow.isFolder && sourceRow.selected ? Model.GLYPH.folderOpen : (sourceRow.modelData.glyph || "")
            color: sourceRow.selected ? root.foreground : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.left: sourceGlyph.right
            anchors.leftMargin: Style.space(4)
            anchors.right: folderActions.visible ? folderActions.left : sourceCount.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            visible: !sourceRow.isHeader && !sourceRow.renaming
            text: sourceRow.modelData.title
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            id: folderActions
            anchors.right: sourceCount.left
            anchors.rightMargin: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter
            visible: sourceRow.isFolder && !sourceRow.renaming && (rowMouse.containsMouse || actionsHover.hovered)
            spacing: 0
            HoverHandler { id: actionsHover }
            PanelActionButton {
              size: Style.space(20); fontSize: Style.font.caption
              iconText: Model.GLYPH.rename; tooltipText: "Rename"
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.renamingFolder = sourceRow.modelData.id
            }
            PanelActionButton {
              size: Style.space(20); fontSize: Style.font.caption
              iconText: Model.GLYPH.move; tooltipText: "Move folder…"
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.picker = { kind: "folder", id: sourceRow.modelData.id, title: sourceRow.modelData.title }
            }
            PanelActionButton {
              size: Style.space(20); fontSize: Style.font.caption
              iconText: Model.GLYPH.trash; tooltipText: "Delete folder"
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.confirmDeleteFolder = sourceRow.modelData.id
            }
          }

          Text {
            id: sourceCount
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            visible: !sourceRow.isHeader && !sourceRow.renaming
            text: sourceRow.modelData.count > 0 ? String(sourceRow.modelData.count) : ""
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: !sourceRow.isHeader
            enabled: !sourceRow.isHeader && !sourceRow.renaming
            z: -1
            onClicked: {
              root.activePane = 0
              root.selectSource(sourceRow.modelData)
              root.forceActiveFocus()
            }
            onDoubleClicked: if (sourceRow.isFolder) root.renamingFolder = sourceRow.modelData.id
          }
        }
      }

      // One rename field, placed over the row being renamed.
      TextField {
        id: renameField
        visible: root.renamingFolder !== ""
        x: Style.space(26)
        width: sidebar.width - x
        y: {
          var index = root.indexOfSource(Model.SOURCE_FOLDER, root.renamingFolder)
          var item = sourceList.itemAtIndex(index)
          return item ? sourceList.y + item.y - sourceList.contentY : sourceList.y
        }
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalPadding: Style.space(4)
        verticalPadding: Style.space(2)
        onVisibleChanged: if (visible) {
          var index = root.indexOfSource(Model.SOURCE_FOLDER, root.renamingFolder)
          text = index >= 0 ? root.sourceItems[index].title : ""
          forceActiveFocus()
          selectAll()
        }
        Keys.onReturnPressed: {
          var name = Model.plainLine(text)
          if (name !== "") root.service.renameFolder(root.renamingFolder, name)
          root.renamingFolder = ""
          root.forceActiveFocus()
        }
        Keys.onEscapePressed: {
          root.renamingFolder = ""
          root.forceActiveFocus()
        }
        onActiveFocusChanged: if (!activeFocus && visible) root.renamingFolder = ""
      }
    }

    PanelSeparator {
      id: sep1
      anchors.left: sidebar.right
      anchors.leftMargin: Style.space(10)
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: 1
      foreground: root.foreground
    }

    // ------------------------------------------------------------- notes

    Item {
      id: middle
      anchors.left: sep1.right
      anchors.leftMargin: Style.space(10)
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: root.listWidth

      Text {
        id: sourceHeading
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: newNoteButton.left
        anchors.rightMargin: Style.space(4)
        text: root.sourceTitle
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      PanelActionButton {
        id: windowButton
        visible: root.showWindowButton
        anchors.right: parent.right
        anchors.verticalCenter: sourceHeading.verticalCenter
        iconText: Model.GLYPH.window
        tooltipText: "Open in a window  ·  o"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.openWindowRequested(root.selectedNoteId)
      }

      PanelActionButton {
        id: newNoteButton
        anchors.right: root.showWindowButton ? windowButton.left : parent.right
        anchors.verticalCenter: sourceHeading.verticalCenter
        iconText: Model.GLYPH.newNote
        tooltipText: "New note  ·  n / Ctrl+N"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.newNote()
      }

      TextField {
        id: searchField
        anchors.top: sourceHeading.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        placeholderText: "Search titles and text…  /"
        onTextChanged: {
          root.query = text
          searchDebounce.restart()
        }
        Keys.onEscapePressed: {
          text = ""
          root.forceActiveFocus()
        }
        Keys.onReturnPressed: {
          root.activePane = 1
          root.forceActiveFocus()
        }
        Keys.onDownPressed: {
          root.activePane = 1
          root.moveNoteSelection(1)
          root.forceActiveFocus()
        }
      }

      ListView {
        id: noteList
        anchors.top: searchField.bottom
        anchors.topMargin: Style.space(10)
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
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
          dimmed: modelData.trashed
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          border.width: selected && root.activePane === 1 && !root.typing ? 1 : 0
          border.color: Style.focusBorderFor(root.foreground, root.accent)
          onClicked: {
            root.activePane = 1
            root.selectNote(modelData.id)
            root.forceActiveFocus()
          }
          onDoubleClicked: {
            root.selectNote(modelData.id)
            editor.focusEditor(false)
          }
        }

        Text {
          anchors.centerIn: parent
          visible: noteList.count === 0
          text: root.query.trim() !== "" ? "No match"
            : (root.sourceKind === Model.SOURCE_TRASH ? "Trash is empty" : "No notes here · n")
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    PanelSeparator {
      id: sep2
      anchors.left: middle.right
      anchors.leftMargin: Style.space(10)
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: 1
      foreground: root.foreground
    }

    // ------------------------------------------------------------ editor

    Item {
      id: editorPane
      anchors.left: sep2.right
      anchors.leftMargin: Style.space(14)
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom

      Item {
        id: editorHeader
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(metaColumn.implicitHeight, actions.height)
        visible: root.selectedNote !== null

        Column {
          id: metaColumn
          anchors.left: parent.left
          anchors.right: actions.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)
          Text {
            width: parent.width
            text: root.selectedNote ? Model.noteTitle(root.selectedNote) : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            text: {
              if (!root.selectedNote) return ""
              var parts = [Model.formatUpdated(root.selectedNote.updated, root.now), root.selectedFolderName]
              if ((root.selectedNote.tags || []).length > 0) parts.push("#" + root.selectedNote.tags.join(" #"))
              if (root.selectedNote.trashed) parts.push("in Trash")
              return parts.join("  ·  ")
            }
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: actions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)
          PanelActionButton {
            iconText: root.mode === "split" ? Model.GLYPH.split : (root.mode === "source" ? Model.GLYPH.source : Model.GLYPH.preview)
            tooltipText: "Layout: " + root.mode + "  ·  e / Ctrl+E"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.cycleMode()
          }
          PanelActionButton {
            iconText: Model.GLYPH.pin
            tooltipText: root.selectedNote && root.selectedNote.pinned ? "Unpin  ·  p" : "Pin  ·  p"
            foreground: root.selectedNote && root.selectedNote.pinned ? root.accent : root.foreground
            fontFamily: root.fontFamily
            onClicked: root.togglePin()
          }
          PanelActionButton {
            iconText: Model.GLYPH.folder
            tooltipText: "Move to folder…  ·  m"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: if (root.selectedNote) root.picker = { kind: "note", id: root.selectedNote.id, title: Model.noteTitle(root.selectedNote) }
          }
          PanelActionButton {
            iconText: root.selectedNote && root.selectedNote.trashed ? Model.GLYPH.restore : Model.GLYPH.trash
            tooltipText: root.selectedNote && root.selectedNote.trashed ? "Restore  ·  x" : "Move to Trash  ·  x"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.trashOrRestore()
          }
        }
      }

      PanelSeparator {
        id: editorRule
        anchors.top: editorHeader.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        visible: root.selectedNote !== null
        foreground: root.foreground
      }

      NoteEditor {
        id: editor
        anchors.top: editorRule.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        service: root.service
        noteId: root.active ? root.selectedNoteId : ""
        mode: root.mode
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: root.editorFontSize
        onEscapePressed: {
          root.activePane = 1
          root.forceActiveFocus()
        }
      }

      Text {
        anchors.centerIn: parent
        visible: root.selectedNote === null
        text: !root.service ? ""
          : root.service.daemonState === "installing" ? "Installing the omajot program…"
          : root.service.daemonState === "missing"
            ? "The omajot program is missing.\n" + root.service.lastError
              + "\nOr build it: zig build -Doptimize=ReleaseSafe in the plugin directory."
          : "Select a note, or press n for a new one"
        width: Math.min(parent.width - Style.space(24), implicitWidth)
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  // ------------------------------------------------------ folder picker

  Rectangle {
    anchors.fill: parent
    visible: root.picker !== null
    color: Qt.rgba(0, 0, 0, 0.45)
    MouseArea { anchors.fill: parent; onClicked: root.picker = null }

    Rectangle {
      anchors.centerIn: parent
      width: Style.space(340)
      height: Math.min(parent.height - Style.space(80), pickerColumn.implicitHeight + Style.space(24))
      radius: Style.cornerRadius
      color: root.background
      border.width: 1
      border.color: Style.normalBorderFor(root.foreground, root.accent)
      MouseArea { anchors.fill: parent }

      Column {
        id: pickerColumn
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(4)
        Text {
          width: parent.width
          text: root.picker ? "Move “" + root.picker.title + "” to" : ""
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        ListView {
          width: parent.width
          height: Math.min(contentHeight, Style.space(420))
          clip: true
          model: root.picker ? root.pickerTargets() : []
          delegate: Rectangle {
            required property var modelData
            width: ListView.view.width
            height: Style.space(26)
            radius: Style.cornerRadius
            color: pickMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6) + modelData.depth * Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: (modelData.id === "" ? Model.GLYPH.unfiled : Model.GLYPH.folder) + "  " + modelData.name
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: pickMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.pickFolder(modelData.id)
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------- open on your phone

  Rectangle {
    anchors.fill: parent
    visible: root.phoneOpen
    color: Qt.rgba(0, 0, 0, 0.55)
    MouseArea { anchors.fill: parent; onClicked: root.phoneOpen = false }

    Rectangle {
      anchors.centerIn: parent
      width: phoneColumn.implicitWidth + Style.space(32)
      height: phoneColumn.implicitHeight + Style.space(28)
      radius: Style.cornerRadius
      color: root.background
      border.width: 1
      border.color: Style.normalBorderFor(root.foreground, root.accent)
      MouseArea { anchors.fill: parent }

      Column {
        id: phoneColumn
        anchors.centerIn: parent
        spacing: Style.space(10)

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.phoneInvite ? root.phoneInvite.title.replace(/:$/, "") : "Open omajot on your phone"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        // Black on white whatever the theme, whole-pixel modules, 4-module quiet zone.
        Canvas {
          id: qrCanvas
          readonly property int modules: root.phoneQr ? root.phoneQr.size + 8 : 0
          readonly property int scale: modules > 0 ? Math.max(3, Math.floor(Style.space(260) / modules)) : 0
          anchors.horizontalCenter: parent.horizontalCenter
          width: modules * scale
          height: width
          visible: root.phoneQr !== null
          onPaint: {
            var ctx = getContext("2d")
            ctx.fillStyle = "#ffffff"
            ctx.fillRect(0, 0, width, height)
            if (!root.phoneQr) return
            ctx.fillStyle = "#000000"
            var rows = root.phoneQr.rows
            for (var y = 0; y < rows.length; y++)
              for (var x = 0; x < rows[y].length; x++)
                if (rows[y].charAt(x) === "1") ctx.fillRect((x + 4) * scale, (y + 4) * scale, scale, scale)
          }
          Connections {
            target: root
            function onPhoneQrChanged() { qrCanvas.requestPaint() }
          }
        }

        Text {
          width: Style.space(420)
          visible: text !== ""
          text: root.phoneInvite && root.phoneInvite.note ? root.phoneInvite.note : ""
          wrapMode: Text.Wrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // No hub yet: the steps to run one and reach it with Tailscale.
        Repeater {
          model: root.phoneInvite ? root.phoneInvite.steps : []
          delegate: TextEdit {
            required property var modelData
            required property int index
            width: Style.space(420)
            text: (index + 1) + ". " + modelData
            wrapMode: TextEdit.Wrap
            readOnly: true
            selectByMouse: true
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        TextEdit {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.phoneQr !== null
          text: root.service ? root.service.activeHub : ""
          readOnly: true
          selectByMouse: true
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.phoneQr !== null
          text: "Scan with the camera, then Share → Add to Home Screen"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        TextEdit {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(420)
          horizontalAlignment: TextEdit.AlignHCenter
          wrapMode: TextEdit.Wrap
          readOnly: true
          selectByMouse: true
          text: root.phoneQr ? root.phoneQr.footer : (root.phoneInvite ? "" : "")
          visible: text !== ""
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  ConfirmDialog {
    anchors.fill: parent
    opened: root.confirmDeleteFolder !== ""
    message: {
      var index = root.indexOfSource(Model.SOURCE_FOLDER, root.confirmDeleteFolder)
      var name = index >= 0 ? root.sourceItems[index].title : "this folder"
      return "Delete “" + name + "”? Its notes move to Notes, its subfolders up one level."
    }
    confirmText: "Delete"
    fontFamily: root.fontFamily
    onCanceled: root.confirmDeleteFolder = ""
    onConfirmed: {
      root.service.deleteFolder(root.confirmDeleteFolder)
      if (root.sourceKind === Model.SOURCE_FOLDER && root.sourceId === root.confirmDeleteFolder) {
        root.sourceKind = Model.SOURCE_ALL
        root.sourceId = ""
      }
      root.confirmDeleteFolder = ""
    }
  }
}
