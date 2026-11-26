// Tests for the Notification Center plugin's ServiceLink.js.
// Run from the plugin directory: node --test
"use strict"
const assert = require("node:assert")
const { test } = require("node:test")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "..", "ServiceLink.js"), "utf8").replace(/^\.pragma library$/m, "")
// A fresh copy per test, as a fresh QML engine would load it.
const load = () => { const link = {}; vm.runInNewContext(source, link); return link }

test("a registered service is current and reaches every listener", () => {
  const link = load()
  const seen = []
  const listener = next => seen.push(next)
  link.subscribe(listener)
  link.subscribe(listener)
  assert.strictEqual(link.current(), null)
  const service = { name: "a" }
  link.register(service)
  link.register(service)
  assert.strictEqual(link.current(), service)
  assert.deepStrictEqual(seen, [service])
})

test("a reload replaces the service, and the old one leaving changes nothing", () => {
  const link = load()
  const seen = []
  link.subscribe(next => seen.push(next && next.name))
  const old = { name: "old" }, fresh = { name: "new" }
  link.register(old)
  link.register(fresh)
  link.unregister(old)
  assert.strictEqual(link.current(), fresh)
  link.unregister(fresh)
  assert.strictEqual(link.current(), null)
  link.unregister(null)
  assert.deepStrictEqual(seen, ["old", "new", null])
})

test("an unsubscribed listener hears nothing and a failing one stops no other", () => {
  const link = load()
  const seen = []
  const gone = () => seen.push("gone")
  link.subscribe(() => { throw new Error("destroyed widget") })
  link.subscribe(gone)
  link.subscribe(next => seen.push(next.name))
  link.unsubscribe(gone)
  link.unsubscribe(() => {})
  link.subscribe("not a function")
  link.register({ name: "a" })
  assert.deepStrictEqual(seen, ["a"])
})
