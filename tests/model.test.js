// Tests for the Notification Center plugin's Model.js.
// Run from the plugin directory: node --test
"use strict"
const assert = require("node:assert")
const { test } = require("node:test")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const pluginDir = path.join(__dirname, "..")
const Model = {}
vm.runInNewContext(fs.readFileSync(path.join(pluginDir, "Model.js"), "utf8").replace(/^\.pragma library$/m, ""), Model)
// vm-context objects have a foreign prototype; compare them as plain JSON.
const plain = value => JSON.parse(JSON.stringify(value))

const NOW = 1795000000
const TODAY = NOW - 3600 * 5 // local midnight, five hours ago
const row = (over = {}) => ({ key: "n1", app: "Teams for Linux", appIcon: "teams-for-linux", glyph: "", summary: "Ana",
  body: "Hello", source: "Teams for Linux", senderPid: 4242, execArgv: "", ts: NOW - 120, closed_ts: NOW - 60,
  closed_reason: "expired", urgency: 1, ...over })
const history = rows => Model.parseHistory(JSON.stringify(rows)).entries
const marks = (over = {}) => ({ seenTs: 0, clearedTs: 0, readTs: 0, hidden: [], ...over })
const win = (over = {}) => ({ address: "0xabc", class: "org.gnome.Nautilus", title: "Files", pid: 1, focusHistoryID: 3, ...over })
const clients = list => Model.parseClients(JSON.stringify(list))

const tests = {
  "history parsing keeps valid rows newest first"() {
    const entries = history([row({ key: "a", closed_ts: NOW - 500 }), { closed_ts: "x" }, 7, row({ key: "b", closed_ts: NOW - 10 })])
    assert.deepStrictEqual(plain(entries.map(e => e.id)), ["b@" + (NOW - 10), "a@" + (NOW - 500)])
    assert.strictEqual(entries[0].missed, true)
    assert.strictEqual(history([row({ closed_reason: "dismissed" })])[0].missed, false)
    assert.strictEqual(history([row({ closed_reason: "silenced" })])[0].missed, true)
    assert.strictEqual(history([row({ urgency: 2 })])[0].critical, true)
    assert.strictEqual(history([row({ ts: undefined })])[0].ts, NOW - 60)
    assert.strictEqual(history([row({ senderPid: -3 })])[0].senderPid, 0)
    assert.strictEqual(history([row({ senderPid: 1.5 })])[0].senderPid, 0)
  },
  "history parsing reports unreadable files and accepts a missing one"() {
    assert.deepStrictEqual(plain(Model.parseHistory("")), { entries: [], error: "" })
    assert.strictEqual(Model.parseHistory("{").error, "error.unreadable")
    assert.strictEqual(Model.parseHistory("{\"a\":1}").error, "error.unreadable")
    assert.strictEqual(Model.parseHistory(JSON.stringify(Array.from({ length: 150 }, (_, i) => row({ key: "k" + i })))).entries.length, 100)
  },
  "markup-shaped sender text becomes plain text"() {
    const entry = history([row({ summary: "<img src=\"https://example.invalid/t\">Ana", body: "<b>Tom &amp;amp; Jerry</b><br>next &lt;i&gt;" })])[0]
    assert.strictEqual(entry.summary, "Ana")
    assert.strictEqual(entry.body, "Tom & Jerry\nnext <i>")
    assert.strictEqual(Model.plainText("  a \t b \n\n\n\n c  "), "a b\n\nc")
    assert.strictEqual(Model.plainText(42), "")
    assert.strictEqual(Model.plainText("x".repeat(5000)).length, 4096)
  },
  "only theme icon names are kept"() {
    assert.strictEqual(history([row()])[0].appIcon, "teams-for-linux")
    assert.strictEqual(history([row({ appIcon: "/tmp/x.png" })])[0].appIcon, "")
    assert.strictEqual(history([row({ appIcon: "file:///etc/passwd" })])[0].appIcon, "")
    assert.strictEqual(history([row({ appIcon: "../icon" })])[0].appIcon, "")
  },
  "Omarchy exec commands follow its daemon's rules"() {
    assert.deepStrictEqual(plain(Model.execArgv("[\"xdg-open\",\"/tmp/a.png\"]")), ["xdg-open", "/tmp/a.png"])
    assert.strictEqual(Model.execArgv(""), null)
    assert.strictEqual(Model.execArgv("xdg-open /tmp/a.png"), null)
    assert.strictEqual(Model.execArgv("[\"-rf\"]"), null)
    assert.strictEqual(Model.execArgv("[\"a\",3]"), null)
    assert.strictEqual(Model.execArgv("[\"a\",\"b\\u0000c\"]"), null)
    assert.strictEqual(Model.execArgv(JSON.stringify(Array(33).fill("a"))), null)
    assert.strictEqual(Model.execArgv("[]"), null)
  },
  "host names are checked before a URL is built from them"() {
    assert.strictEqual(Model.hostname("App.Slack.com."), "app.slack.com")
    assert.strictEqual(Model.hostname("Teams for Linux"), "")
    assert.strictEqual(Model.hostname("0x7f.0x0.0x0.0x1"), "")
    assert.strictEqual(Model.hostname("evil.com/path"), "")
    assert.strictEqual(Model.hostname("localhost"), "")
  },
  "Do Not Disturb follows quiet.json"() {
    assert.strictEqual(Model.parseQuiet("{\"dnd\":true}\n"), true)
    assert.strictEqual(Model.parseQuiet("{\"dnd\":false}"), false)
    assert.strictEqual(Model.parseQuiet(""), false)
    assert.strictEqual(Model.parseQuiet("nope"), false)
  },
  "own state round-trips and rejects other schemas"() {
    const state = Model.parseState(Model.serialiseState(marks({ seenTs: 10, clearedTs: 5, readTs: 7, hidden: ["a@1"] })))
    assert.deepStrictEqual(plain(state), { seenTs: 10, clearedTs: 5, readTs: 7, hidden: ["a@1"] })
    assert.strictEqual(Model.parseState("{\"schema\":1,\"seen_ts\":3}").readTs, 0)
    assert.deepStrictEqual(plain(Model.parseState("{\"schema\":2,\"seen_ts\":10}")), marks())
    assert.deepStrictEqual(plain(Model.parseState("{")), marks())
    assert.deepStrictEqual(plain(Model.parseState("{\"schema\":1,\"seen_ts\":\"x\",\"cleared_ts\":-4,\"hidden\":[1,\"b@2\"]}")),
      marks({ hidden: ["b@2"] }))
  },
  "removing one hides it and forgets ids Omarchy no longer keeps"() {
    const entries = history([row({ key: "a", closed_ts: NOW - 30 }), row({ key: "b", closed_ts: NOW - 300 })])
    const [a, b] = entries.map(e => e.id)
    const state = Model.hide(marks({ hidden: ["gone@1"] }), a, entries)
    assert.deepStrictEqual(plain(state.hidden), [a])
    assert.deepStrictEqual(plain(Model.kept(entries, state).map(e => e.id)), [b])
    assert.deepStrictEqual(plain(Model.hide(state, b, entries).hidden), [a, b])
    assert.deepStrictEqual(plain(Model.hide(state, a, entries).hidden), [a])
  },
  "missed count skips removed rows and starts after the seen and cleared marks"() {
    const entries = history([row({ key: "a", closed_ts: NOW - 30 }), row({ key: "b", closed_ts: NOW - 300 }),
      row({ key: "c", closed_ts: NOW - 200, closed_reason: "activated" })])
    assert.strictEqual(Model.missedCount(entries, marks()), 2)
    assert.strictEqual(Model.missedCount(entries, marks({ seenTs: NOW - 100 })), 1)
    assert.strictEqual(Model.missedCount(entries, marks({ clearedTs: NOW - 10 })), 0)
    assert.strictEqual(Model.missedCount(entries, marks({ hidden: [entries[0].id] })), 1)
  },
  "listing applies the clear mark, the app filter, the search and day groups"() {
    const entries = history([row({ key: "a", closed_ts: NOW - 60, summary: "Deploy finished" }),
      row({ key: "b", app: "FortiClient", closed_ts: NOW - 7200, summary: "VPN connected", body: "Tunnel up" }),
      row({ key: "c", closed_ts: TODAY - 600 }), row({ key: "d", closed_ts: TODAY - 90000 })])
    const all = Model.listed(entries, marks(), "", "", NOW - 3600, TODAY)
    assert.deepStrictEqual(plain(all.map(r => [r.day, r.firstOfDay, r.fresh])),
      [["today", true, true], ["today", false, false], ["yesterday", true, false], ["earlier", true, false]])
    assert.deepStrictEqual(plain(Model.listed(entries, marks(), "FortiClient", "", 0, TODAY).map(r => r.entry.app)), ["FortiClient"])
    assert.strictEqual(Model.listed(entries, marks({ clearedTs: NOW - 60 }), "", "", 0, TODAY).length, 0)
    const search = q => plain(Model.listed(entries, marks(), "", q, 0, TODAY).map(r => r.entry.summary))
    assert.deepStrictEqual(search("tunnel"), ["VPN connected"])
    assert.deepStrictEqual(search("  FORTI   up "), ["VPN connected"])
    assert.deepStrictEqual(search("deploy vpn"), [])
    assert.strictEqual(search("teams").length, 3)
    assert.strictEqual(Model.listed(entries, marks(), "Teams for Linux", "tunnel", 0, TODAY).length, 0)
  },
  "read all clears tags, dots and the missed count up to the newest row"() {
    const entries = history([row({ key: "a", closed_ts: NOW - 30 }), row({ key: "b", closed_ts: NOW - 300, closed_reason: "dismissed" })])
    const before = marks()
    assert.strictEqual(Model.missedCount(entries, before), 1)
    assert.strictEqual(Model.unreadCount(entries, before, NOW - 3600), 2)
    const read = Model.markAllRead(before, entries)
    assert.deepStrictEqual([read.readTs, read.seenTs], [NOW - 30, NOW - 30])
    assert.strictEqual(Model.missedCount(entries, read), 0)
    assert.strictEqual(Model.unreadCount(entries, read, 0), 0)
    const rows = Model.listed(entries, read, "", "", 0, TODAY)
    assert.deepStrictEqual(plain(rows.map(r => [r.unread, r.fresh])), [[false, false], [false, false]])
    // A notification closing after the mark is unread again.
    const later = history([row({ key: "c", closed_ts: NOW + 10 })].concat([row({ key: "a", closed_ts: NOW - 30 })]))
    assert.strictEqual(Model.missedCount(later, read), 1)
    assert.deepStrictEqual(plain(Model.listed(later, read, "", "", NOW, TODAY).map(r => r.unread)), [true, false])
    // The mark never moves back, and an empty history leaves it where it is.
    assert.strictEqual(Model.markAllRead(marks({ readTs: NOW + 99, seenTs: NOW + 99 }), entries).readTs, NOW + 99)
    assert.strictEqual(Model.markAllRead(marks({ readTs: 5 }), []).readTs, 5)
  },
  "read all needs an unread row for the panel or a count on the bell"() {
    const entries = history([row({ key: "a", closed_ts: NOW - 30, closed_reason: "dismissed" }),
      row({ key: "b", closed_ts: NOW - 300 })])
    assert.strictEqual(Model.canReadAll(entries, marks(), 0), true)
    // Nothing missed after the seen mark, but a dot for a panel opened earlier.
    const seen = marks({ seenTs: NOW, readTs: NOW - 300 })
    assert.strictEqual(Model.canReadAll(entries, seen, NOW - 100), true)
    assert.strictEqual(Model.canReadAll(entries, seen, NOW), false)
    // A missed tag still shows below the seen mark until read all.
    assert.strictEqual(Model.canReadAll(entries, marks({ seenTs: NOW }), NOW), true)
    assert.strictEqual(Model.canReadAll(entries, Model.markAllRead(marks(), entries), 0), false)
    assert.strictEqual(Model.canReadAll([], marks(), 0), false)
  },
  "the seen mark is now, or the newest row when it is later"() {
    const entries = history([row({ key: "a", closed_ts: NOW + 50 }), row({ key: "b", closed_ts: NOW - 300 })])
    assert.strictEqual(Model.seenMark(entries, NOW), NOW + 50)
    assert.strictEqual(Model.seenMark(entries, NOW + 99), NOW + 99)
    assert.strictEqual(Model.seenMark([], NOW), NOW)
  },
  "clear all moves the clear mark to the newest row and undo keeps the seen mark"() {
    const entries = history([row({ key: "a", closed_ts: NOW - 30 }), row({ key: "b", closed_ts: NOW - 300 })])
    const before = marks({ seenTs: NOW - 400, readTs: NOW - 500, hidden: [entries[1].id] })
    const cleared = Model.clearAll(before, entries)
    assert.deepStrictEqual(plain(cleared), { seenTs: NOW - 400, clearedTs: NOW - 30, readTs: NOW - 500, hidden: [] })
    assert.strictEqual(Model.kept(entries, cleared).length, 0)
    assert.deepStrictEqual(plain(Model.clearAll(marks({ clearedTs: 7 }), [])), marks({ clearedTs: 7 }))
    // Looking at the list after the change keeps counting as looking.
    const back = Model.restored(before, Model.withMarks(cleared, { seenTs: NOW }))
    assert.deepStrictEqual(plain(back), { seenTs: NOW, clearedTs: 0, readTs: NOW - 500, hidden: [entries[1].id] })
    assert.deepStrictEqual(plain(before.hidden), [entries[1].id])
  },
  "the state answer comes from the first open panel, else the first one"() {
    assert.strictEqual(Model.reportingPanel([]), -1)
    assert.strictEqual(Model.reportingPanel([false, false]), 0)
    assert.strictEqual(Model.reportingPanel([false, true, true]), 1)
    const shared = { opened: true, entries: 4, missed: 2, dnd: true, error: "error.unreadable",
      marks: marks({ seenTs: 30, clearedTs: 10, readTs: 20, hidden: ["a@1", "b@2"] }) }
    const panel = { listed: 1, error: "error.service", filter: "Slack", query: "deploy", searchFocused: true,
      seenBefore: 25, missedAtOpen: 3 }
    assert.deepStrictEqual(plain(Model.stateReport(shared, panel)), { opened: true, entries: 4, listed: 1, missed: 2,
      dnd: true, error: "error.service", filter: "Slack", query: "deploy", search_focused: true, hidden: 2,
      cleared_ts: 10, seen_ts: 30, read_ts: 20, seen_before: 25, missed_at_open: 3 })
    assert.strictEqual(Model.stateReport(shared, Object.assign({}, panel, { error: "" })).error, "error.unreadable")
    assert.deepStrictEqual(plain(Model.stateReport(Object.assign({}, shared, { opened: false, error: "" }), null)),
      { opened: false, entries: 4, listed: 4, missed: 2, dnd: true, error: "", filter: "", query: "",
        search_focused: false, hidden: 2, cleared_ts: 10, seen_ts: 30, read_ts: 20, seen_before: 30, missed_at_open: 2 })
  },
  "filters list the busiest apps and need two of them"() {
    assert.deepStrictEqual(plain(Model.appFilters(history([row(), row({ key: "x" })]))), [])
    const apps = ["A", "B", "B", "C", "C", "C", "D", "E", "A very long application name"]
    const filters = Model.appFilters(history(apps.map((app, i) => row({ key: "k" + i, app, closed_ts: NOW - i }))))
    assert.deepStrictEqual(plain(filters.map(f => [f.app, f.count])), [["C", 3], ["B", 2], ["A", 1], ["A very long application name", 1]])
    assert.strictEqual(filters[3].label, "A very long appli…")
  },
  "Hyprland clients are reduced to valid windows"() {
    const list = clients([win(), win({ address: "nope" }), win({ class: "" }), { address: "0x1" }, 5,
      win({ address: "0xdef", pid: "x", focusHistoryID: undefined })])
    assert.deepStrictEqual(plain(list.map(w => [w.address, w.pid, w.focusOrder])), [["0xabc", 1, 3], ["0xdef", 0, 9999]])
    assert.deepStrictEqual(plain(Model.parseClients("not json")), [])
  },
  "opening runs Omarchy's command first, then the sender's window"() {
    const windows = clients([win({ address: "0x1", class: "teams-for-linux", pid: 4242 }), win({ address: "0x2", class: "foot", pid: 9 })])
    const shot = history([row({ app: "omasnap", source: "omasnap", senderPid: 0, execArgv: "[\"xdg-open\",\"/tmp/s.png\"]" })])[0]
    assert.deepStrictEqual(plain(Model.openTarget(shot, windows)), { kind: "exec", argv: ["xdg-open", "/tmp/s.png"] })
    assert.deepStrictEqual(plain(Model.openTarget(history([row()])[0], windows)), { kind: "window", address: "0x1" })
    // The sender's pid has no window: the app's class still finds Teams.
    assert.deepStrictEqual(plain(Model.openTarget(history([row({ senderPid: 77 })])[0], windows)), { kind: "window", address: "0x1" })
    assert.strictEqual(Model.openTarget(null, windows), null)
  },
  "opening finds a source's window by class, web app and browser tab"() {
    const pick = (source, list) => plain(Model.windowForSource(clients(list), source))
    assert.strictEqual(pick("Telegram Desktop", [win({ class: "org.telegram.desktop" })]).address, "0xabc")
    assert.strictEqual(pick("Slack", [win({ class: "chrome-app.slack.com__-Default" })]).address, "0xabc")
    assert.strictEqual(pick("app.slack.com", [win({ class: "chrome-app.slack.com__-Default" })]).address, "0xabc")
    assert.strictEqual(pick("app.slack.com", [win({ class: "chromium", title: "Slack | general - Chromium" })]).address, "0xabc")
    assert.strictEqual(pick("app.slack.com", [win({ class: "foot", title: "slack notes" })]), null)
    assert.strictEqual(pick("Slack", [win({ class: "slackline" })]), null)
    assert.strictEqual(pick("Foo", [win({ class: "foo" })]), null)
    const recent = pick("Teams for Linux", [win({ address: "0x1", class: "teams-for-linux", focusHistoryID: 4 }),
      win({ address: "0x2", class: "teams-for-linux", focusHistoryID: 1 })])
    assert.strictEqual(recent.address, "0x2")
  },
  "opening falls back to the source site, then the app by name"() {
    const site = history([row({ app: "Google Chrome", source: "web.whatsapp.com", senderPid: 0 })])[0]
    assert.deepStrictEqual(plain(Model.openTarget(site, [])), { kind: "url", url: "https://web.whatsapp.com/" })
    const app = history([row({ app: "Foo (beta)", source: "Foo (beta)", senderPid: 0 })])[0]
    assert.deepStrictEqual(plain(Model.openTarget(app, [])), { kind: "app", argv: ["omarchy-hyprland-focus-app", "Foo \\(beta\\)"] })
    assert.strictEqual(Model.openTarget(history([row({ app: "", source: "", senderPid: 0 })])[0], []), null)
  },
  "relative time and formatting helpers"() {
    assert.deepStrictEqual(plain(Model.ago(NOW - 5, NOW)), { key: "time.now", count: 0 })
    assert.deepStrictEqual(plain(Model.ago(NOW - 150, NOW)), { key: "time.minutes", count: 2 })
    assert.deepStrictEqual(plain(Model.ago(NOW - 7300, NOW)), { key: "time.hours", count: 2 })
    assert.deepStrictEqual(plain(Model.ago(NOW - 90000, NOW)), { key: "time.days", count: 1 })
    assert.deepStrictEqual(plain(Model.ago(NOW + 50, NOW)), { key: "time.now", count: 0 })
    assert.strictEqual(Model.initial("teams"), "T")
    assert.strictEqual(Model.initial(""), "?")
    assert.strictEqual(Model.omarchyGlyph(""), true)
    assert.strictEqual(Model.omarchyGlyph("󰅍"), false)
    assert.deepStrictEqual([Model.barIcon(0, false), Model.barIcon(3, false), Model.barIcon(3, true)], ["󰂚", "󱅫", "󰂛"])
  },
  "the bar label counts missed notifications up to 99+"() {
    const format = n => "<" + n + ">"
    assert.deepStrictEqual([0, -2, NaN, 1, 76, 99, 100, 4200].map(n => Model.barLabel(n, true, format)),
      ["", "", "", "<1>", "<76>", "<99>", "<99>+", "<99>+"])
    assert.strictEqual(Model.barLabel(76, false, format), "")
    assert.strictEqual(Model.barLabel("<b>7</b>", true, format), "")
    assert.strictEqual(Model.barLabel(2.7, true, format), "<2>")
  },
  "the catalog holds every key the panel reads"() {
    const en = JSON.parse(fs.readFileSync(path.join(pluginDir, "i18n/en.json"), "utf8"))
    const qml = ["Panel.qml", "Service.qml", "EntryRow.qml"].map(f => fs.readFileSync(path.join(pluginDir, f), "utf8")).join("\n")
    const used = new Set([...qml.matchAll(/strings\.tn?\("([a-z.]+[a-z])"[,)]/g)].map(m => m[1]))
    for (const key of ["error.unreadable", "error.service", "notice.removed", "notice.cleared", "notice.nothing",
      "reason.expired", "reason.silenced", "day.today", "day.yesterday", "day.earlier", "time.now", "time.minutes",
      "time.hours", "time.days"]) used.add(key)
    for (const key of used) assert.ok(key in en, "missing " + key)
  },
}
for (const [name, body] of Object.entries(tests)) test(name, body)
