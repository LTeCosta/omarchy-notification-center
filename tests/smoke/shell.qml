import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "ServiceLink.js" as ServiceLink

// Driver for service.smoke.sh: one Service and two bar widgets (two monitors)
// on stand-in bars that reach it through shell.serviceFor, a widget on a
// stand-in replacement bar whose shell has no services, and a second Service
// standing for a reload; a fake omarchy-shell first on PATH. Prints "SMOKE ok - ..." or "SMOKE not ok - ..."
// per assertion and "SMOKE done <failures>" at the end.
ShellRoot {
  id: root

  readonly property string pluginId: "io.github.ltecosta.notification-center"
  readonly property string fakeDir: Quickshell.env("FAKE_DIR")
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/" + pluginId
  readonly property real now: Number(Quickshell.env("SMOKE_NOW"))

  property int failures: 0
  property int step: -1
  property string stepName: ""
  property var waiting: null
  property var waitDeadline: 0
  property real seenAtClose: 0
  property var bare: null
  property var fresh: null

  Service { id: service }

  Component {
    id: barComponent
    QtObject {
      property var target: null
      property QtObject shell: QtObject {
        property var lookup: null
        function serviceFor(id) { return lookup && id === root.pluginId ? lookup.target : null }
      }
      property color foreground: "white"
      property color barForeground: "white"
      property color urgent: "red"
      property string fontFamily: "sans-serif"
      property bool vertical: false
      property int barSize: 30
      property bool foregroundAnimationEnabled: false
      function showTooltip(_item, _text) {}
      function hideTooltip(_item) {}
      function switchPanelFrom(_item, _direction) { return false }
      Component.onCompleted: shell.lookup = this
    }
  }

  Component {
    id: serviceComponent
    Service { }
  }

  Component {
    id: panelComponent
    Panel { }
  }

  property var leftBar: barComponent.createObject(root, { target: service })
  property var rightBar: barComponent.createObject(root, { target: service })
  property var bareBar: barComponent.createObject(root, { target: null })
  property var left: panelComponent.createObject(root, { bar: leftBar })
  property var right: panelComponent.createObject(root, { bar: rightBar })

  function check(condition, message) {
    if (!condition) failures++
    console.log("SMOKE " + (condition ? "ok" : "not ok") + " - " + stepName + ": " + message)
  }

  function ipc(method) {
    var answer = IpcRegistry.call(pluginId, method, [])
    return answer.ran ? answer.output : null
  }

  function stateIpc() {
    var text = ipc("state")
    try { return JSON.parse(text) } catch (error) { return {} }
  }

  function handlers() {
    return IpcRegistry.handlers.filter(function(handler) { return handler && handler.enabled && handler.target === root.pluginId }).length
  }

  // then(output) after an argv command; one at a time.
  function exec(argv, then) {
    tool.then = then
    tool.command = argv
    tool.running = true
  }

  Process {
    id: tool
    property var then: null
    stdout: StdioCollector { id: toolOut; waitForEnd: true }
    onExited: function(_exitCode, _exitStatus) {
      var then = tool.then
      Qt.callLater(function() { if (then) then(toolOut.text) })
    }
  }

  // then() once predicate() holds; a check fails after `ms` otherwise.
  function waitFor(predicate, ms, what, then) {
    waitDeadline = Date.now() + ms
    waiting = { predicate: predicate, what: what, then: then }
  }

  Timer {
    interval: 25
    running: root.waiting !== null
    repeat: true
    onTriggered: {
      var wait = root.waiting
      var held = false
      try { held = wait.predicate() } catch (error) {}
      if (held) { root.waiting = null; wait.then(); return }
      if (Date.now() < root.waitDeadline) return
      root.waiting = null
      root.check(false, "timed out waiting for " + wait.what)
      root.next()
    }
  }

  Timer {
    interval: 120000
    running: true
    onTriggered: { root.check(false, "the run timed out"); console.log("SMOKE done " + root.failures); Qt.quit() }
  }

  Component.onCompleted: Qt.callLater(next)

  function next() {
    step++
    if (step >= steps.length) { console.log("SMOKE done " + failures); Qt.quit(); return }
    stepName = steps[step].name
    steps[step].run()
  }

  property var steps: [
    { name: "start", run: function() {
      root.waitFor(function() { return service.entries.length === 3 && service.stateDirReady && service.ipcReady && service.marks.seenTs > 0 },
        5000, "the service to load", function() {
          root.check(service.missed === 1 && root.left.missed === 1 && root.right.missed === 1,
            "both bells show the service's missed count (" + root.left.missed + ", " + root.right.missed + ")")
          root.check(service.panels.length === 2 && service.openCount === 0, "both widgets registered, none open")
          root.check(root.handlers() === 1, "one IPC handler for the plugin (" + root.handlers() + ")")
          root.next()
        })
    } },

    { name: "open on one monitor", run: function() {
      root.left.open()
      root.check(service.openCount === 1, "the service counts one open panel")
      root.check(root.left.seenBefore === root.now - 250, "the panel keeps the seen mark from before it opened")
      root.check(service.marks.seenTs >= root.now, "opening marks the list seen")
      root.check(root.left.missedAtOpen === 1 && root.left.missed === 0 && root.right.missed === 0,
        "the open panel keeps its count while both bells clear")
      root.check(root.left.rows.filter(function(row) { return row.fresh }).length === 2, "the rows closed since the seen mark have a dot")
      var apps = root.left.filters.map(function(filter) { return filter.app })
      root.left.selectFilter(apps[0])
      var state = root.stateIpc()
      root.check(state.opened === true && state.filter === apps[0] && state.listed === 1 && state.entries === 3
        && state.seen_before === root.now - 250 && state.missed_at_open === 1, "state reports the open panel (" + JSON.stringify(state) + ")")
      root.next()
    } },

    { name: "read all from IPC", run: function() {
      root.check(root.ipc("readAll") === "ok", "the service answers readAll")
      root.check(service.marks.readTs === root.now - 100, "every row is read")
      root.check(root.left.noticeKey === "notice.read" && root.left.undoMarks !== null && root.right.undoMarks === null,
        "the open panel offers its undo, the other does not")
      root.left.undo()
      root.check(service.marks.readTs === 0 && service.marks.seenTs >= root.now, "undo puts the read mark back and keeps the seen mark")
      root.next()
    } },

    { name: "remove and clear", run: function() {
      root.left.selectFilter("")
      root.left.removeEntry(service.entries[0])
      root.check(service.kept.length === 2 && root.right.kept.length === 2, "a removal shows on both monitors")
      root.left.undo()
      root.check(service.kept.length === 3, "undo brings it back")
      root.left.clearList()
      root.check(service.kept.length === 0 && root.left.noticeCount === 3, "clear all empties the list (" + root.left.noticeCount + ")")
      root.left.undo()
      root.check(service.kept.length === 3, "undo brings the list back")
      root.next()
    } },

    { name: "the other monitor", run: function() {
      root.left.close()
      root.seenAtClose = service.marks.seenTs
      root.check(service.openCount === 0 && root.stateIpc().opened === false, "closing leaves no panel open")
      root.right.open()
      root.check(root.right.seenBefore === root.seenAtClose && service.openCount === 1,
        "the other panel counts from the seen mark the first one left")
      root.check(root.stateIpc().seen_before === root.seenAtClose, "state now reports that panel")
      root.right.close()
      root.next()
    } },

    { name: "IPC routing", run: function() {
      root.ipc("toggle"); root.ipc("open"); root.ipc("close")
      root.exec(["sh", "-c", "sleep 0.5; cat \"$1\"", "sh", root.fakeDir + "/calls"], function(calls) {
        root.check(calls.indexOf("shell toggle " + root.pluginId) >= 0 && calls.indexOf("shell summon " + root.pluginId) >= 0
          && calls.indexOf("shell hide " + root.pluginId) >= 0, "open, close and toggle go to the focused monitor's panel through the shell")
        root.next()
      })
    } },

    { name: "do not disturb", run: function() {
      root.right.toggleDnd()
      root.waitFor(function() { return service.dnd === true && service.callMethod === "" }, 5000, "Do Not Disturb", function() {
        root.check(root.left.dnd && root.right.dnd, "both bells follow Do Not Disturb")
        root.exec(["touch", root.fakeDir + "/fail"], function() {
          root.right.open()
          root.right.toggleDnd()
          root.waitFor(function() { return root.right.errorKey !== "" }, 5000, "the failure", function() {
            root.check(root.right.errorKey === "error.service" && root.left.errorKey === "", "only the asking panel reports the failure")
            root.right.close()
            root.next()
          })
        })
      })
    } },

    { name: "state file", run: function() {
      root.exec(["cat", root.stateDir + "/state.json"], function(text) {
        var saved = {}
        try { saved = JSON.parse(text) } catch (error) {}
        root.check(saved.schema === 1 && saved.seen_ts === service.marks.seenTs && saved.read_ts === 0 && saved.cleared_ts === 0,
          "the service wrote the marks (" + text.trim() + ")")
        root.next()
      })
    } },

    { name: "a rebuilt bar", run: function() {
      var extra = panelComponent.createObject(root, { bar: root.leftBar })
      root.check(service.panels.length === 3, "a new widget registers")
      extra.open()
      root.check(service.openCount === 1, "and counts while open")
      extra.destroy()
      root.waitFor(function() { return service.panels.length === 2 }, 2000, "the widget to leave", function() {
        root.check(service.openCount === 0, "a destroyed widget no longer counts")
        root.next()
      })
    } },

    { name: "under a replacement bar", run: function() {
      // bareBar's shell answers serviceFor() with null, as a replacement bar's does.
      root.bare = panelComponent.createObject(root, { bar: root.bareBar })
      var bare = root.bare
      root.check(bare.shellService === null && bare.service === service && service.panels.indexOf(bare) >= 0,
        "a widget whose bar has no services binds to the service through the link")
      root.check(bare.missed === service.missed && bare.kept.length === 3 && bare.dnd === service.dnd,
        "it shows the service's history and Do Not Disturb")
      root.left.removeEntry(service.entries[0])
      root.check(bare.kept.length === 2, "it follows a change made on another monitor")
      root.left.undo()
      bare.open()
      root.check(service.openCount === 1 && root.stateIpc().opened === true, "its panel counts as open")
      bare.close()
      root.next()
    } },

    { name: "a reloaded service", run: function() {
      var bare = root.bare
      root.fresh = serviceComponent.createObject(root)
      var fresh = root.fresh
      root.check(ServiceLink.current() === fresh && bare.service === fresh, "the widget follows the new service")
      root.check(fresh.panels.indexOf(bare) >= 0 && service.panels.indexOf(bare) < 0, "and moves its registration to it")
      root.check(root.left.service === service, "a widget on the built-in bar keeps its shell's service")
      ServiceLink.unregister(service)
      root.check(ServiceLink.current() === fresh, "the old service leaving afterwards does not clear the link")
      root.waitFor(function() { return fresh.entries.length === 3 && fresh.marks.seenTs > 0 }, 5000, "the new service to load", function() {
        root.check(bare.kept.length === 3 && bare.missed === fresh.missed, "the widget shows the new service's state")
        root.next()
      })
    } },

    { name: "the service gone", run: function() {
      var bare = root.bare
      var seen = service.marks.seenTs
      root.fresh.destroy()
      root.waitFor(function() { return bare.service === null }, 2000, "the widget to let go", function() {
        root.check(ServiceLink.current() === null && bare.missed === 0 && bare.kept.length === 0 && bare.dnd === false,
          "the widget falls back to an empty list")
        bare.open()
        bare.readAll()
        bare.clearList()
        bare.close()
        root.check(service.marks.seenTs === seen && service.kept.length === 3, "it leaves the remaining service alone")
        root.exec(["sh", "-c", "sleep 0.5; cat \"$1\"", "sh", root.fakeDir + "/calls"], function(calls) {
          root.check(calls.indexOf(root.pluginId + " readAll") >= 0, "its actions go over IPC")
          ServiceLink.register(service)
          root.check(bare.service === service && service.panels.indexOf(bare) >= 0, "a service that starts later is picked up")
          bare.destroy()
          root.next()
        })
      })
    } }
  ]
}
