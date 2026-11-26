import QtQuick

// Stand-in for the kit's KeyboardPanel in service.smoke.sh: the offscreen
// platform has no layer-shell backend, so the panel's content is built in a
// plain item with the properties Panel.qml sets.
Item {
  property Item anchorItem: null
  property var owner: null
  property var bar: null
  property bool open: false
  property Item focusTarget: null
  property real contentWidth: 420
  property real contentHeight: 720
  width: contentWidth
  height: contentHeight
  function fittedContentWidth(wanted) { return wanted }
  function fittedContentHeight(wanted, most) { return Math.min(wanted, most) }
}
