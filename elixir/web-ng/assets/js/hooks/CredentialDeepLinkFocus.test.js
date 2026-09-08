import {afterEach, describe, expect, it, vi} from "vitest"

import CredentialDeepLinkFocus from "./CredentialDeepLinkFocus"

function makeHook(focused = "true") {
  const calls = []
  let frameCallback = null

  const el = {
    dataset: {focused},
    focus: vi.fn(options => calls.push(["focus", options])),
    scrollIntoView: vi.fn(options => calls.push(["scroll", options])),
  }

  const requestAnimationFrame = vi.fn(callback => {
    frameCallback = callback
    return 17
  })

  const cancelAnimationFrame = vi.fn()
  vi.stubGlobal("requestAnimationFrame", requestAnimationFrame)
  vi.stubGlobal("cancelAnimationFrame", cancelAnimationFrame)

  const hook = Object.create(CredentialDeepLinkFocus)
  hook.el = el

  return {
    calls,
    cancelAnimationFrame,
    el,
    flushFrame: () => frameCallback?.(),
    hook,
    requestAnimationFrame,
  }
}

afterEach(() => vi.unstubAllGlobals())

describe("CredentialDeepLinkFocus hook", () => {
  it("scrolls and focuses a targeted row after LiveView inserts it", () => {
    const fixture = makeHook()

    fixture.hook.mounted()
    expect(fixture.requestAnimationFrame).toHaveBeenCalledOnce()

    fixture.flushFrame()

    expect(fixture.calls).toEqual([
      ["scroll", {block: "center", inline: "nearest"}],
      ["focus", {preventScroll: true}],
    ])
  })

  it("does nothing for an unfocused credential row", () => {
    const fixture = makeHook("false")

    fixture.hook.mounted()

    expect(fixture.requestAnimationFrame).not.toHaveBeenCalled()
    expect(fixture.el.scrollIntoView).not.toHaveBeenCalled()
    expect(fixture.el.focus).not.toHaveBeenCalled()
  })

  it("focuses a reused row when a later patch targets it", () => {
    const fixture = makeHook("false")

    fixture.hook.mounted()
    fixture.el.dataset.focused = "true"
    fixture.hook.updated()
    fixture.flushFrame()

    expect(fixture.el.scrollIntoView).toHaveBeenCalledOnce()
    expect(fixture.el.focus).toHaveBeenCalledOnce()
  })

  it("does not steal focus again on unrelated patches", () => {
    const fixture = makeHook()

    fixture.hook.mounted()
    fixture.flushFrame()
    fixture.hook.updated()

    expect(fixture.requestAnimationFrame).toHaveBeenCalledOnce()
    expect(fixture.el.scrollIntoView).toHaveBeenCalledOnce()
    expect(fixture.el.focus).toHaveBeenCalledOnce()
  })

  it("cancels pending focus work when LiveView removes the row", () => {
    const fixture = makeHook()

    fixture.hook.mounted()
    fixture.hook.destroyed()

    expect(fixture.cancelAnimationFrame).toHaveBeenCalledWith(17)
  })
})
