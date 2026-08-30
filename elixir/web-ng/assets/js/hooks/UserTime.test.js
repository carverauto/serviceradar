import {describe, expect, it} from "vitest"

import UserTime from "./UserTime"

function makeHook({iso = "2026-08-30T18:00:00.123456Z", timeZone = "America/Chicago", style = "full"} = {}) {
  const attributes = {
    "aria-label": `${iso} UTC; display zone ${timeZone}`,
    title: `${iso} (UTC); display zone ${timeZone}`,
  }
  const el = {
    dataset: {userTimeIso: iso, userTimeZone: timeZone, userTimeStyle: style},
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

  it("reformats updated server markup without replacing its canonical instant", () => {
    const fixture = makeHook()
    fixture.hook.mounted()
    fixture.el.dataset.userTimeIso = "2026-11-01T07:30:00.123456Z"
    fixture.el.dataset.userTimeZone = "America/Chicago"
    fixture.el.textContent = "2026-11-01T07:30:00.123456Z"

    fixture.hook.updated()

    expect(fixture.attributes["aria-label"]).toContain("2026-11-01T07:30:00.123456Z")
    expect(fixture.attributes["aria-label"]).toContain("GMT-6")
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
