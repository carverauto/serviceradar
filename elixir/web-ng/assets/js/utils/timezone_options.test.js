import {describe, expect, it} from "vitest"

import {filterTimezoneOptions} from "./timezone_options"

const noSupportedValuesOfIntl = {
  DateTimeFormat: class {
    constructor(_locale, {timeZone}) {
      if (!["Etc/UTC", "America/Chicago", "Europe/London"].includes(timeZone)) throw new RangeError("unsupported zone")
    }
  },
}

describe("filterTimezoneOptions", () => {
  it("constructor-probes every server-approved option when supportedValuesOf is absent", () => {
    const calls = []
    const intl = {
      DateTimeFormat: class {
        constructor(_locale, {timeZone}) {
          calls.push(timeZone)
          if (!["Etc/UTC", "America/Chicago", "Europe/London"].includes(timeZone)) throw new RangeError("unsupported zone")
        }
      },
    }

    expect(filterTimezoneOptions(["America/Chicago", "Europe/London", "Mars/Olympus"], "America/Chicago", {intl}))
      .toEqual(["Etc/UTC", "America/Chicago", "Europe/London"])
    expect(calls).toEqual(expect.arrayContaining(["America/Chicago", "Europe/London", "Mars/Olympus"]))
  })

  it("constructor-probes every server-approved option when supportedValuesOf throws", () => {
    const calls = []
    const intl = {
      supportedValuesOf: () => {
        throw new Error("unsupported API")
      },
      DateTimeFormat: class {
        constructor(_locale, {timeZone}) {
          calls.push(timeZone)
          if (!["Etc/UTC", "America/Chicago", "Europe/London"].includes(timeZone)) throw new RangeError("unsupported zone")
        }
      },
    }

    expect(filterTimezoneOptions(["America/Chicago", "Europe/London", "Mars/Olympus"], "America/Chicago", {intl}))
      .toEqual(["Etc/UTC", "America/Chicago", "Europe/London"])
    expect(calls).toEqual(expect.arrayContaining(["America/Chicago", "Europe/London", "Mars/Olympus"]))
  })

  it("retains only UTC and the saved zone when supportedValuesOf is unavailable", () => {
    expect(filterTimezoneOptions(["America/Chicago", "Europe/London"], "America/Chicago", {intl: undefined}))
      .toEqual(["Etc/UTC", "America/Chicago"])
  })

  it("intersects the server catalog with browser values without inventing a zone", () => {
    const calls = []
    const intl = {
      supportedValuesOf: () => ["America/Chicago", "Asia/Tokyo"],
      DateTimeFormat: class {
        constructor(_locale, {timeZone}) {
          calls.push(timeZone)
          if (!["Etc/UTC", "America/Chicago", "Europe/London"].includes(timeZone)) throw new RangeError("unsupported zone")
        }
      },
    }

    expect(filterTimezoneOptions(["Europe/London", "Mars/Olympus", "America/Chicago", "Asia/Tokyo"], "Europe/London", {intl}))
      .toEqual(["Etc/UTC", "America/Chicago", "Europe/London"])
    expect(calls).toEqual(expect.arrayContaining(["America/Chicago", "Asia/Tokyo"]))
    expect(calls).not.toContain("Europe/London")
  })

  it("retains a saved legacy timezone even when it is absent from the server catalog and browser rejects it", () => {
    expect(filterTimezoneOptions(["America/Chicago"], "Legacy/Removed", {intl: noSupportedValuesOfIntl}))
      .toEqual(["Etc/UTC", "America/Chicago", "Legacy/Removed"])
  })
})
