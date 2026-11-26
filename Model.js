// Pure rules for the Notification Center panel: reading Omarchy's notification
// history, the panel's own seen, cleared and removed marks, search, filters,
// what opening a notification does, and formatting. QML binds to these
// functions so tests/model.test.js can exercise them in node.
.pragma library

// Omarchy keeps at most 100 closed notifications; anything longer is not its file.
var MAX_ENTRIES = 100
var MAX_FILE_CHARS = 2097152
var MAX_TEXT = 4096
var MAX_APP = 128
var MAX_SOURCE = 253
var MAX_ARGV = 32
var MAX_ARG = 2048
var MAX_HIDDEN = 200
var MAX_QUERY = 200
var MAX_FILTER_APPS = 4
var MAX_FILTER_LABEL = 18
var STATE_SCHEMA = 1
// Closed without the user seeing it through: it timed out, or Do Not Disturb
// sent it straight to history.
var MISSED_REASONS = { expired: true, silenced: true }
var ICON_NAME = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/
var ADDRESS = /^0x[0-9a-f]{1,16}$/i
var ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " }
var BROWSER_CLASSES = /^(chrome|chromium|google-chrome|firefox|zen|brave|microsoft-edge|edge|vivaldi|helium)/
// Every browser title ends in the browser's name; left on, a google.com
// notification would match every Chrome window.
var BROWSER_SUFFIX = /\s*[-–—|]\s*(google chrome|chromium|mozilla firefox|firefox|zen browser|brave origin|brave|microsoft edge|vivaldi|helium)\s*$/
// Labels that name nobody: common subdomains and public suffixes.
var GENERIC_LABELS = { www: 1, app: 1, web: 1, my: 1, m: 1, mail: 1, com: 1, org: 1, net: 1,
  io: 1, co: 1, dev: 1, ai: 1, so: 1, site: 1, uk: 1 }

function isObject(value) { return value !== null && typeof value === "object" && !Array.isArray(value) }

function bounded(value, limit) {
  return typeof value === "string" ? value.slice(0, limit) : ""
}

function finiteNumber(value) {
  return typeof value === "number" && isFinite(value) ? value : NaN
}

function decodeOnce(text) {
  return text
    .replace(/&#(\d{1,7});/g, function(whole, n) {
      var code = parseInt(n, 10)
      return code > 0 && code < 0x110000 ? String.fromCodePoint(code) : whole
    })
    .replace(/&#x([0-9a-f]{1,6});/gi, function(whole, n) {
      var code = parseInt(n, 16)
      return code > 0 && code < 0x110000 ? String.fromCodePoint(code) : whole
    })
    .replace(/&([a-z]+);/gi, function(whole, name) {
      var hit = ENTITIES[String(name).toLowerCase()]
      return hit === undefined ? whole : hit
    })
}

// A notification body is markup; the panel shows it as plain text. Tags go,
// <br> becomes a line break, entities are decoded (relays stack escapes, so up
// to three passes) and runs of blank space collapse.
function plainText(value, limit) {
  var text = bounded(value, limit || MAX_TEXT)
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]*>/g, "")
  for (var i = 0; i < 3; i++) {
    var once = decodeOnce(text)
    if (once === text) break
    text = once
  }
  return text
    .replace(/\r\n?/g, "\n")
    .replace(/[\t\f\v ]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
}

// Omarchy's --exec command, held to the rules its daemon applies before it
// runs one: a JSON array of up to 32 strings, no NUL, no leading-dash program.
function execArgv(value) {
  var text = bounded(value, MAX_TEXT)
  if (!text) return null
  var argv
  try { argv = JSON.parse(text) } catch (error) { return null }
  if (!Array.isArray(argv) || argv.length === 0 || argv.length > MAX_ARGV) return null
  for (var i = 0; i < argv.length; i++)
    if (typeof argv[i] !== "string" || argv[i].length > MAX_ARG || argv[i].indexOf("\u0000") >= 0) return null
  if (!argv[0] || argv[0].charAt(0) === "-") return null
  return argv
}

// A web notification's source is the site's host name.
function hostname(value) {
  if (typeof value !== "string" || value.length > MAX_SOURCE) return ""
  var host = value.toLowerCase().replace(/\.$/, "")
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(host)) return ""
  // A numeric-looking last label would be read as an IPv4 address.
  if (/^(?:0x[0-9a-f]*|[0-9]+)$/i.test(host.split(".").pop())) return ""
  return host
}

function entryFrom(row) {
  if (!isObject(row)) return null
  var closed = finiteNumber(row.closed_ts)
  if (!(closed > 0)) return null
  var ts = finiteNumber(row.ts)
  var reason = /^[a-z]{1,32}$/.test(String(row.closed_reason)) ? String(row.closed_reason) : ""
  var urgency = finiteNumber(row.urgency)
  var pid = finiteNumber(row.senderPid)
  var app = plainText(row.app, MAX_APP)
  var summary = plainText(row.summary)
  var body = plainText(row.body)
  return {
    id: bounded(String(row.key === undefined ? "" : row.key), 64) + "@" + closed,
    app: app,
    appIcon: ICON_NAME.test(bounded(row.appIcon, 256)) ? row.appIcon : "",
    glyph: bounded(row.glyph, 8),
    summary: summary,
    body: body,
    source: plainText(row.source, MAX_SOURCE),
    senderPid: pid > 0 && pid === Math.floor(pid) ? pid : 0,
    execArgv: execArgv(row.execArgv),
    ts: ts > 0 ? ts : closed,
    closedTs: closed,
    reason: reason,
    missed: MISSED_REASONS[reason] === true,
    critical: urgency === 2,
    haystack: (app + "\n" + summary + "\n" + body).toLowerCase()
  }
}

// Omarchy's history.json: closed rows, newest first. A missing or empty file
// is an empty history; anything else unreadable is reported.
function parseHistory(text) {
  var raw = typeof text === "string" ? text : ""
  if (!raw.trim()) return { entries: [], error: "" }
  if (raw.length > MAX_FILE_CHARS) return { entries: [], error: "error.unreadable" }
  var rows
  try {
    rows = JSON.parse(raw)
  } catch (error) {
    return { entries: [], error: "error.unreadable" }
  }
  if (!Array.isArray(rows)) return { entries: [], error: "error.unreadable" }
  var entries = []
  for (var i = 0; i < rows.length && entries.length < MAX_ENTRIES; i++) {
    var entry = entryFrom(rows[i])
    if (entry) entries.push(entry)
  }
  entries.sort(function(a, b) { return b.closedTs - a.closedTs })
  return { entries: entries, error: "" }
}

// Omarchy's quiet.json: { "dnd": true } while Do Not Disturb is on.
function parseQuiet(text) {
  if (typeof text !== "string" || !text.trim() || text.length > 4096) return false
  try {
    var read = JSON.parse(text)
    return isObject(read) && read.dnd === true
  } catch (error) {
    return false
  }
}

function emptyMarks() { return { seenTs: 0, clearedTs: 0, readTs: 0, hidden: [] } }

// The panel's own state: when the list was last looked at, up to when it was
// cleared and up to when it was all marked read (closed_ts seconds), and the
// ids removed one by one.
function parseState(text) {
  var state = emptyMarks()
  if (typeof text !== "string" || !text.trim() || text.length > 65536) return state
  try {
    var read = JSON.parse(text)
    if (!isObject(read) || read.schema !== STATE_SCHEMA) return state
    var seen = finiteNumber(read.seen_ts), cleared = finiteNumber(read.cleared_ts), readTs = finiteNumber(read.read_ts)
    if (seen > 0) state.seenTs = seen
    if (cleared > 0) state.clearedTs = cleared
    if (readTs > 0) state.readTs = readTs
    if (Array.isArray(read.hidden))
      state.hidden = read.hidden.filter(function(id) { return typeof id === "string" && id.length <= 128 })
        .slice(0, MAX_HIDDEN)
  } catch (error) {}
  return state
}

function serialiseState(state) {
  return JSON.stringify({ schema: STATE_SCHEMA, seen_ts: state.seenTs || 0, cleared_ts: state.clearedTs || 0,
    read_ts: state.readTs || 0, hidden: state.hidden || [] }) + "\n"
}

function withMarks(state, change) {
  var next = { seenTs: state.seenTs, clearedTs: state.clearedTs, readTs: state.readTs, hidden: state.hidden.slice() }
  for (var key in change) next[key] = change[key]
  return next
}

// Removing one adds its id; ids of rows Omarchy no longer keeps are dropped.
function hide(state, id, entries) {
  var present = {}
  for (var i = 0; i < entries.length; i++) present[entries[i].id] = true
  var hidden = state.hidden.filter(function(known) { return known !== id && present[known] })
  hidden.push(id)
  return withMarks(state, { hidden: hidden.slice(-MAX_HIDDEN) })
}

// What the list holds: past the clear mark and not removed.
function kept(entries, state) {
  var hidden = {}
  for (var i = 0; i < state.hidden.length; i++) hidden[state.hidden[i]] = true
  return entries.filter(function(entry) { return entry.closedTs > state.clearedTs && !hidden[entry.id] })
}

// Missed notifications in the list that closed after it was last looked at
// or marked read.
function missedCount(entries, state) {
  var rows = kept(entries, state)
  var since = Math.max(state.seenTs, state.readTs)
  var count = 0
  for (var i = 0; i < rows.length; i++)
    if (rows[i].missed && rows[i].closedTs > since) count++
  return count
}

// Whether a row still shows as unread: a missed tag, or a new-row dot for
// one that closed after `seenBefore`.
function isUnread(entry, state, seenBefore) {
  return entry.closedTs > state.readTs && (entry.missed || entry.closedTs > seenBefore)
}

function unreadCount(entries, state, seenBefore) {
  var rows = kept(entries, state)
  var count = 0
  for (var i = 0; i < rows.length; i++)
    if (isUnread(rows[i], state, seenBefore)) count++
  return count
}

// Read all: every notification Omarchy holds now counts as seen and read.
function markAllRead(state, entries) {
  var newest = 0
  for (var i = 0; i < entries.length; i++) newest = Math.max(newest, entries[i].closedTs)
  return withMarks(state, { readTs: Math.max(state.readTs, newest), seenTs: Math.max(state.seenTs, newest) })
}

// Whether Read all has anything to clear for a panel that opened at
// `seenBefore`: a row that still shows as unread, or a count on the bell.
function canReadAll(entries, state, seenBefore) {
  return unreadCount(entries, state, seenBefore) > 0 || missedCount(entries, state) > 0
}

// The seen mark a panel leaves as it opens or closes: now, or the newest row
// when that one carries a later time.
function seenMark(entries, now) {
  return Math.max(now, entries.length ? entries[0].closedTs : 0)
}

// Clear all: every row Omarchy holds now leaves the list, and the removed ids
// are no longer needed.
function clearAll(state, entries) {
  return withMarks(state, { clearedTs: entries.length ? entries[0].closedTs : state.clearedTs, hidden: [] })
}

// Undo puts back the marks from before a removal, Clear all or Read all, but
// keeps the seen mark as it is now: the list was in view meanwhile.
function restored(previous, current) {
  return withMarks(previous, { seenTs: current.seenTs })
}

// ---------- Panels ----------

// Which bar's panel answers for the `state` IPC method: the first open one,
// else the first there is; -1 when no bar shows the widget.
function reportingPanel(openFlags) {
  for (var i = 0; i < openFlags.length; i++)
    if (openFlags[i] === true) return i
  return openFlags.length ? 0 : -1
}

// The `state` IPC answer. `shared` holds what every panel shows (opened is
// whether any panel is open); `panel` holds the answering panel's own view,
// or null without one, which reads as a closed panel with no filter.
function stateReport(shared, panel) {
  var marks = shared.marks
  var view = panel || { listed: shared.entries, error: "", filter: "", query: "", searchFocused: false,
    seenBefore: marks.seenTs, missedAtOpen: shared.missed }
  return { opened: shared.opened === true, entries: shared.entries, listed: view.listed, missed: shared.missed,
    dnd: shared.dnd === true, error: view.error || shared.error || "", filter: view.filter, query: view.query,
    search_focused: view.searchFocused === true, hidden: marks.hidden.length, cleared_ts: marks.clearedTs,
    seen_ts: marks.seenTs, read_ts: marks.readTs, seen_before: view.seenBefore, missed_at_open: view.missedAtOpen }
}

function filterLabel(app) {
  return app.length > MAX_FILTER_LABEL ? app.slice(0, MAX_FILTER_LABEL - 1) + "…" : app
}

// The apps with the most notifications, for the filter chips. Fewer than two
// apps need no filter.
function appFilters(entries) {
  var counts = {}, names = []
  for (var i = 0; i < entries.length; i++) {
    var app = entries[i].app
    if (!app) continue
    if (counts[app] === undefined) { counts[app] = 0; names.push(app) }
    counts[app]++
  }
  if (names.length < 2) return []
  names.sort(function(a, b) { return counts[b] - counts[a] || (a < b ? -1 : a > b ? 1 : 0) })
  return names.slice(0, MAX_FILTER_APPS).map(function(name) {
    return { app: name, label: filterLabel(name), count: counts[name] }
  })
}

// Search words, lowercased; a row matches when its app, summary or body
// holds every one of them.
function queryWords(query) {
  return bounded(query, MAX_QUERY).toLowerCase().split(/\s+/).filter(function(word) { return word !== "" })
}

function matches(entry, words) {
  for (var i = 0; i < words.length; i++)
    if (entry.haystack.indexOf(words[i]) < 0) return false
  return true
}

function dayOf(closedTs, todayStart) {
  if (closedTs >= todayStart) return "today"
  if (closedTs >= todayStart - 86400) return "yesterday"
  return "earlier"
}

// The rows the panel lists: kept, of the chosen app, matching the search, each
// with its day, whether it opens that day's group, whether it arrived since last
// seen (`fresh`) and whether it still carries its missed tag (`unread`).
function listed(entries, state, app, query, seenBefore, todayStart) {
  var out = [], lastDay = ""
  var rows = kept(entries, state)
  var words = queryWords(query)
  for (var i = 0; i < rows.length; i++) {
    var entry = rows[i]
    if (app !== "" && entry.app !== app) continue
    if (!matches(entry, words)) continue
    var day = dayOf(entry.closedTs, todayStart)
    var unreadAfter = entry.closedTs > state.readTs
    out.push({ entry: entry, day: day, firstOfDay: day !== lastDay,
      fresh: unreadAfter && entry.closedTs > seenBefore, unread: unreadAfter && entry.missed })
    lastDay = day
  }
  return out
}

// ---------- Opening a notification ----------

// `hyprctl clients -j`, reduced to what choosing a window needs.
function parseClients(text) {
  var list
  try { list = JSON.parse(String(text || "")) } catch (error) { return [] }
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length && i < 512; i++) {
    var c = list[i]
    if (!isObject(c) || !ADDRESS.test(String(c.address || "")) || typeof c["class"] !== "string" || !c["class"]) continue
    out.push({ address: String(c.address), wmClass: c["class"], title: typeof c.title === "string" ? c.title : "",
      pid: finiteNumber(c.pid) > 0 ? c.pid : 0,
      // 0 is the window you are in, 1 the one before it.
      focusOrder: finiteNumber(c.focusHistoryID) >= 0 ? c.focusHistoryID : 9999 })
  }
  return out
}

function mostRecent(candidates) {
  var best = null
  for (var i = 0; i < candidates.length; i++)
    if (!best || candidates[i].focusOrder < best.focusOrder) best = candidates[i]
  return best
}

// Whole words only: "slack" must not match "slackline".
function wordIn(text, word) {
  var at = text.indexOf(word)
  while (at >= 0) {
    var before = at === 0 ? "" : text.charAt(at - 1)
    var after = text.charAt(at + word.length)
    if (!/[a-z0-9]/.test(before) && !/[a-z0-9]/.test(after)) return true
    at = text.indexOf(word, at + 1)
  }
  return false
}

// What to look for in a browser title, most telling first: "app.slack.com"
// gives ["slack"], "news.ycombinator.com" gives ["news", "ycombinator"].
function brandsOf(host) {
  var labels = host.split(".")
  var out = []
  for (var i = 0; i < labels.length; i++)
    if (labels[i].length >= 4 && !GENERIC_LABELS[labels[i]]) { out.push(labels[i]); break }
  var registered = labels.length >= 2 ? labels[labels.length - 2] : ""
  if (registered.length >= 4 && !GENERIC_LABELS[registered] && out.indexOf(registered) < 0) out.push(registered)
  return out
}

// The window that already shows a source, as Omarchy's daemon finds it: a
// web app carries its host in the class, a browser tab only in its title; an
// app name matches a native class or a web app's host label.
function windowForSource(windows, source) {
  var name = String(source || "").toLowerCase()
  if (!name) return null
  var found = [], i
  var host = hostname(name)
  if (host) {
    for (i = 0; i < windows.length; i++)
      if (windows[i].wmClass.toLowerCase().indexOf(host) >= 0) found.push(windows[i])
    if (found.length) return mostRecent(found)
    var brands = brandsOf(host)
    for (var b = 0; b < brands.length; b++) {
      found = []
      for (i = 0; i < windows.length; i++) {
        if (!BROWSER_CLASSES.test(windows[i].wmClass.toLowerCase())) continue
        if (wordIn(windows[i].title.toLowerCase().replace(BROWSER_SUFFIX, ""), brands[b])) found.push(windows[i])
      }
      if (found.length) return mostRecent(found)
    }
    return null
  }
  var slug = name.replace(/[^a-z0-9]+/g, "")
  if (slug.length < 4) return null
  // Several words also match a class ending in them: "Telegram Desktop" is
  // org.telegram.desktop; "Teams for Linux" is teams-for-linux.
  var words = name.split(/[^a-z0-9]+/).filter(function(w) { return w })
  var tail = words.length > 1 ? "." + words.join(".") : ""
  for (i = 0; i < windows.length; i++) {
    var lower = windows[i].wmClass.toLowerCase()
    var dotted = "." + lower.replace(/[^a-z0-9]+/g, ".")
    if (lower.replace(/[^a-z0-9]+/g, "") === slug || (tail && dotted.slice(-tail.length) === tail)) {
      found.push(windows[i])
      continue
    }
    if (lower.indexOf("chrome-") !== 0) continue
    var labels = lower.substring(7).split("__")[0].split(".")
    if (labels.indexOf(slug) >= 0) found.push(windows[i])
  }
  return mostRecent(found)
}

function regexLiteral(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// What a click on a stored notification does, in the order Omarchy's daemon
// uses for one it puts back from history (its sender's own actions die with
// the notification): Omarchy's --exec command, the sender's window, the
// source's window, the source site, then any window of the app.
function openTarget(entry, windows) {
  if (!entry) return null
  if (entry.execArgv) return { kind: "exec", argv: entry.execArgv }
  if (entry.senderPid > 0)
    for (var i = 0; i < windows.length; i++)
      if (windows[i].pid === entry.senderPid) return { kind: "window", address: windows[i].address }
  var win = windowForSource(windows, entry.source || entry.app)
  if (win) return { kind: "window", address: win.address }
  var host = hostname(entry.source)
  if (host) return { kind: "url", url: "https://" + host + "/" }
  if (entry.app) return { kind: "app", argv: ["omarchy-hyprland-focus-app", regexLiteral(entry.app)] }
  return null
}

// ---------- Formatting ----------

// How long ago, as a translation key and a count.
function ago(ts, now) {
  var seconds = Math.max(0, now - ts)
  if (seconds < 60) return { key: "time.now", count: 0 }
  if (seconds < 3600) return { key: "time.minutes", count: Math.floor(seconds / 60) }
  if (seconds < 86400) return { key: "time.hours", count: Math.floor(seconds / 3600) }
  return { key: "time.days", count: Math.floor(seconds / 86400) }
}

// Omarchy's own marks sit at U+E900 and up and need its icon font.
function omarchyGlyph(glyph) {
  var code = String(glyph || "").codePointAt(0)
  return code >= 0xe900 && code <= 0xe9ff
}

function initial(app) {
  var text = String(app || "").trim()
  return text ? String.fromCodePoint(text.codePointAt(0)).toUpperCase() : "?"
}

function barIcon(missed, dnd) {
  if (dnd) return "󰂛"
  return missed > 0 ? "󱅫" : "󰂚"
}

// The most missed notifications the bar spells out; more read as "99+".
var BAR_LABEL_MAX = 99

// The number beside the bell, or "" when there is none to show. `format`
// turns a number into the shell's digits.
function barLabel(missed, show, format) {
  var count = Math.floor(Number(missed))
  if (!show || !(count > 0)) return ""
  return count > BAR_LABEL_MAX ? format(BAR_LABEL_MAX) + "+" : format(count)
}
