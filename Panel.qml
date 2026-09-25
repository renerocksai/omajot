import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.mjs" as Model
import "qml"

// The omajot main window: a normal Hyprland window around the notes view
// (qml/NotesView.qml), summoned by the host (`omarchy-shell` panel kind) from
// the bar, IPC, or a keybinding.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false
  property bool closingFromHost: false

  readonly property string pluginId: Model.PLUGIN_ID

  function open(payloadJson) {
    opened = true
    view.show(payloadJson)
  }

  function close() {
    closingFromHost = true
    opened = false
    Qt.callLater(function() { root.closingFromHost = false })
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else opened = false
  }

  FloatingWindow {
    id: window
    visible: root.opened
    title: "omajot"
    color: Color.background
    implicitWidth: 1180
    implicitHeight: 760
    minimumSize: Qt.size(760, 480)

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

    NotesView {
      id: view
      anchors.fill: parent
      focus: true
      service: root.service
      active: root.opened
      onCloseRequested: root.requestClose()
    }
  }
}
