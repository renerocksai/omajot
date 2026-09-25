import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// omajot in the bar: a note icon. Click for the quick-notes dropdown,
// middle-click for the main window. The service (Service.qml) owns the daemon
// and all data; this widget owns the settings and hands them over.
BarWidget {
  id: root
  moduleName: "io.github.renerocksai.omajot"

  readonly property var service: bar && bar.shell
    ? bar.shell.firstPartyServiceFor(Model.PLUGIN_ID) : null

  // Empty: the daemon reads "hub" from ~/.config/omajot/config.json (Service normalizes the rest).
  readonly property string hubUrl: String(setting("hubUrl", "") || "")
  readonly property string dataDir: String(setting("dataDir", ""))
  readonly property string daemonPath: String(setting("daemonPath", ""))
  readonly property string previewMode: {
    var mode = String(setting("previewMode", "split"))
    return ["split", "source", "preview"].indexOf(mode) >= 0 ? mode : "split"
  }
  readonly property real editorFontSize: {
    var size = Number(setting("fontSize", 0))
    return isFinite(size) && size >= 6 && size <= 40 ? size : Style.font.bodySmall
  }

  function pushSettings() {
    if (!service) return
    service.previewMode = previewMode
    service.editorFontSize = Number(setting("fontSize", 0)) >= 6 ? editorFontSize : 0
    service.configure(hubUrl, dataDir, daemonPath)
  }

  onServiceChanged: pushSettings()
  onSettingsChanged: Qt.callLater(root.pushSettings)

  // --- dropdown plumbing (the shape the bar host expects) ----------------------

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (opened) close(); else open() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function capture() { if (panelLoader.item) panelLoader.item.capture() }

  // The main window is the plugin's `panel` entry point, summoned by the host.
  function openWindow(noteId) {
    if (!bar || !bar.shell) return
    bar.shell.summon(Model.PLUGIN_ID, JSON.stringify({ note: String(noteId || "") }))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: Math.max(
    icon.tightWidth, Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  readonly property string tooltipLine: {
    if (!service) return "omajot"
    if (service.daemonState === "missing") return "omajot: daemon binary not found"
    var count = Model.notesForSource(service.notes, Model.SOURCE_ALL, "", []).length
    return count + (count === 1 ? " note" : " notes") + " · " + service.syncText
      + "\nClick: quick notes · Middle-click: open omajot"
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("qml/QuickPanel.qml")
    visible: false
    onLoaded: {
      item.bar = Qt.binding(function() { return root.bar })
      item.settings = Qt.binding(function() { return root.settings })
      item.service = Qt.binding(function() { return root.service })
      item.editorFontSize = Qt.binding(function() { return root.editorFontSize })
      item.anchorItem = button
      item.hostWidget = root
    }
  }

  IpcHandler {
    target: "io.github.renerocksai.omajot"

    function toggle(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function capture(): void { root.capture() }
    function window(): void { root.openWindow("") }
    function state(): string {
      if (!root.service) return "{}"
      return JSON.stringify({
        daemon: root.service.daemonState, sync: root.service.syncState,
        pending: root.service.syncPending, notes: root.service.notes.length,
        error: root.service.lastError
      })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.service || root.service.daemonState !== "ready"
    active: root.service && (root.service.daemonState === "crashed" || root.service.daemonState === "missing")
    useActiveColor: true
    fixedWidth: !vertical ? Style.bar.iconSlot : -1
    fixedHeight: vertical ? Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.tooltipLine

    OpticalGlyph {
      id: icon
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
      text: Model.GLYPH.note
      fontFamily: button.fontFamily
      fontSize: Style.bar.iconFont
      color: button.foreground
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.openWindow("")
      else root.togglePanel()
    }
  }

  Component.onCompleted: Qt.callLater(root.pushSettings)
}
