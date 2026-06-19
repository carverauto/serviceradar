import {describe, expect, it} from "vitest"

import {bgpSeriesValue} from "./BGPTimeSeriesChart"

describe("BGPTimeSeriesChart gap handling", () => {
  it("preserves missing AS values as null", () => {
    expect(bgpSeriesValue({values: {"64512": 4}}, "64512")).toBe(4)
    expect(bgpSeriesValue({values: {"64512": null}}, "64512")).toBeNull()
    expect(bgpSeriesValue({values: {}}, "64512")).toBeNull()
  })
})
