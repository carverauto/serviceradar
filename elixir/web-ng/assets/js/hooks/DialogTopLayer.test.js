import {afterEach, describe, expect, it, vi} from "vitest"

import DialogTopLayer from "./DialogTopLayer"

function makeDialogHook() {
  let activeElement = null
  const ignoredAttributes = new Set()
  const listeners = new Map()
  const closeButton = {focus: () => (activeElement = closeButton)}
  const input = {focus: () => (activeElement = input)}
  const trigger = {focus: vi.fn(() => (activeElement = trigger))}

  const el = {
    dataset: {returnFocus: "#picker-trigger"},
    open: false,
    addEventListener: (event, listener) => listeners.set(event, listener),
    removeEventListener: (event) => listeners.delete(event),
    querySelector: () => null,
    showModal: vi.fn(() => {
      el.open = true
      closeButton.focus()
    }),
    close: vi.fn(() => {
      el.open = false
    }),
  }

  const ignoreAttributes = vi.fn((_element, attributes) => {
    attributes.forEach((attribute) => ignoredAttributes.add(attribute))
  })

  const hook = Object.create(DialogTopLayer)
  hook.el = el
  hook.js = () => ({ignoreAttributes})
  hook.pushEvent = vi.fn()

  return {
    activeElement: () => activeElement,
    closeButton,
    el,
    hook,
    ignoreAttributes,
    ignoredAttributes,
    input,
    trigger,
    listeners,
  }
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("DialogTopLayer hook", () => {
  it("keeps an open dialog and input focus across LiveView patches", () => {
    const fixture = makeDialogHook()

    fixture.hook.mounted()
    fixture.input.focus()

    // The server omits the browser-owned `open` attribute. LiveView would
    // remove it during a form validation patch unless the hook ignores it.
    if (!fixture.ignoredAttributes.has("open")) fixture.el.open = false
    fixture.hook.updated()

    expect(fixture.ignoreAttributes).toHaveBeenCalledOnce()
    expect(fixture.ignoreAttributes).toHaveBeenCalledWith(fixture.el, ["open"])
    expect(fixture.el.showModal).toHaveBeenCalledOnce()
    expect(fixture.el.open).toBe(true)
    expect(fixture.activeElement()).toBe(fixture.input)
  })

  it("restores focus to the stable trigger when LiveView destroys the dialog", () => {
    const fixture = makeDialogHook()

    vi.stubGlobal("document", {
      activeElement: fixture.trigger,
      querySelector: vi.fn(selector =>
        selector === "#picker-trigger" ? fixture.trigger : null
      ),
    })

    fixture.hook.mounted()
    fixture.input.focus()
    fixture.hook.destroyed()

    expect(fixture.trigger.focus).toHaveBeenCalledOnce()
    expect(fixture.activeElement()).toBe(fixture.trigger)
  })

  it("routes Escape and backdrop dismissal through the same server cancel event", () => {
    const fixture = makeDialogHook()
    fixture.el.dataset.cancel = "agent_picker_cancel"
    fixture.hook.mounted()

    const escape = {preventDefault: vi.fn()}
    fixture.listeners.get("cancel")(escape)
    fixture.listeners.get("click")({target: fixture.el})

    expect(escape.preventDefault).toHaveBeenCalledOnce()
    expect(fixture.hook.pushEvent).toHaveBeenNthCalledWith(1, "agent_picker_cancel", {})
    expect(fixture.hook.pushEvent).toHaveBeenNthCalledWith(2, "agent_picker_cancel", {})
  })
})
