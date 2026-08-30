import {describe, expect, it} from "vitest"

import {axisUserTimeFormatter, formatUserTime, STYLE_OPTIONS} from "./user_time"

describe("formatUserTime", () => {
  it.each([
    ["2026-11-01T06:30:00Z", "GMT-5"],
    ["2026-11-01T07:30:00Z", "GMT-6"],
    ["2026-03-08T07:30:00Z", "GMT-6"],
    ["2026-03-08T08:30:00Z", "GMT-5"],
  ])("uses IANA DST rules for %s", (iso, offset) => {
    const result = formatUserTime(iso, {timeZone: "America/Chicago", style: "full", locale: "en-US"})

    expect(result.text).toContain(offset)
    expect(result.offset).toContain(offset)
    expect(result.canonical).toBe(iso)
  })

  it("preserves canonical fractional precision instead of deriving it from Date", () => {
    const canonical = "2026-08-30T18:00:00.123456Z"

    expect(formatUserTime(canonical, {timeZone: "America/Chicago", style: "full", locale: "en-US"})).toMatchObject({
      canonical,
    })
  })

  it("requires an explicit IANA timezone and a named style", () => {
    expect(formatUserTime("2026-08-30T18:00:00Z", {style: "full"})).toBeNull()
    expect(formatUserTime("2026-08-30T18:00:00Z", {timeZone: "America/Chicago", style: "custom"})).toBeNull()
  })

  it("returns null for invalid instants and Intl failures", () => {
    const throwsOnConstruction = {DateTimeFormat: class { constructor() { throw new Error("unsupported") } }}
    const throwsOnFormat = {
      DateTimeFormat: class {
        constructor() {}
        format() {
          throw new Error("format failed")
        }
      },
    }

    expect(formatUserTime("not-an-instant", {timeZone: "America/Chicago"})).toBeNull()
    expect(formatUserTime("2026-08-30T18:00:00Z", {timeZone: "Mars/Olympus"})).toBeNull()
    expect(formatUserTime("2026-08-30T18:00:00Z", {timeZone: "America/Chicago", intl: {}})).toBeNull()
    expect(formatUserTime("2026-08-30T18:00:00Z", {timeZone: "America/Chicago", intl: throwsOnConstruction})).toBeNull()
    expect(formatUserTime("2026-08-30T18:00:00Z", {timeZone: "America/Chicago", intl: throwsOnFormat})).toBeNull()
  })

  it("uses a formatted-parts numeric offset fallback without implicit local time", () => {
    const calls = []
    const intl = {
      DateTimeFormat: class {
        constructor(_locale, options) {
          calls.push(options)
          this.options = options
        }

        format() {
          return this.options.timeZoneName === "shortOffset" ? "Aug 30, 2026, 1:00 PM CDT" : "Aug 30, 2026, 1:00 PM"
        }

        formatToParts() {
          if (this.options.timeZoneName === "shortOffset") return [{type: "timeZoneName", value: "CDT"}]

          const parts = this.options.timeZone === "America/Chicago"
            ? [2026, 8, 30, 13, 0, 0]
            : [2026, 8, 30, 18, 0, 0]

          return ["year", "month", "day", "hour", "minute", "second"].map((type, index) => ({
            type,
            value: String(parts[index]).padStart(2, "0"),
          }))
        }
      },
    }

    const result = formatUserTime("2026-08-30T18:00:00Z", {
      timeZone: "America/Chicago",
      style: "full",
      intl,
    })

    expect(result).toMatchObject({offset: "GMT-05:00"})
    expect(result.text).toContain("GMT-05:00")
    expect(calls).not.toContainEqual(expect.not.objectContaining({timeZone: expect.anything()}))
  })

  it("keeps offsets out of axis labels while preserving them for full and tooltip labels", () => {
    const options = {timeZone: "America/Chicago", locale: "en-US"}

    expect(STYLE_OPTIONS.axis.timeZoneName).toBeUndefined()
    expect(formatUserTime("2026-08-30T18:00:00Z", {...options, style: "axis"}).text).not.toContain("GMT")
    expect(formatUserTime("2026-08-30T18:00:00Z", {...options, style: "full"}).text).toContain("GMT")
    expect(formatUserTime("2026-08-30T18:00:00Z", {...options, style: "tooltip"}).text).toContain("GMT")
  })

  it("formats chart axis input values without changing them", () => {
    const input = new Date("2026-08-30T18:00:00Z")
    const formatAxis = axisUserTimeFormatter({timeZone: "America/Chicago", locale: "en-US"})

    expect(formatAxis(input)).toBeTruthy()
    expect(input.toISOString()).toBe("2026-08-30T18:00:00.000Z")
  })
})
