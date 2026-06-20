import {describe, expect, it} from "vitest"

import {bgpSeriesValue, isolatedSeriesPoints} from "./BGPTimeSeriesChart"

describe("BGPTimeSeriesChart gap handling", () => {
  it("preserves missing AS values as null", () => {
    expect(bgpSeriesValue({values: {"64512": 4}}, "64512")).toBe(4)
    expect(bgpSeriesValue({values: {"64512": null}}, "64512")).toBeNull()
    expect(bgpSeriesValue({values: {}}, "64512")).toBeNull()
  })

  it("marks isolated valid points between gaps", () => {
    expect(isolatedSeriesPoints([null, 10, null, 20, 30, null, 40])).toEqual([
      {value: 10, index: 1},
      {value: 40, index: 6},
    ])
  })
})
