import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"
import vm from "node:vm"

const source = readFileSync(new URL("../../../priv/static/theme_init.js", import.meta.url), "utf8")

function boot({saved, osDark = false, scriptKey, htmlKey} = {}) {
  const key = scriptKey || htmlKey || "sr:theme"
  const store = new Map()
  if (saved !== undefined) store.set(key, saved)
  const listeners = {}
  const html = {
    attrs: {},
    getAttribute(name) {
      return name === "data-sr-theme-key" ? htmlKey || null : (this.attrs[name] ?? null)
    },
    setAttribute(name, value) {
      this.attrs[name] = value
    },
  }
  const context = {
    document: {
      currentScript: {getAttribute: (name) => (name === "data-sr-theme-key" ? scriptKey || null : null)},
      documentElement: html,
    },
    localStorage: {
      getItem: (name) => (store.has(name) ? store.get(name) : null),
      setItem: (name, value) => store.set(name, value),
      removeItem: (name) => store.delete(name),
    },
    window: {
      addEventListener(type, fn) {
        listeners[type] = fn
      },
      matchMedia() {
        return {
          matches: osDark,
          addEventListener(_type, fn) {
            listeners.change = fn
          },
        }
      },
    },
  }
  vm.runInNewContext(source, context)
  return {html, listeners, store, key}
}

test("uses sr:theme and follows the OS when nothing is stored", () => {
  const {html, store} = boot({osDark: true})
  assert.equal(html.attrs["data-theme"], "dark")
  assert.equal(html.attrs["data-theme-preference"], "system")
  assert.equal(store.has("sr:theme"), false)
})

test("restores a stored light preference before first paint", () => {
  const {html} = boot({saved: "light", osDark: true})
  assert.equal(html.attrs["data-theme"], "light")
  assert.equal(html.attrs["data-theme-preference"], "light")
})

test("honours data-sr-theme-key and sr:set-theme", () => {
  const {html, listeners, store} = boot({scriptKey: "phx:theme", osDark: false})
  assert.equal(store.has("sr:theme"), false)
  listeners["sr:set-theme"]({detail: {theme: "dark"}})
  assert.equal(store.get("phx:theme"), "dark")
  assert.equal(html.attrs["data-theme"], "dark")
  assert.equal(html.attrs["data-theme-preference"], "dark")
})

test("the source is an external script, not an inline document", () => {
  assert.equal(source.includes("<script"), false)
  assert.equal(source.includes("sr:theme"), true)
  assert.equal(source.includes("data-sr-theme-key"), true)
})
