import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One notification from history, and a keyboard cursor stop. A click opens
// it; the buttons that appear under the cursor expand or remove it. Every
// string in `entry` comes from the sender, so every Text here is plain.
CursorSurface {
  id: row

  required property var entry
  property bool fresh: false
  property bool expanded: false
  property string timeText: ""
  property string reasonText: ""
  property string expandTooltip: ""
  property string removeTooltip: ""
  property string freshTooltip: ""
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  readonly property bool keyboardEnabled: visible
  readonly property bool expandable: body.truncated || summary.truncated || row.expanded
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property real slot: Style.space(28)
  readonly property real pad: Style.space(8)

  signal activated()
  signal expandRequested()
  signal removeRequested()
  signal pointerEntered()

  function keyboardActivate() { row.activated() }

  implicitHeight: Math.max(slot, column.implicitHeight) + pad * 2

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: row.pointerEntered()
    onClicked: row.activated()
  }

  Item {
    id: icon
    x: row.pad
    y: row.pad
    width: row.slot
    height: row.slot

    Image {
      id: picture
      anchors.fill: parent
      source: row.entry.appIcon ? Quickshell.iconPath(row.entry.appIcon, true) : ""
      sourceSize.width: row.slot * 2
      sourceSize.height: row.slot * 2
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      visible: status === Image.Ready
    }

    Text {
      anchors.centerIn: parent
      visible: !picture.visible && row.entry.glyph !== ""
      textFormat: Text.PlainText
      text: row.entry.glyph
      color: row.entry.critical ? row.urgent : row.foreground
      font.family: Model.omarchyGlyph(row.entry.glyph) ? "omarchy" : row.fontFamily
      font.pixelSize: Style.font.heading
    }

    Rectangle {
      anchors.fill: parent
      visible: !picture.visible && row.entry.glyph === ""
      radius: Style.cornerRadius > 0 ? width / 2 : 0
      color: Qt.rgba(row.foreground.r, row.foreground.g, row.foreground.b, 0.12)

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: Model.initial(row.entry.app)
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }
  }

  Column {
    id: column
    x: icon.x + icon.width + Style.space(10)
    y: row.pad
    width: row.width - x - row.pad
    spacing: Style.space(2)

    Item {
      width: parent.width
      implicitHeight: Math.max(appText.implicitHeight, tools.height)

      Text {
        id: appText
        anchors.left: parent.left
        anchors.right: meta.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: row.entry.app
        color: row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      // Time and tags at rest; the row's buttons take their place under the cursor.
      Row {
        id: meta
        visible: !row.hasCursor
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Text {
          visible: row.reasonText !== ""
          textFormat: Text.PlainText
          text: row.reasonText
          color: Color.accent
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          text: row.timeText
          color: row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          visible: row.fresh
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(6)
          height: width
          radius: width / 2
          color: Color.accent

          HoverHandler { id: freshHover }
          PanelToolTip {
            visible: freshHover.hovered && row.freshTooltip !== ""
            text: row.freshTooltip
          }
        }
      }

      Row {
        id: tools
        visible: row.hasCursor
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          rightPadding: Style.space(4)
          textFormat: Text.PlainText
          text: row.timeText
          color: row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          visible: row.expandable
          iconText: row.expanded ? "󰅃" : "󰅀"
          tooltipText: row.expandTooltip
          foreground: row.foreground
          fontFamily: row.fontFamily
          fontSize: Style.font.bodySmall
          onHovered: function(on) { if (on) row.pointerEntered() }
          onClicked: row.expandRequested()
        }

        PanelActionButton {
          iconText: "󰅖"
          tooltipText: row.removeTooltip
          foreground: row.foreground
          hoverColor: row.urgent
          fontFamily: row.fontFamily
          fontSize: Style.font.bodySmall
          onHovered: function(on) { if (on) row.pointerEntered() }
          onClicked: row.removeRequested()
        }
      }
    }

    Text {
      id: summary
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      text: row.entry.summary
      color: row.entry.critical ? row.urgent : row.foreground
      font.family: row.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      wrapMode: Text.Wrap
      maximumLineCount: row.expanded ? 6 : 2
      elide: Text.ElideRight
    }

    Text {
      id: body
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      text: row.entry.body
      color: row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
      maximumLineCount: row.expanded ? 16 : 2
      elide: Text.ElideRight
    }
  }
}
