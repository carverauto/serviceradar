import {beforeEach, describe, expect, it} from "vitest"

import SettingsNavTree from "./SettingsNavTree"

// Lightweight DOM mocks (jsdom is not part of this project's vitest env, so the
// existing hook tests model just enough of the element surface the hook touches).

function memoryStorage() {
  const store = new Map()
  return {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
    clear: () => store.clear(),
  }
}

function makeGroup({id, active = false, open = false, views = []}) {
  const attrs = {"data-group-id": id}
  if (active) attrs["data-active-group"] = "true"

  const listeners = {}
  const leafItems = views.map((haystack) => ({
    _hidden: false,
    getAttribute: (k) => (k === "data-view-search" ? haystack : null),
    classList: {
      toggle(_cls, force) {
        this._force = force
      },
    },
  }))

  const group = {
    open,
    _hidden: false,
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    hasAttribute: (k) => k in attrs,
    addEventListener: (ev, fn) => {
      listeners[ev] = fn
    },
    removeEventListener: (ev) => {
      delete listeners[ev]
    },
    classList: {
      toggle(_cls, force) {
        group._hidden = !!force
      },
    },
    querySelectorAll: () => leafItems,
    // Test helper: emulate the browser dispatching a `toggle` event after the
    // operator clicks the <summary>.
    _fireToggle() {
      if (listeners.toggle) listeners.toggle({currentTarget: group})
    },
  }

  return group
}

function makeTree(groups, {filterValue = null} = {}) {
  const filterInput =
    filterValue === null
      ? null
      : {
          value: filterValue,
          addEventListener() {},
          removeEventListener() {},
        }

  const emptyEl = {classList: {toggle() {}}}

  const el = {
    querySelector: (selector) => {
      if (selector === "[data-view-filter-input]") return filterInput
      if (selector === "[data-view-filter-empty]") return emptyEl
      return null
    },
    querySelectorAll: (selector) =>
      selector === "[data-nav-group]" ? groups : [],
  }

  const hook = Object.create(SettingsNavTree)
  hook.el = el
  return hook
}

// Simulate a LiveView patch that re-sends the server markup: `open` survives on
// the active group (the server renders it open) but is stripped from every other
// group (the server omits it), exactly as morphdom's attribute merge would.
function patchStrippingOpen(hook, groups) {
  hook.beforeUpdate()
  groups.forEach((g) => {
    if (!g.hasAttribute("data-active-group")) g.open = false
  })
  hook.updated()
}

describe("SettingsNavTree hook", () => {
  beforeEach(() => {
    globalThis.localStorage = memoryStorage()
  })

  it("keeps an operator-expanded non-active group open across a re-render", () => {
    const active = makeGroup({id: "sys_cluster", active: true, open: true})
    const security = makeGroup({id: "sys_security", open: false})
    const groups = [active, security]

    const hook = makeTree(groups)
    hook.mounted()

    // Operator expands the Security group (browser sets `open`, fires `toggle`).
    security.open = true
    security._fireToggle()

    // A periodic refresh (e.g. Cluster page's 10s timer) repaints the shell.
    patchStrippingOpen(hook, groups)

    expect(security.open).toBe(true) // regression: was collapsed before the fix
    expect(active.open).toBe(true)
  })

  it("survives repeated re-renders", () => {
    const active = makeGroup({id: "sys_cluster", active: true, open: true})
    const security = makeGroup({id: "sys_security", open: false})
    const groups = [active, security]

    const hook = makeTree(groups)
    hook.mounted()

    security.open = true
    security._fireToggle()

    patchStrippingOpen(hook, groups)
    patchStrippingOpen(hook, groups)
    patchStrippingOpen(hook, groups)

    expect(security.open).toBe(true)
  })

  it("keeps a collapsed group collapsed across a re-render (no forced re-open)", () => {
    // The operator collapses the ACTIVE group; a background refresh must not
    // re-open it every tick.
    const active = makeGroup({id: "sys_cluster", active: true, open: true})
    const groups = [active]

    const hook = makeTree(groups)
    hook.mounted()

    active.open = false
    active._fireToggle()

    // The server still renders the active group `open`, so the patch sets it open.
    hook.beforeUpdate()
    active.open = true
    hook.updated()

    expect(active.open).toBe(false)
  })

  it("does not disturb a group the operator never touched", () => {
    const active = makeGroup({id: "sys_cluster", active: true, open: true})
    const other = makeGroup({id: "sys_alerts", open: false})
    const groups = [active, other]

    const hook = makeTree(groups)
    hook.mounted()

    patchStrippingOpen(hook, groups)

    expect(other.open).toBe(false)
    expect(active.open).toBe(true)
  })
})
