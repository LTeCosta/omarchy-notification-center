import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Notification Center bar widget. Reads the history Omarchy's notification
// service keeps in ~/.local/state/omarchy/notifications/history.json, keeps its
// own seen, cleared and removed marks beside it, and acts through the
// service's IPC (`omarchy-shell notifications …`); Omarchy's files are only read.
Panel {
  id: root
  moduleName: "io.github.ltecosta.notification-center"
  ipcTarget: moduleName
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string serviceDir: home + "/.local/state/omarchy/notifications"
  readonly property string stateDir: home + "/.local/state/omarchy/" + moduleName

  property var history: ({ entries: [], error: "" })
  property string historyText: "\u0000"
  property bool dnd: false
  property var marks: Model.emptyMarks()
  property bool stateDirReady: false
  property bool savePending: false
  // The seen mark as it was when the panel opened: newer rows get a dot.
  property real seenBefore: 0
  // The marks before the last removal or clear, while it can be undone.
  property var undoMarks: null
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
  // A reloaded or moved widget briefly overlaps its old instance; register
  // the IPC target only after the old one has released it.
  property bool ipcReady: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var entries: history.entries
  readonly property var kept: Model.kept(entries, marks)
  readonly property int missed: Model.missedCount(entries, marks)
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

  function refresh() {
    historyFile.reload()
    quietFile.reload()
  }

  function readHistory(text) {
    // An unchanged file keeps the rows, so a periodic reread does not rebuild
    // them under the pointer.
    if (text === historyText) return
    historyText = text
    history = Model.parseHistory(text)
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

  // ---------- Own state ----------
  function saveMarks() {
    if (!stateDirReady) { savePending = true; return }
    savePending = false
    stateFile.setText(Model.serialiseState(marks))
  }

  function markSeen() {
    var seen = Math.max(Date.now() / 1000, entries.length ? entries[0].closedTs : 0)
    if (seen === marks.seenTs) return
    marks = Model.withMarks(marks, { seenTs: seen })
    saveMarks()
  }

  function removeEntry(entry) {
    if (!entry) return
    var index = navigationItems().indexOf(cursorItem)
    undoMarks = marks
    marks = Model.hide(marks, entry.id, entries)
    saveMarks()
    say("notice.removed", 0)
    keepCursorAt(index)
  }

  function clearList() {
    if (kept.length === 0) return
    var count = kept.length
    undoMarks = marks
    marks = Model.withMarks(marks, { clearedTs: entries[0].closedTs, hidden: [] })
    appFilter = ""
    saveMarks()
    say("notice.cleared", count)
    keepCursorAt(-1)
  }

  function undo() {
    if (!undoMarks) return
    marks = Model.withMarks(undoMarks, { seenTs: marks.seenTs })
    undoMarks = null
    saveMarks()
    say("", 0)
  }

  // ---------- Actions ----------
  function callService(method) {
    if (serviceCall.running) return
    serviceCall.method = method
    serviceCall.command = ["omarchy-shell", "notifications", method]
    serviceCall.running = true
  }

  function toggleDnd() { callService("toggleDnd") }

  function showOnScreen() {
    callService("showHistory")
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

  function scrollIntoView(item) {
    Qt.callLater(function() {
      if (!item) return
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
    else if (value >= "0" && value <= "9") {
      var values = filterValues()
      var index = Number(value)
      if (index < values.length) selectFilter(values[index])
    }
  }

  function stateIpc() {
    return JSON.stringify({ opened: opened, entries: kept.length, listed: rows.length, missed: missed, dnd: dnd,
      error: errorKey || history.error, filter: appFilter, query: query, search_focused: searchField.activeFocus,
      hidden: marks.hidden.length,
      cleared_ts: marks.clearedTs, seen_ts: marks.seenTs, seen_before: seenBefore, missed_at_open: missedAtOpen })
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
    if (opened) {
      tick()
      refresh()
      seenBefore = marks.seenTs
      expandedIds = ({})
      scroller.contentY = 0
    }
    // Opening marks what is listed as seen; closing marks what arrived meanwhile.
    markSeen()
  }

  onFiltersChanged: if (appFilter !== "" && !filters.some(function(filter) { return filter.app === appFilter })) appFilter = ""

  Component.onCompleted: makeStateDir.running = true

  Timer {
    interval: 150
    running: true
    onTriggered: root.ipcReady = true
  }

  ShellIpc {
    enabled: root.ipcReady
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function state(): string { return root.stateIpc() }
  }

  FileView {
    id: historyFile
    path: root.serviceDir + "/history.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readHistory(text())
    onLoadFailed: root.readHistory("")
  }

  FileView {
    id: quietFile
    path: root.serviceDir + "/quiet.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.dnd = Model.parseQuiet(text())
    onLoadFailed: root.dnd = false
  }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    // Every bar (one per monitor) has its own panel; the file keeps their
    // marks, and so their badges, the same.
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.marks = Model.parseState(text())
  }

  // The service rewrites its files atomically; the watch follows them, and a
  // reread of a file that did not change costs nothing.
  Timer {
    interval: root.opened ? 10000 : 30000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.tick()
  }

  Process {
    id: makeStateDir
    command: ["mkdir", "-p", "-m", "0700", root.stateDir]
    onExited: function(exitCode, _exitStatus) {
      root.stateDirReady = exitCode === 0
      if (root.stateDirReady && root.savePending) root.saveMarks()
    }
  }

  Process {
    id: serviceCall
    property string method: ""
    stdout: StdioCollector { id: serviceOut; waitForEnd: true }
    onExited: function(exitCode, _exitStatus) {
      Qt.callLater(function() {
        if (exitCode !== 0) root.fail("error.service")
        else if (serviceCall.method === "toggleDnd") root.dnd = serviceOut.text.trim() === "on"
        quietFile.reload()
      })
    }
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
    labelText: root.setting("barLabel", "Missed") === "Missed" && root.missed > 0
      ? Commons.I18n.formatNumber(root.missed) : ""
    tooltipText: root.tooltip()
    active: root.missed > 0 || root.dnd
    activeColor: Color.accent
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.toggleDnd()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(720))

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
        anchors.fill: parent
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
                  busy: serviceCall.running && serviceCall.method === "toggleDnd"
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
                  reasonText: entry.missed ? strings.t("reason." + entry.reason) : ""
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

          PanelSeparator { foreground: root.foreground }

          // ---------- Actions ----------
          Row {
            id: actions
            width: parent.width
            spacing: Style.space(6)
            readonly property real buttonWidth: (width - spacing) / 2

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
}
