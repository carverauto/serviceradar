import {describe, expect, it} from "vitest"

import {finiteSeriesValues, valuesForSeries} from "./BGPTimeSeriesChart"

describe("BGPTimeSeriesChart gap handling", () => {
  const data = [
    {time: "2026-01-01T00:00:00Z", values: {"64512": 100, "64513": 0}},
    {time: "2026-01-01T00:01:00Z", values: {"64512": null}},
    {time: "2026-01-01T00:02:00Z", values: {"64512": 300, "64513": undefined}},
  ]

  it("preserves nulls instead of converting missing samples to zero", () => {
    expect(valuesForSeries(data, "64512")).toEqual([100, null, 300])
    expect(valuesForSeries(data, "64513")).toEqual([0, null, null])
  })

  it("ignores nulls when deriving y-axis domain values", () => {
    expect(finiteSeriesValues(data, ["64512", "64513"])).toEqual([100, 0, 300])
  })
})
