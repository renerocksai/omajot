import QtQuick
import Quickshell
import qs.Commons
import "../Model.mjs" as Model

// Rendered markdown for one note. Images are lifted into their own segments
// and drawn by Image items (Qt's Markdown renderer paints nothing for file://
// images in the shell); task boxes are `task:<line>` links that ask the owner
// to toggle the checkbox in the source.
Flickable {
  id: root

  property string text: ""
  property string dataDir: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall

  signal taskToggled(int line)

  function hexOf(colour) {
    function channel(value) { return ("0" + Math.round(value * 255).toString(16)).slice(-2) }
    return "#" + channel(colour.r) + channel(colour.g) + channel(colour.b)
  }

  readonly property var segments: Model.splitPreview(root.text, root.dataDir)
  readonly property var styling: ({
    linkColor: hexOf(root.accent),
    textColor: hexOf(root.foreground),
    fontSizePx: root.fontSize,
    tableBorderColor: hexOf(Qt.darker(root.foreground, 2.2))
  })

  contentWidth: width
  contentHeight: column.implicitHeight
  clip: true
  boundsBehavior: Flickable.StopAtBounds
  interactive: contentHeight > height

  function scrollBy(panes) {
    var limit = Math.max(0, contentHeight - height)
    contentY = Math.max(0, Math.min(limit, contentY + height * panes))
  }

  Column {
    id: column
    width: root.width
    spacing: Style.space(8)

    Repeater {
      model: root.segments

      delegate: Item {
        id: segment
        required property var modelData
        readonly property bool isImage: segment.modelData.kind === "image"

        width: column.width
        implicitHeight: segment.isImage
          ? Math.max(segmentImage.height, segmentNotice.visible ? segmentNotice.implicitHeight : 0)
          : segmentText.implicitHeight
        height: implicitHeight

        Text {
          id: segmentText
          visible: !segment.isImage
          width: parent.width
          text: segment.isImage ? "" : Model.styleMarkdown(segment.modelData.text, root.styling)
          textFormat: Text.MarkdownText
          color: root.foreground
          linkColor: root.accent
          font.family: root.fontFamily
          font.pixelSize: root.fontSize
          wrapMode: Text.Wrap
          onLinkActivated: function(link) {
            var line = Model.taskLine(link)
            if (line >= 0) {
              root.taskToggled(line)
              return
            }
            var url = Model.externalLinkUrl(link)
            if (url !== "") Quickshell.execDetached(["xdg-open", url])
          }
          HoverHandler {
            cursorShape: segmentText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
          }
        }

        Image {
          id: segmentImage
          visible: segment.isImage && status === Image.Ready
          source: segment.isImage ? segment.modelData.url : ""
          asynchronous: true
          fillMode: Image.PreserveAspectFit
          width: implicitWidth > 0 ? Math.min(implicitWidth, parent.width) : 0
          height: implicitWidth > 0 ? Math.round(implicitHeight * (width / implicitWidth)) : 0
          // A decode bound, not a display size (see omajop).
          sourceSize.width: Model.MAX_IMAGE_PIXELS_PER_SIDE
          sourceSize.height: Model.MAX_IMAGE_PIXELS_PER_SIDE
          mipmap: true
          smooth: true
        }

        Text {
          id: segmentNotice
          visible: segment.isImage && segmentImage.status === Image.Error
          width: parent.width
          text: "Missing image" + (segment.isImage && segment.modelData.title ? ": " + segment.modelData.title : "")
          textFormat: Text.PlainText
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
