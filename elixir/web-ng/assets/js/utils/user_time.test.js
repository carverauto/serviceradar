import {describe, expect, it} from "vitest"

import {
  axisUserTimeFormatter,
  canonicalUtcInstant,
  formatUserTime,
  STYLE_OPTIONS,
  userTimeFormatter,
} from "./user_time"

describe("formatUserTime", () => {
  it("formats chart Date values through the shared explicit-zone contract", () => {
    const formatTooltip = userTimeFormatter({
      timeZone: "America/Chicago",
      style: "tooltip",
      locale: "en-US",
    })
    const label = formatTooltip(new Date("2026-08-30T18:00:00Z"))

    expect(label).toContain("01:00:00 PM")
    expect(label).toContain("GMT-5")
  })

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

    expect(canonicalUtcInstant(canonical)).toBe(canonical)
    expect(canonicalUtcInstant("2026-08-30T13:00:00.123456-05:00")).toBe(canonical)
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

  it("retries shortOffset formatting and derives a numeric offset when the runtime rejects that option", () => {
    const calls = []
    const intl = {
      DateTimeFormat: class {
        constructor(_locale, options) {
          calls.push(options)
          if (options.timeZoneName === "shortOffset") throw new Error("shortOffset unsupported")
          this.options = options
        }

        format() {
          return "Aug 30, 2026, 1:00 PM"
        }

        formatToParts() {
          const values = this.options.timeZone === "America/Chicago"
            ? [2026, 8, 30, 13, 0, 0]
            : [2026, 8, 30, 18, 0, 0]

          return ["year", "month", "day", "hour", "minute", "second"].map((type, index) => ({
            type,
            value: String(values[index]).padStart(2, "0"),
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
    expect(calls.some((options) => options.timeZone === "America/Chicago" && !("timeZoneName" in options))).toBe(true)
    expect(calls).toContainEqual(expect.objectContaining({timeZone: "Etc/UTC", numberingSystem: "latn"}))
    expect(calls).not.toContainEqual(expect.not.objectContaining({timeZone: expect.anything()}))
  })

  it("uses ISO calendar parts for ar-SA offset arithmetic without changing the visible formatter calendar", () => {
    const calls = []
    const intl = {
      DateTimeFormat: class {
        constructor(locale, options) {
          calls.push({locale, options})
          this.options = options
        }

        format() {
          return "١٠ ربيع الأول ١٤٤٨، ١:٠٠ م"
        }

        formatToParts() {
          if (this.options.calendar !== "iso8601") throw new Error("non-ISO arithmetic calendar")

          const values = this.options.timeZone === "America/Chicago"
            ? [2026, 8, 30, 13, 0, 0]
            : [2026, 8, 30, 18, 0, 0]

          return ["year", "month", "day", "hour", "minute", "second"].map((type, index) => ({
            type,
            value: String(values[index]).padStart(2, "0"),
          }))
        }
      },
    }

    const result = formatUserTime("2026-08-30T18:00:00Z", {
      timeZone: "America/Chicago",
      style: "full",
      locale: "ar-SA",
      intl,
    })

    expect(result).toMatchObject({offset: "GMT-05:00"})
    expect(result.text).toContain("GMT-05:00")
    expect(calls[0].locale).toBe("ar-SA")
    expect("calendar" in calls[0].options).toBe(false)
    expect(calls).toContainEqual(expect.objectContaining({options: expect.objectContaining({calendar: "iso8601"})}))
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

  it("rejects zone-less and invalid string axis inputs instead of interpreting them in the host timezone", () => {
    const formatAxis = axisUserTimeFormatter({timeZone: "America/Chicago", locale: "en-US"})

    expect(formatAxis("2026-08-30T18:00:00")).toBe("")
    expect(formatAxis("not-an-instant")).toBe("")
  })

  it("rejects impossible canonical date boundaries before Date can normalize them", () => {
    const formatAxis = axisUserTimeFormatter({timeZone: "America/Chicago", locale: "en-US"})
    const invalid = [
      "2026-02-29T18:00:00Z",
      "2026-02-30T18:00:00Z",
      "2026-04-31T18:00:00Z",
      "2026-01-01T24:00:00Z",
      "2026-01-01T23:60:00Z",
      "2026-01-01T23:59:60Z",
    ]

    for (const iso of invalid) {
      expect(formatUserTime(iso, {timeZone: "America/Chicago"})).toBeNull()
      expect(formatAxis(iso)).toBe("")
    }

    expect(formatUserTime("2024-02-29T18:00:00.123456+00:00", {timeZone: "America/Chicago"})).toMatchObject({
      canonical: "2024-02-29T18:00:00.123456+00:00",
    })
  })
})
