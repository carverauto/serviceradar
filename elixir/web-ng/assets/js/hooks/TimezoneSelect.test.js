import {describe, expect, it} from "vitest"

import TimezoneSelect from "./TimezoneSelect"

function option(value) {
  return {value, remove: () => undefined}
}

function makeHook({current = "America/Chicago", value = current, options = ["Etc/UTC", current, "Mars/Olympus"]} = {}) {
  const datalist = {children: options.map(option), replaceChildren(...next) { this.children = next }}
  const input = {value, dataset: {optionsId: "timezone_catalog", currentTimezone: current}}
  const hook = Object.create(TimezoneSelect)
  hook.el = input
  hook.el.ownerDocument = {getElementById: (id) => id === "timezone_catalog" ? datalist : null}

  return {datalist, hook, input}
}

describe("TimezoneSelect hook", () => {
  it("removes unsupported server-rendered datalist options and preserves the current input", () => {
    const fixture = makeHook()

    fixture.hook.mounted()

    expect(fixture.datalist.children.map(({value}) => value)).toEqual(["Etc/UTC", "America/Chicago"])
    expect(fixture.input.value).toBe("America/Chicago")
  })

  it("preserves user text across LiveView updates", () => {
    const fixture = makeHook({value: "Europe/London"})

    fixture.hook.mounted()
    fixture.input.value = "America/Chicago"
    fixture.hook.updated()

    expect(fixture.input.value).toBe("America/Chicago")
  })
})
