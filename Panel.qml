import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Notification Center bar widget, one per monitor's bar. The history, the
// marks, Do Not Disturb and the IPC target belong to the plugin's service
// (Service.qml), built once for every bar; this widget keeps the bell and its
// own panel: search, filter, cursor, expanded rows and the seen mark as it was
// when the panel opened. Without the service it shows an empty list and sends
// its actions over IPC.
Panel {
  id: root
  moduleName: "io.github.ltecosta.notification-center"
  // The service answers the plugin's IPC target.
  manageIpc: false

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  // The service this widget registered with, to leave it when either goes.
  property var attachedService: null

  readonly property var history: service ? service.history : ({ entries: [], error: "" })
  readonly property bool dnd: service ? service.dnd : false
  readonly property var marks: service ? service.marks : Model.emptyMarks()
  // The seen mark as it was when the panel opened: newer rows get a dot.
  property real seenBefore: 0
  // The marks before the last removal, clear or read all, while it can be undone.
  property var undoMarks: null
  property real undoSeenBefore: 0
  property real now: Date.now() / 1000
  property real todayStart: startOfToday()
  property string appFilter: ""
  property string query: ""
  property var expandedIds: ({})
  property string noticeKey: ""
  property int noticeCount: 0
  property string errorKey: ""
  property bool cursorActive: false
  property var cursorItem: null
  // Enter and Space both arrive as activateRequested; Enter says so first.
  property bool enterPressed: false
  property bool wasOpened: false
  // The search field holds the keyboard only after / or a click on it.
  property bool searchWanted: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var entries: history.entries
  readonly property var kept: service ? service.kept : []
  readonly property int missed: service ? service.missed : 0
  readonly property int missedAtOpen: Model.missedCount(entries, Model.withMarks(marks, { seenTs: seenBefore }))
  readonly property var filters: Model.appFilters(kept)
  readonly property var rows: Model.listed(entries, marks, appFilter, query, seenBefore, todayStart)
  readonly property var filterOptions: [{ value: "", label: strings.t("filter.all") + "  " + Commons.I18n.formatNumber(kept.length) }]
    .concat(filters.map(function(filter) {
      return { value: filter.app, label: filter.label + "  " + Commons.I18n.formatNumber(filter.count),
        tooltip: strings.t("filter.tooltip").arg(filter.app).arg(Commons.I18n.formatNumber(filter.count)) }
    }))

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function startOfToday() {
    var day = new Date()
    day.setHours(0, 0, 0, 0)
    return day.getTime() / 1000
  }

  function tick() {
    now = Date.now() / 1000
    todayStart = startOfToday()
  }

  // The plugin's IPC target, which the service answers, for when this bar
  // cannot reach the service directly.
  function ipc(args) { Quickshell.execDetached(["omarchy-shell", root.moduleName].concat(args)) }

  function attachService() {
    if (attachedService === service) return
    if (attachedService && typeof attachedService.detach === "function") attachedService.detach(root)
    attachedService = service
    if (attachedService) attachedService.attach(root)
  }

  function agoText(ts) {
    var ago = Model.ago(ts, now)
    return ago.key === "time.now" ? strings.t(ago.key)
      : strings.tn(ago.key, ago.count).arg(Commons.I18n.formatNumber(ago.count))
  }

  function heroMeta() {
    if (kept.length === 0) return strings.t("hero.empty")
    var meta = strings.tn("hero.count", kept.length).arg(Commons.I18n.formatNumber(kept.length))
    var count = opened ? missedAtOpen : missed
    return count > 0 ? meta + " · " + strings.tn("hero.missed", count).arg(Commons.I18n.formatNumber(count)) : meta
  }

  function tooltip() {
    var lines = [missed > 0 ? strings.tn("tooltip.missed", missed).arg(Commons.I18n.formatNumber(missed)) : strings.t("tooltip.idle")]
    if (dnd) lines.push(strings.t("tooltip.dnd"))
    lines.push(strings.t("tooltip.clicks"))
    return lines.join("\n")
  }

  function emptyText() {
    if (query.trim() !== "") return strings.t("empty.search").arg(query.trim())
    if (appFilter !== "") return strings.t("empty.app").arg(appFilter)
    return strings.t("empty.all")
  }

  function say(key, count) {
    errorKey = ""
    noticeKey = key
    noticeCount = count || 0
  }

  function fail(key) {
    noticeKey = ""
    errorKey = key
  }

  // ---------- Marks ----------
  // The service changes the shared marks and hands back the ones from before,
  // which this panel keeps for its undo.
  function rememberUndo(previous) {
    undoMarks = previous
    undoSeenBefore = seenBefore
  }

  function readAll() {
    if (!service) { ipc(["readAll"]); return }
    var previous = service.readAll(seenBefore)
    if (!previous) return
    rememberUndo(previous)
    seenBefore = Math.max(seenBefore, marks.readTs)
    say("notice.read", 0)
  }

  function removeEntry(entry) {
    if (!entry || !service) return
    var index = navigationItems().indexOf(cursorItem)
    var previous = service.hide(entry.id)
    if (!previous) return
    rememberUndo(previous)
    say("notice.removed", 0)
    keepCursorAt(index)
  }

  function clearList() {
    if (!service || kept.length === 0) return
    var count = kept.length
    var previous = service.clear()
    if (!previous) return
    rememberUndo(previous)
    appFilter = ""
    say("notice.cleared", count)
    keepCursorAt(-1)
  }

  function undo() {
    if (!undoMarks) return
    if (service) service.restore(undoMarks)
    seenBefore = undoSeenBefore
    undoMarks = null
    say("", 0)
  }

  // ---------- Actions ----------
  // Without the service, Omarchy's notification service is called directly.
  function toggleDnd() {
    if (service) service.toggleDnd(root)
    else Quickshell.execDetached(["omarchy-shell", "notifications", "toggleDnd"])
  }

  function showOnScreen() {
    if (service) service.showHistory(root)
    else Quickshell.execDetached(["omarchy-shell", "notifications", "showHistory"])
    close()
  }

  // The open windows decide where it goes, so ask Hyprland for them first.
  function openEntry(entry) {
    if (!entry || opener.running) return
    opener.entry = entry
    opener.running = true
  }

  function openTarget(entry, clientsJson) {
    var target = Model.openTarget(entry, Model.parseClients(clientsJson))
    if (!target) { say("notice.nothing", 0); return }
    if (target.kind === "exec") Util.execArgv(target.argv)
    else if (target.kind === "window")
      Hyprland.dispatch('hl.dsp.focus({window = hl.get_window("address:' + target.address + '")})')
    else if (target.kind === "url") Qt.openUrlExternally(target.url)
    else if (target.kind === "app") Quickshell.execDetached(target.argv)
    close()
  }

  function toggleExpanded(id) {
    var next = {}
    for (var key in expandedIds) if (key !== id) next[key] = true
    if (!expandedIds[id]) next[id] = true
    expandedIds = next
  }

  function selectFilter(app) {
    if (app !== "" && !filters.some(function(filter) { return filter.app === app })) return
    appFilter = app
    keepCursorAt(-1)
  }

  function filterValues() { return filterOptions.map(function(option) { return option.value }) }

  function focusSearch() {
    cursorActive = false
    cursorItem = null
    searchWanted = true
    searchField.forceActiveFocus()
  }

  function leaveSearch(toList) {
    searchWanted = false
    keyCatcher.forceActiveFocus()
    if (!toList) return
    var items = navigationItems()
    for (var i = 0; i < items.length; i++)
      if (items[i].entry) { setCursor(items[i]); scrollIntoView(items[i]); return }
  }

  // ---------- Keyboard cursor ----------
  // Every visible item that defines keyboardEnabled and keyboardActivate is a
  // stop, in declaration order; h/l call keyboardAdjust.
  function navigationItems() {
    var items = []
    collect(content, items)
    collect(footerArea, items)
    return items
  }

  function collect(item, items) {
    if (!item || item.visible !== true) return
    if (item.keyboardEnabled !== undefined && typeof item.keyboardActivate === "function") {
      if (item.keyboardEnabled === true) items.push(item)
      return
    }
    for (var i = 0; i < item.children.length; i++) collect(item.children[i], items)
  }

  function setCursor(item) {
    if (!item || item.keyboardEnabled !== true) return
    cursorActive = true
    cursorItem = item
  }

  // After the list changes, keep the cursor where it was, on the row that
  // took the place of a removed one, or on the first stop.
  function keepCursorAt(index) {
    Qt.callLater(function() {
      if (!cursorActive) return
      var items = navigationItems()
      if (items.indexOf(cursorItem) >= 0) return
      cursorItem = items.length ? items[Math.max(0, Math.min(index, items.length - 1))] : null
      if (!cursorItem) cursorActive = false
    })
  }

  function moveCursor(dx, dy) {
    var items = navigationItems()
    if (!items.length) return
    if (dy === 0) {
      if (cursorActive && cursorItem && typeof cursorItem.keyboardAdjust === "function")
        cursorItem.keyboardAdjust(dx)
      return
    }
    if (!cursorActive || items.indexOf(cursorItem) < 0) {
      setCursor(dy < 0 ? items[items.length - 1] : items[0])
      return
    }
    var next = Math.max(0, Math.min(items.length - 1, items.indexOf(cursorItem) + dy))
    setCursor(items[next])
    scrollIntoView(items[next])
  }

  function inList(item) {
    for (var parentItem = item; parentItem; parentItem = parentItem.parent)
      if (parentItem === content) return true
    return false
  }

  function scrollIntoView(item) {
    Qt.callLater(function() {
      if (!item || !inList(item)) return
      var top = item.mapToItem(scroller.contentItem, 0, 0).y
      var margin = Style.space(6)
      if (top < scroller.contentY + margin) scroller.contentY = Math.max(0, top - margin)
      else if (top + item.height > scroller.contentY + scroller.height - margin)
        scroller.contentY = Math.min(Math.max(0, scroller.contentHeight - scroller.height),
          top + item.height + margin - scroller.height)
    })
  }

  function activateCursor() {
    var enter = enterPressed
    enterPressed = false
    if (!cursorActive || !cursorItem) return
    // Space on a row expands it; Enter, like a click, opens it.
    if (cursorItem.entry && !enter) toggleExpanded(cursorItem.entry.id)
    else cursorItem.keyboardActivate()
  }

  function textKey(value) {
    if (value === "/") focusSearch()
    else if (value === "d" || value === "D") toggleDnd()
    else if (value === "r" || value === "R") showOnScreen()
    else if (value === "u" || value === "U") undo()
    else if (value === "a" || value === "A") readAll()
    else if (value >= "0" && value <= "9") {
      var values = filterValues()
      var index = Number(value)
      if (index < values.length) selectFilter(values[index])
    }
  }

  // This panel's part of the service's `state` IPC answer.
  function panelState() {
    return { listed: rows.length, error: errorKey, filter: appFilter, query: query,
      searchFocused: searchField.activeFocus, seenBefore: seenBefore, missedAtOpen: missedAtOpen }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    // The handler also runs as the widget is built, closed; that is no look.
    var shown = wasOpened !== opened
    wasOpened = opened
    if (!shown) return
    cursorActive = false
    cursorItem = null
    noticeKey = ""
    errorKey = ""
    undoMarks = null
    searchField.text = ""
    searchWanted = false
    if (service) service.panelOpenChanged()
    if (opened) {
      tick()
      if (service) service.refresh()
      seenBefore = marks.seenTs
      expandedIds = ({})
      scroller.contentY = 0
    }
    // Opening marks what is listed as seen; closing marks what arrived meanwhile.
    if (service) service.markSeen()
  }

  onServiceChanged: attachService()
  Component.onCompleted: attachService()
  Component.onDestruction: if (attachedService && typeof attachedService.detach === "function") attachedService.detach(root)

  Connections {
    target: root.service
    function onCallFailed(_method, requester) { if (requester === root) root.fail("error.service") }
  }

  onFiltersChanged: if (appFilter !== "" && !filters.some(function(filter) { return filter.app === appFilter })) appFilter = ""

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.tick()
  }

  Process {
    id: opener
    property var entry: null
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector { id: clientsOut; waitForEnd: true }
    onExited: function(exitCode, _exitStatus) {
      Qt.callLater(function() { root.openTarget(opener.entry, exitCode === 0 ? clientsOut.text : "[]") })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barIcon(root.missed, root.dnd)
    // A vertical bar has no room beside the bell; the tooltip still counts.
    labelText: vertical ? "" : Model.barLabel(root.missed, root.setting("barLabel", "Missed") === "Missed",
      function(count) { return Commons.I18n.formatNumber(count) })
    // The slot widens by the number and its gap so it never covers its neighbours.
    slotSize: Style.bar.iconSlot + (labelText !== "" ? Math.ceil(countMetrics.advanceWidth) + Style.space(4) : 0)
    tooltipText: root.tooltip()
    active: root.missed > 0 || root.dnd
    activeColor: Color.accent
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.toggleDnd()
      else if (buttonCode === Qt.RightButton) root.readAll()
      else root.toggle()
    }
  }

  TextMetrics {
    id: countMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: button.labelText
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight + Style.space(10) + footerArea.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onReturnRequested: root.enterPressed = true
      onActivateRequested: root.activateCursor()
      onDeleteRequested: if (root.cursorActive && root.cursorItem && root.cursorItem.entry) root.removeEntry(root.cursorItem.entry)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(value) { root.textKey(value) }

      Flickable {
        id: scroller
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: footerArea.top
        anchors.bottomMargin: Style.space(10)
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: scroller.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: strings.t("title")
            meta: root.heroMeta()
            foreground: root.foreground; fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.barIcon(root.opened ? root.missedAtOpen : root.missed, root.dnd)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                id: dndRow
                readonly property bool keyboardEnabled: true
                function keyboardActivate() { root.toggleDnd() }
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: strings.t("dnd.label")
                  color: root.dnd ? Color.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                ToggleSwitch {
                  id: dndSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.dnd
                  busy: root.service ? root.service.callMethod === "toggleDnd" : false
                  hasCursor: root.cursorItem === dndRow
                  foreground: root.foreground
                  onToggled: root.toggleDnd()
                  onHovered: function(on) { if (on) root.setCursor(dndRow) }

                  PanelToolTip {
                    visible: dndSwitch.containsMouse
                    text: root.dnd ? strings.t("dnd.on") : strings.t("dnd.off")
                  }
                }
              }
            }
          }

          // ---------- Search ----------
          TextField {
            id: searchField
            visible: root.kept.length > 0 || text !== ""
            width: parent.width
            placeholderText: strings.t("search.placeholder")
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            onTextChanged: root.query = text
            // Typing belongs to the panel's shortcuts until / or a click asks
            // for the search; focus that reaches the field any other way, as
            // when the panel opens, goes back to them.
            onPressed: root.searchWanted = true
            onActiveFocusChanged: {
              if (activeFocus && !root.searchWanted) Qt.callLater(function() { root.leaveSearch(false) })
              else if (!activeFocus) root.searchWanted = false
            }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (text !== "") text = ""
                else root.leaveSearch(false)
                event.accepted = true
              } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return
                  || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) {
                root.leaveSearch(true)
                event.accepted = true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: root.errorKey !== "" ? strings.t(root.errorKey)
              : root.history.error !== "" ? strings.t(root.history.error)
              : root.noticeKey === "" ? ""
              : root.noticeKey === "notice.cleared"
                ? strings.tn(root.noticeKey, root.noticeCount).arg(Commons.I18n.formatNumber(root.noticeCount))
                : strings.t(root.noticeKey)
            color: root.errorKey !== "" || root.history.error !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- App filter ----------
          // Chips wrap onto a second line rather than run past the panel.
          Flow {
            id: filterRow
            visible: root.filters.length > 0
            width: parent.width
            spacing: Style.space(6)
            readonly property bool keyboardEnabled: visible
            function keyboardActivate() {}
            function keyboardAdjust(direction) {
              var values = root.filterValues()
              var index = values.indexOf(root.appFilter) + direction
              if (index >= 0 && index < values.length) root.selectFilter(values[index])
            }

            Repeater {
              model: root.filterOptions

              delegate: Button {
                required property var modelData
                required property int index
                bordered: true
                selected: root.appFilter === modelData.value
                text: modelData.label
                tooltipText: modelData.tooltip || ""
                hasCursor: root.cursorItem === filterRow && selected
                foreground: root.foreground; fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onHovered: function(on) { if (on) root.setCursor(filterRow) }
                onClicked: root.selectFilter(modelData.value)
              }
            }
          }

          // ---------- Notifications ----------
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.rows.length > 0

            Repeater {
              model: root.rows

              delegate: Column {
                id: group
                required property var modelData
                width: parent.width
                spacing: Style.space(4)

                PanelSectionHeader {
                  visible: group.modelData.firstOfDay
                  topPadding: Style.space(4)
                  text: strings.t("day." + group.modelData.day)
                  foreground: root.foreground; fontFamily: root.fontFamily
                }

                EntryRow {
                  id: entryRow
                  width: parent.width
                  entry: group.modelData.entry
                  fresh: group.modelData.fresh
                  expanded: root.expandedIds[entry.id] === true
                  timeText: root.agoText(entry.ts)
                  reasonText: group.modelData.unread ? strings.t("reason." + entry.reason) : ""
                  expandTooltip: expanded ? strings.t("entry.collapse") : strings.t("entry.expand")
                  removeTooltip: strings.t("entry.remove")
                  freshTooltip: strings.t("entry.new")
                  urgent: root.urgent
                  foreground: root.foreground; fontFamily: root.fontFamily
                  hasCursor: root.cursorItem === entryRow
                  onPointerEntered: root.setCursor(entryRow)
                  onActivated: root.openEntry(entry)
                  onExpandRequested: root.toggleExpanded(entry.id)
                  onRemoveRequested: root.removeEntry(entry)
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.rows.length === 0
            width: parent.width
            topPadding: Style.space(8)
            bottomPadding: Style.space(8)
            horizontalAlignment: Text.AlignHCenter
            text: root.emptyText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }

      // Always in view below the list, however long it grows.
      Column {
        id: footerArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(10)

        PanelSeparator { foreground: root.foreground }

        // ---------- Actions ----------
        Row {
          id: actions
          width: parent.width
          spacing: Style.space(6)
          readonly property real buttonWidth: (width - spacing * 2) / 3

          Button {
            id: showButton
            readonly property bool keyboardEnabled: visible && enabled
            function keyboardActivate() { root.showOnScreen() }
            width: actions.buttonWidth
            bordered: true
            text: strings.t("action.show")
            iconText: "󰋚"
            tooltipText: strings.t("action.show.tooltip")
            enabled: root.entries.length > 0
            hasCursor: root.cursorItem === showButton
            foreground: root.foreground; fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onHovered: function(on) { if (on) root.setCursor(showButton) }
            onClicked: root.showOnScreen()
          }

          Button {
            id: readButton
            readonly property bool keyboardEnabled: visible && enabled
            function keyboardActivate() { root.readAll() }
            width: actions.buttonWidth
            bordered: true
            text: strings.t("action.read")
            iconText: "󰸞"
            tooltipText: strings.t("action.read.tooltip")
            enabled: Model.canReadAll(root.entries, root.marks, root.seenBefore)
            hasCursor: root.cursorItem === readButton
            foreground: root.foreground; fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onHovered: function(on) { if (on) root.setCursor(readButton) }
            onClicked: root.readAll()
          }

          Button {
            id: clearButton
            readonly property bool undoing: root.undoMarks !== null
            readonly property bool keyboardEnabled: visible && enabled
            function keyboardActivate() { undoing ? root.undo() : root.clearList() }
            width: actions.buttonWidth
            bordered: true
            text: undoing ? strings.t("action.undo") : strings.t("action.clear")
            iconText: undoing ? "󰕌" : "󰎟"
            tooltipText: undoing ? strings.t("action.undo.tooltip") : strings.t("action.clear.tooltip")
            enabled: undoing || root.kept.length > 0
            hasCursor: root.cursorItem === clearButton
            foreground: root.foreground; fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onHovered: function(on) { if (on) root.setCursor(clearButton) }
            onClicked: keyboardActivate()
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: strings.t("footer")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
