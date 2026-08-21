import {describe, expect, it, vi} from "vitest"

import ToastTopLayer from "./ToastTopLayer"

function makeToastHook({message = "", hidden = false} = {}) {
  const listeners = new Map()
  const el = {
    dataset: {toastMessage: message, toastKind: "error"},
    innerHTML: message ? `<p>${message}</p>` : "",
    attributes: hidden ? {hidden: ""} : {},
    hasAttribute: (name) => name in el.attributes,
    matches: (sel) => sel === ":popover-open" && el._open === true,
    addEventListener: (event, listener) => listeners.set(event, listener),
    removeEventListener: (event) => listeners.delete(event),
    showPopover: vi.fn(() => {
      el._open = true
    }),
    hidePopover: vi.fn(() => {
      el._open = false
    }),
    setAttribute: (name, value) => {
      el.attributes[name] = value
    },
    removeAttribute: (name) => {
      delete el.attributes[name]
    },
    click: () => listeners.get("click")?.(),
  }

  const ignoreAttributes = vi.fn()
  const hook = Object.create(ToastTopLayer)
  hook.el = el
  hook.js = () => ({ignoreAttributes})

  return {el, hook, ignoreAttributes}
}

describe("ToastTopLayer hook", () => {
  it("opens a popover when a flash message arrives so it stacks above showModal", () => {
    const fixture = makeToastHook({message: "only one enabled add-on profile"})

    fixture.hook.mounted()

    expect(fixture.ignoreAttributes).toHaveBeenCalledWith(fixture.el, ["popover"])
    expect(fixture.el.showPopover).toHaveBeenCalledOnce()
  })

  it("keeps the last toast after LiveView clears flash (modal dismiss)", () => {
    const fixture = makeToastHook({message: "only one enabled add-on profile"})
    fixture.hook.mounted()

    fixture.el.dataset.toastMessage = ""
    fixture.el.innerHTML = ""
    fixture.hook.updated()

    expect(fixture.el.innerHTML).toContain("only one enabled add-on profile")
    expect(fixture.el.showPopover).toHaveBeenCalled()
    expect(fixture.el.hidePopover).not.toHaveBeenCalled()
  })

  it("does not open hidden reconnect flashes", () => {
    const fixture = makeToastHook({message: "Attempting to reconnect", hidden: true})

    fixture.hook.mounted()

    expect(fixture.el.showPopover).not.toHaveBeenCalled()
  })
})
