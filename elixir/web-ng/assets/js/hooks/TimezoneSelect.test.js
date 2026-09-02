import {describe, expect, it} from "vitest"

import TimezoneSelect from "./TimezoneSelect"

function classList(initial = []) {
  const classes = new Set(initial)
  return {
    add(name) {
      classes.add(name)
    },
    remove(name) {
      classes.delete(name)
    },
    contains(name) {
      return classes.has(name)
    },
    toggle(name, force) {
      if (force === true) classes.add(name)
      else if (force === false) classes.delete(name)
      else if (classes.has(name)) classes.delete(name)
      else classes.add(name)
      return classes.has(name)
    },
    toArray() {
      return [...classes]
    },
  }
}

function makeItem(timezone) {
  return {
    dataset: {timezone},
    hidden: false,
    classList: classList(),
    setAttribute() {},
    getAttribute() {
      return null
    },
  }
}

function makeHook({
  current = "Etc/UTC",
  value = current,
  options = ["Etc/UTC", "America/Chicago", "Europe/London", "Mars/Olympus"],
} = {}) {
  const items = options.map(makeItem)
  const empty = {hidden: true, classList: classList(["hidden"]), dataset: {}}
  const listbox = {
    children: items,
    classList: classList(["hidden"]),
    hidden: false,
    querySelectorAll(selector) {
      if (selector === "[data-timezone]") return items
      if (selector === "[data-timezone-empty]") return [empty]
      return []
    },
    querySelector(selector) {
      if (selector === "[data-timezone-empty]") return empty
      return null
    },
    addEventListener() {},
    removeEventListener() {},
    setAttribute() {},
  }
  const listeners = {}
  const documentListeners = {}
  const input = {
    value,
    dataset: {optionsId: "timezone_catalog", currentTimezone: current},
    classList: classList(),
    select() {
      this._selected = true
    },
    addEventListener(event, handler) {
      listeners[event] = handler
    },
    removeEventListener(event) {
      delete listeners[event]
    },
    setAttribute() {},
    getAttribute() {
      return null
    },
    ownerDocument: {
      getElementById(id) {
        return id === "timezone_catalog" ? listbox : null
      },
      addEventListener(event, handler) {
        documentListeners[event] = handler
      },
      removeEventListener(event) {
        delete documentListeners[event]
      },
    },
  }
  const hook = Object.create(TimezoneSelect)
  hook.el = input

  return {empty, hook, input, items, listbox, listeners}
}

function visibleZones(fixture) {
  return fixture.items.filter((item) => !item.hidden && !item.classList.contains("hidden")).map((item) => item.dataset.timezone)
}

describe("TimezoneSelect hook", () => {
  it("hides unsupported catalog rows and keeps the current input", () => {
    const fixture = makeHook({current: "America/Chicago", value: "America/Chicago"})

    fixture.hook.mounted()

    expect(visibleZones(fixture)).toEqual(["Etc/UTC", "America/Chicago", "Europe/London"])
    expect(fixture.input.value).toBe("America/Chicago")
    expect(fixture.listbox.classList.contains("hidden")).toBe(true)
  })

  it("opens the full supported catalog on focus even when the field is Etc/UTC", () => {
    const fixture = makeHook()

    fixture.hook.mounted()
    fixture.listeners.focus()

    expect(fixture.listbox.classList.contains("hidden")).toBe(false)
    expect(visibleZones(fixture)).toEqual(["Etc/UTC", "America/Chicago", "Europe/London"])
    expect(fixture.input._selected).toBe(true)
  })

  it("filters to a city match after the user types a different query", () => {
    const fixture = makeHook()

    fixture.hook.mounted()
    fixture.listeners.focus()
    fixture.input.value = "chicago"
    fixture.listeners.input()

    expect(visibleZones(fixture)).toEqual(["America/Chicago"])
    expect(fixture.empty.hidden).toBe(true)
  })

  it("preserves user text across LiveView updates", () => {
    const fixture = makeHook({value: "Europe/London"})

    fixture.hook.mounted()
    fixture.input.value = "America/Chicago"
    fixture.hook.updated()

    expect(fixture.input.value).toBe("America/Chicago")
  })
})
