import {describe, expect, it} from "vitest"

import UserTime from "./UserTime"

function makeHook({iso = "2026-08-30T18:00:00.123456Z", timeZone = "America/Chicago", style = "full"} = {}) {
  const attributes = {
    datetime: iso,
    "aria-label": `${iso} UTC; display zone ${timeZone}`,
    title: `${iso} (UTC); display zone ${timeZone}`,
  }
  const el = {
    dataset: {
      userTimeIso: iso,
      userTimeZone: timeZone,
      userTimeStyle: style,
      userTimeFallback: iso,
      userTimeTitle: `${iso} (UTC); display zone ${timeZone}`,
      userTimeAriaLabel: `${iso} UTC; display zone ${timeZone}`,
    },
    textContent: iso,
    getAttribute: (name) => attributes[name] ?? null,
    setAttribute: (name, value) => {
      attributes[name] = value
    },
  }
  const hook = Object.create(UserTime)
  hook.el = el

  return {attributes, el, hook}
}

describe("UserTime hook", () => {
  it("localizes on mount and retains canonical precision in accessibility metadata", () => {
    const fixture = makeHook()

    fixture.hook.mounted()

    expect(fixture.el.textContent).not.toBe("2026-08-30T18:00:00.123456Z")
    expect(fixture.attributes["aria-label"]).toContain("2026-08-30T18:00:00.123456Z")
    expect(fixture.attributes["aria-label"]).toContain("America/Chicago")
    expect(fixture.attributes["aria-label"]).toContain("GMT-5")
  })

  it("synchronizes fresh server metadata before localizing an updated canonical instant", () => {
    const fixture = makeHook()
    fixture.hook.mounted()
    const canonical = "2026-11-01T07:30:00.123456Z"
    fixture.el.dataset.userTimeIso = canonical
    fixture.el.dataset.userTimeFallback = canonical
    fixture.el.dataset.userTimeZone = "America/Chicago"
    fixture.el.dataset.userTimeTitle = `${canonical} (UTC); display zone America/Chicago`
    fixture.el.dataset.userTimeAriaLabel = `${canonical} UTC; display zone America/Chicago`

    fixture.hook.updated()

    expect(fixture.el.textContent).not.toBe(canonical)
    expect(fixture.attributes.datetime).toBe(canonical)
    expect(fixture.attributes.title).toBe(`${canonical} (UTC); display zone America/Chicago`)
    expect(fixture.attributes["aria-label"]).toContain(canonical)
    expect(fixture.attributes["aria-label"]).toContain("GMT-6")
  })

  it("restores fresh server metadata and UTC fallback after a failed update following localization", () => {
    const fixture = makeHook()
    fixture.hook.mounted()
    const canonical = "2026-11-01T07:30:00.123456Z"
    fixture.el.dataset.userTimeIso = canonical
    fixture.el.dataset.userTimeFallback = canonical
    fixture.el.dataset.userTimeZone = "Mars/Olympus"
    fixture.el.dataset.userTimeTitle = `${canonical} (UTC); display zone Mars/Olympus`
    fixture.el.dataset.userTimeAriaLabel = `${canonical} UTC; display zone Mars/Olympus`

    fixture.hook.updated()

    expect(fixture.el.textContent).toBe(canonical)
    expect(fixture.attributes.datetime).toBe(canonical)
    expect(fixture.attributes.title).toBe(`${canonical} (UTC); display zone Mars/Olympus`)
    expect(fixture.attributes["aria-label"]).toBe(`${canonical} UTC; display zone Mars/Olympus`)
  })

  it("restores the server UTC fallback when explicit-zone localization fails", () => {
    const fixture = makeHook({timeZone: "Mars/Olympus"})

    fixture.hook.mounted()

    expect(fixture.el.textContent).toBe("2026-08-30T18:00:00.123456Z")
    expect(fixture.attributes["aria-label"]).toBe(
      "2026-08-30T18:00:00.123456Z UTC; display zone Mars/Olympus",
    )
  })

  it("restores the server UTC fallback when the timezone metadata is absent", () => {
    const fixture = makeHook()
    delete fixture.el.dataset.userTimeZone

    fixture.hook.mounted()

    expect(fixture.el.textContent).toBe("2026-08-30T18:00:00.123456Z")
  })
})
