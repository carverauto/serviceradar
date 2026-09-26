import {describe, expect, it, vi} from "vitest"

import ServicePickerKeys from "./ServicePickerKeys"

function makeItem(kind) {
  const item = {
    kind,
    focus: vi.fn(),
    matches: (selector) => selector === `[data-picker-${kind}]`,
  }
  return item
}

function makeHook(items) {
  const listeners = {}
  const el = {
    addEventListener: (name, fn) => {
      listeners[name] = fn
    },
    removeEventListener: vi.fn(),
    querySelectorAll: () => items,
  }
  const hook = Object.create(ServicePickerKeys)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.mounted()
  const keydown = (key, target) => {
    const event = {key, target, preventDefault: vi.fn()}
    listeners.keydown(event)
    return event
  }
  return {hook, keydown}
}

describe("ServicePickerKeys hook", () => {
  it("moves focus from the search field to the first option on ArrowDown", () => {
    const search = makeItem("search")
    const first = makeItem("option")
    const second = makeItem("option")
    const {keydown} = makeHook([search, first, second])

    const event = keydown("ArrowDown", search)

    expect(event.preventDefault).toHaveBeenCalled()
    expect(first.focus).toHaveBeenCalled()
  })

  it("stops at the ends of the list instead of wrapping", () => {
    const search = makeItem("search")
    const only = makeItem("option")
    const {keydown} = makeHook([search, only])

    keydown("ArrowDown", only)
    keydown("ArrowUp", search)

    expect(only.focus).toHaveBeenCalledTimes(1)
    expect(search.focus).toHaveBeenCalledTimes(1)
  })

  it("applies the selection when Enter is pressed on an option", () => {
    const option = makeItem("option")
    const {hook, keydown} = makeHook([makeItem("search"), option])

    const event = keydown("Enter", option)

    expect(event.preventDefault).toHaveBeenCalled()
    expect(hook.pushEvent).toHaveBeenCalledWith("service_picker_apply", {})
  })

  it("leaves Enter in the search field to the form's own submit", () => {
    const search = makeItem("search")
    const {hook, keydown} = makeHook([search])

    const event = keydown("Enter", search)

    expect(event.preventDefault).not.toHaveBeenCalled()
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })
})
