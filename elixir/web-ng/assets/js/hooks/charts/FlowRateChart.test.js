import {describe, expect, it} from "vitest"

import {contiguousValueRuns, parsePoints} from "./FlowRateChart"

describe("FlowRateChart gap handling", () => {
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
})
