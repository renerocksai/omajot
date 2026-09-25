import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "../Model.mjs" as Model

// The bar dropdown: the same notes view as the main window (NotesView.qml),
// sources │ notes │ editor, in a popout. `n` captures a new note, `o` opens
// the selected note in the main window.
Panel {
  id: root
  moduleName: "io.github.renerocksai.omajot"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root
  property real editorFontSize: Style.font.bodySmall

  // Quick capture: open the dropdown on a fresh, focused note.
  function capture() {
    if (!opened) open()
    view.capture()
  }

  onOpenedChanged: if (opened) view.show("{}")

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: view
    contentWidth: panel.fittedContentWidth(Style.space(1000))
    contentHeight: panel.fittedContentHeight(Style.space(600))

    NotesView {
      id: view
      anchors.fill: parent
      service: root.service
      active: root.opened
      showWindowButton: true
      contentMargin: 0
      sidebarWidth: Style.space(190)
      listWidth: Style.space(240)
      foreground: root.bar ? root.bar.foreground : Color.foreground
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      editorFontSize: root.editorFontSize
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onOpenWindowRequested: function(noteId) {
        root.close()
        if (root.hostWidget) root.hostWidget.openWindow(noteId)
      }
    }
  }
}
