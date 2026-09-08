import {describe, expect, it} from "vitest"

import {filterTimezoneOptions, matchingTimezoneOptions} from "./timezone_options"

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

  it("formatter-probes every server-approved candidate when supportedValuesOf is available", () => {
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
    expect(calls).toEqual(expect.arrayContaining(["Europe/London", "Mars/Olympus", "America/Chicago", "Asia/Tokyo"]))
  })

  it("retains a server-approved alias omitted by supportedValuesOf when DateTimeFormat accepts it", () => {
    const intl = {
      supportedValuesOf: () => ["America/Chicago"],
      DateTimeFormat: class {
        constructor(_locale, {timeZone}) {
          if (!["Etc/UTC", "America/Chicago", "US/Central"].includes(timeZone)) {
            throw new RangeError("unsupported zone")
          }
        }
      },
    }

    expect(filterTimezoneOptions(["America/Chicago", "US/Central", "Mars/Olympus"], "America/Chicago", {intl}))
      .toEqual(["Etc/UTC", "America/Chicago", "US/Central"])
  })

  it("retains a saved legacy timezone even when it is absent from the server catalog and browser rejects it", () => {
    expect(filterTimezoneOptions(["America/Chicago"], "Legacy/Removed", {intl: noSupportedValuesOfIntl}))
      .toEqual(["Etc/UTC", "America/Chicago", "Legacy/Removed"])
  })
})

describe("matchingTimezoneOptions", () => {
  const catalog = ["Etc/UTC", "Africa/Abidjan", "America/Chicago", "America/New_York", "Europe/London"]

  it("shows the full catalog when the field still holds the saved timezone", () => {
    expect(matchingTimezoneOptions(catalog, "Etc/UTC", "Etc/UTC")).toEqual(catalog)
  })

  it("shows the full catalog when the query is empty", () => {
    expect(matchingTimezoneOptions(catalog, "", "Etc/UTC")).toEqual(catalog)
  })

  it("filters by city or region substring once the user types a different query", () => {
    expect(matchingTimezoneOptions(catalog, "chicago", "Etc/UTC")).toEqual(["America/Chicago"])
    expect(matchingTimezoneOptions(catalog, "New York", "Etc/UTC")).toEqual(["America/New_York"])
  })
})
