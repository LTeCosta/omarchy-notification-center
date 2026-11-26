.pragma library
// The plugin's own way from a bar widget to its service. A .pragma library
// script has one copy per QML engine and URL, so Service.qml and every bar's
// Panel.qml, importing it by the same relative path, see the same object.
//
// The built-in bar hands its widgets a shell whose serviceFor() returns the
// plugin's service; a replacement bar hands them one without services, where
// serviceFor() is null. The service registers here as it starts and leaves as
// it goes, so a widget under any bar finds it, and follows it when it loads
// later, is reloaded or goes away, without polling.

var service = null
var listeners = []

function notify() {
  var current = service
  var copy = listeners.slice()
  for (var i = 0; i < copy.length; i++) {
    // One widget's failure must not keep the others on an old service.
    try { copy[i](current) } catch (error) {}
  }
}

// The newest service wins: a reloaded plugin's service starts before the old
// one is destroyed.
function register(next) {
  if (!next || next === service) return
  service = next
  notify()
}

// Only the service still registered clears the link; an old one leaving after
// its replacement started changes nothing.
function unregister(old) {
  if (!old || old !== service) return
  service = null
  notify()
}

function current() { return service }

function subscribe(listener) {
  if (typeof listener === "function" && listeners.indexOf(listener) < 0) listeners.push(listener)
}

function unsubscribe(listener) {
  var index = listeners.indexOf(listener)
  if (index >= 0) listeners.splice(index, 1)
}
