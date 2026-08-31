import {describe, expect, it, vi} from "vitest"

import DetailsState from "./DetailsState"

function makeDetailsHook({open = false} = {}) {
  const el = {open}
  const ignoreAttributes = vi.fn()
  const hook = Object.create(DetailsState)
  hook.el = el
  hook.js = () => ({ignoreAttributes})
  return {el, hook, ignoreAttributes}
}

describe("DetailsState hook", () => {
  it("tells LiveView to ignore the browser-owned open attribute so patches cannot snap a menu shut", () => {
    const fixture = makeDetailsHook({open: true})

    fixture.hook.mounted()

    expect(fixture.ignoreAttributes).toHaveBeenCalledWith(fixture.el, ["open"])
  })

  it("restores open after a LiveView patch that stripped the attribute", () => {
    const fixture = makeDetailsHook({open: true})

    fixture.hook.mounted()
    fixture.hook.beforeUpdate()
    fixture.el.open = false
    fixture.hook.updated()

    expect(fixture.el.open).toBe(true)
  })
})
