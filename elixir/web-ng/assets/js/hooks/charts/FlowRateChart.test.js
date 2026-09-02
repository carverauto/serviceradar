import {describe, expect, it} from "vitest"

import {
  contiguousValidSegments,
  contiguousValueRuns,
  flowRateAccessibility,
  flowRateTimeLabel,
  parsePoints,
} from "./FlowRateChart"

describe("FlowRateChart gap handling", () => {
  it("formats axis instants in the root's explicit saved timezone", () => {
    expect(
      flowRateTimeLabel("2026-08-30T18:00:00Z", {
        timeZone: "Pacific/Honolulu",
        locale: "en-US",
      }),
    ).toBe("08:00 AM")
  })

  it("exposes the canonical range and full-offset saved-zone context for the canvas", () => {
    const metadata = flowRateAccessibility(
      [
        {t: "2026-08-30T18:00:00Z", v: 1},
        {t: "2026-08-30T18:05:00Z", v: 2},
      ],
      {timeZone: "Pacific/Honolulu", locale: "en-US"},
    )

    expect(metadata).toMatchObject({
      start: "2026-08-30T18:00:00Z",
      end: "2026-08-30T18:05:00Z",
      timeZone: "Pacific/Honolulu",
    })
    expect(metadata.ariaLabel).toContain("08:00:00 AM")
    expect(metadata.ariaLabel).toMatch(/GMT-10(?::00)?/u)
    expect(metadata.ariaLabel).toContain("2026-08-30T18:00:00Z")
  })

  it("keeps null buckets in the time sequence", () => {
    const points = parsePoints(
      JSON.stringify([
        {t: "2026-01-01T00:00:00Z", v: 10},
        {t: "2026-01-01T00:01:00Z", v: null},
        {t: "2026-01-01T00:02:00Z", v: 20},
      ]),
    )

    expect(points).toEqual([
      {t: "2026-01-01T00:00:00Z", v: 10},
      {t: "2026-01-01T00:01:00Z", v: null},
      {t: "2026-01-01T00:02:00Z", v: 20},
    ])
  })

  it("keeps null sentinels instead of dropping them", () => {
    const points = parsePoints(
      JSON.stringify([
        {t: "2026-06-19T00:00:00Z", v: 10},
        {t: "2026-06-19T00:01:00Z", v: null},
        {t: "2026-06-19T00:02:00Z", v: 30},
      ]),
    )

    expect(points).toEqual([
      {t: "2026-06-19T00:00:00Z", v: 10},
      {t: "2026-06-19T00:01:00Z", v: null},
      {t: "2026-06-19T00:02:00Z", v: 30},
    ])
  })

  it("splits line and area segments at null buckets", () => {
    const points = [
      {t: "a", v: 1},
      {t: "b", v: 2},
      {t: "c", v: null},
      {t: "d", v: 4},
      {t: "e", v: 5},
    ]

    expect(contiguousValueRuns(points)).toEqual([
      [
        {t: "a", v: 1},
        {t: "b", v: 2},
      ],
      [
        {t: "d", v: 4},
        {t: "e", v: 5},
      ],
    ])
  })

  it("splits line segments at missing buckets", () => {
    const segments = contiguousValidSegments([
      {t: "a", v: 10},
      {t: "b", v: 20},
      {t: "c", v: null},
      {t: "d", v: 40},
      {t: "e", v: 50},
    ])

    expect(segments).toEqual([
      [
        {t: "a", v: 10, idx: 0},
        {t: "b", v: 20, idx: 1},
      ],
      [
        {t: "d", v: 40, idx: 3},
        {t: "e", v: 50, idx: 4},
      ],
    ])
  })
})
