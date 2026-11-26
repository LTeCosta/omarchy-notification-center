import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Notification Center's shared half, built once however many bars there are.
// It reads the history Omarchy's notification service keeps in
// ~/.local/state/omarchy/notifications/history.json and its Do Not Disturb
// flag, owns the seen, cleared, read and removed marks in the plugin's own
// state file, calls the notification service (`omarchy-shell notifications …`)
// and answers the plugin's IPC target. Omarchy's files are only read.
//
// Each monitor's bar widget (Panel.qml) binds to this object and keeps only its
// own panel: the list's search, filter, cursor and the seen mark as it was when
// that panel opened. A widget registers here so `state` can report its panel
// and the history is reread more often while any panel is open.
Scope {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.ltecosta.notification-center"
  readonly property string home: Quickshell.env("HOME")
  readonly property string serviceDir: home + "/.local/state/omarchy/notifications"
  readonly property string stateDir: home + "/.local/state/omarchy/" + pluginId

  property var history: ({ entries: [], error: "" })
  property string historyText: "\u0000"
  property bool dnd: false
  property var marks: Model.emptyMarks()
  property bool stateDirReady: false
  property bool savePending: false
  // The widgets of every bar, and how many of their panels are open.
  property var panels: []
  property int openCount: 0
  // A reloaded plugin briefly overlaps its old service; register the IPC
  // target only after the old one has released it.
  property bool ipcReady: false

  readonly property var entries: history.entries
  readonly property var kept: Model.kept(entries, marks)
  readonly property int missed: Model.missedCount(entries, marks)
  // The notification service method still running, or "".
  readonly property string callMethod: serviceCall.running ? serviceCall.method : ""

  // A notification service call failed; `requester` is the widget that made it.
  signal callFailed(string method, var requester)

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

  // ---------- Panels ----------
  // A widget's object reads as gone once its bar is rebuilt.
  function livePanels() {
    return panels.filter(function(panel) { return panel && typeof panel.panelState === "function" })
  }

  function attach(panel) {
    var live = livePanels()
    if (live.indexOf(panel) < 0) live.push(panel)
    panels = live
    panelOpenChanged()
  }

  function detach(panel) {
    panels = livePanels().filter(function(known) { return known !== panel })
    panelOpenChanged()
  }

  // Called by a widget as its panel opens or closes.
  function panelOpenChanged() {
    openCount = livePanels().filter(function(panel) { return panel.opened === true }).length
  }

  // ---------- Own state ----------
  function saveMarks() {
    if (!stateDirReady) { savePending = true; return }
    savePending = false
    stateFile.setText(Model.serialiseState(marks))
  }

  // A panel opening or closing marks what is listed as seen.
  function markSeen() {
    var seen = Model.seenMark(entries, Date.now() / 1000)
    if (seen === marks.seenTs) return
    marks = Model.withMarks(marks, { seenTs: seen })
    saveMarks()
  }

  // The changes below return the marks from before them, for the panel's undo,
  // or null when there was nothing to change.
  function readAll(seenBefore) {
    if (!Model.canReadAll(entries, marks, seenBefore)) return null
    var previous = marks
    marks = Model.markAllRead(marks, entries)
    saveMarks()
    return previous
  }

  function hide(id) {
    if (typeof id !== "string" || id === "") return null
    var previous = marks
    marks = Model.hide(marks, id, entries)
    saveMarks()
    return previous
  }

  function clear() {
    if (kept.length === 0) return null
    var previous = marks
    marks = Model.clearAll(marks, entries)
    saveMarks()
    return previous
  }

  function restore(previous) {
    if (!previous) return
    marks = Model.restored(previous, marks)
    saveMarks()
  }

  // ---------- Notification service ----------
  function callService(method, requester) {
    if (serviceCall.running) return false
    serviceCall.method = method
    serviceCall.requester = requester || null
    serviceCall.command = ["omarchy-shell", "notifications", method]
    serviceCall.running = true
    return true
  }

  function toggleDnd(requester) { return callService("toggleDnd", requester) }
  function showHistory(requester) { return callService("showHistory", requester) }

  // ---------- IPC ----------
  // A target reaches only this one object, but the panel to open is the one on
  // the focused monitor: the shell routes summon, hide and toggle through the
  // bar to that monitor's widget.
  function shellPanel(action) {
    Quickshell.execDetached(["omarchy-shell", "shell", action, root.pluginId])
  }

  // Read all from a script acts as the button in an open panel, so that panel
  // offers its undo; with none open, it reads as a panel opening now.
  function readAllFromIpc() {
    var live = livePanels()
    var at = Model.reportingPanel(live.map(function(panel) { return panel.opened === true }))
    if (at >= 0 && live[at].opened === true) live[at].readAll()
    else readAll(marks.seenTs)
  }

  function stateIpc() {
    var live = livePanels()
    var at = Model.reportingPanel(live.map(function(panel) { return panel.opened === true }))
    return JSON.stringify(Model.stateReport({ opened: openCount > 0, entries: kept.length, missed: missed, dnd: dnd,
      error: history.error, marks: marks }, at >= 0 ? live[at].panelState() : null))
  }

  Component.onCompleted: makeStateDir.running = true

  Timer {
    interval: 150
    running: true
    onTriggered: root.ipcReady = true
  }

  ShellIpc {
    enabled: root.ipcReady
    target: root.pluginId
    function open(): void { root.shellPanel("summon") }
    function close(): void { root.shellPanel("hide") }
    function show(): void { root.shellPanel("summon") }
    function hide(): void { root.shellPanel("hide") }
    function toggle(): void { root.shellPanel("toggle") }
    function state(): string { return root.stateIpc() }
    function readAll(): string { root.readAllFromIpc(); return "ok" }
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

  // Only this object writes the marks, so the file is read once, at start.
  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    printErrors: false
    onLoaded: root.marks = Model.parseState(text())
  }

  // The notification service rewrites its files atomically; the watches follow
  // them, and a reread of a file that did not change costs nothing.
  Timer {
    interval: root.openCount > 0 ? 10000 : 30000
    running: true
    repeat: true
    onTriggered: root.refresh()
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
    property var requester: null
    stdout: StdioCollector { id: serviceOut; waitForEnd: true }
    onExited: function(exitCode, _exitStatus) {
      var method = serviceCall.method
      var requester = serviceCall.requester
      serviceCall.requester = null
      Qt.callLater(function() {
        if (exitCode !== 0) root.callFailed(method, requester)
        else if (method === "toggleDnd") root.dnd = serviceOut.text.trim() === "on"
        quietFile.reload()
      })
    }
  }
}
