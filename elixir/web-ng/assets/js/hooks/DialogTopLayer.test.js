import {describe, expect, it, vi} from "vitest"

import DialogTopLayer from "./DialogTopLayer"

function makeDialogHook() {
  let activeElement = null
  const ignoredAttributes = new Set()
  const listeners = new Map()
  const closeButton = {focus: () => (activeElement = closeButton)}
  const input = {focus: () => (activeElement = input)}

  const el = {
    dataset: {},
    open: false,
    addEventListener: (event, listener) => listeners.set(event, listener),
    removeEventListener: (event) => listeners.delete(event),
    querySelector: () => null,
    showModal: vi.fn(() => {
      el.open = true
      closeButton.focus()
    }),
  }

  const ignoreAttributes = vi.fn((_element, attributes) => {
    attributes.forEach((attribute) => ignoredAttributes.add(attribute))
  })

  const hook = Object.create(DialogTopLayer)
  hook.el = el
  hook.js = () => ({ignoreAttributes})

  return {
    activeElement: () => activeElement,
    closeButton,
    el,
    hook,
    ignoreAttributes,
    ignoredAttributes,
    input,
  }
}

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
})
