import QtQuick
import qs.Commons
import "../Model.mjs" as Model

// One note in a list: title, then time and snippet, with pin and tags.
Rectangle {
  id: root

  property var note: null
  property date now: new Date()
  property bool selected: false
  property bool dimmed: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal clicked()
  signal doubleClicked()

  readonly property color muted: Qt.darker(root.foreground, 1.5)

  height: Style.space(46)
  radius: Style.cornerRadius
  color: {
    if (root.selected) return Style.selectedFillFor(root.foreground, root.accent)
    if (mouse.containsMouse) return Style.hoverFillFor(root.foreground, root.accent)
    return "transparent"
  }

  Text {
    id: glyph
    anchors.left: parent.left
    anchors.leftMargin: Style.space(6)
    anchors.top: parent.top
    anchors.topMargin: Style.space(6)
    width: Style.space(12)
    text: root.note && root.note.pinned ? Model.GLYPH.pin : ""
    color: root.note && root.note.pinned ? root.accent : root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Text {
    id: title
    anchors.left: glyph.right
    anchors.leftMargin: Style.space(6)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.top: parent.top
    anchors.topMargin: Style.space(5)
    text: Model.noteTitle(root.note)
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.dimmed ? root.muted : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  Text {
    anchors.left: title.left
    anchors.right: title.right
    anchors.top: title.bottom
    anchors.topMargin: Style.space(2)
    text: {
      if (!root.note) return ""
      var parts = [Model.formatUpdated(root.note.updated, root.now)]
      if (root.note.snippet) parts.push(Model.plainLine(root.note.snippet))
      else if ((root.note.tags || []).length > 0) parts.push("#" + root.note.tags.join(" #"))
      return parts.join("  ")
    }
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    onClicked: root.clicked()
    onDoubleClicked: root.doubleClicked()
  }
}
