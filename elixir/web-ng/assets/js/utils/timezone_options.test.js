import {describe, expect, it} from "vitest"

import {filterTimezoneOptions} from "./timezone_options"

const noSupportedValuesOfIntl = {
  DateTimeFormat: class {
    constructor(_locale, {timeZone}) {
      if (timeZone !== "Etc/UTC" && timeZone !== "America/Chicago") throw new RangeError("unsupported zone")
    }
  },
}

describe("filterTimezoneOptions", () => {
  it("keeps UTC and the saved zone when constructor probing rejects a server option", () => {
    expect(filterTimezoneOptions(["America/Chicago", "Mars/Olympus"], "America/Chicago", {intl: noSupportedValuesOfIntl}))
      .toEqual(["Etc/UTC", "America/Chicago"])
  })

  it("retains only UTC and the saved zone when supportedValuesOf is unavailable", () => {
    expect(filterTimezoneOptions(["America/Chicago", "Europe/London"], "America/Chicago", {intl: undefined}))
      .toEqual(["Etc/UTC", "America/Chicago"])
  })

  it("intersects the server catalog with browser values without inventing a zone", () => {
    const intl = {
      supportedValuesOf: () => ["America/Chicago", "Asia/Tokyo"],
      DateTimeFormat: class {
        constructor(_locale, {timeZone}) {
          if (!["Etc/UTC", "America/Chicago", "Europe/London"].includes(timeZone)) throw new RangeError("unsupported zone")
        }
      },
    }

    expect(filterTimezoneOptions(["Europe/London", "Mars/Olympus", "America/Chicago"], "Europe/London", {intl}))
      .toEqual(["Etc/UTC", "America/Chicago", "Europe/London"])
  })
})
