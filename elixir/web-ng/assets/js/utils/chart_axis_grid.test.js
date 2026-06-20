import {scaleLinear} from "d3-scale"
import {describe, expect, it} from "vitest"

import {yGridTicks} from "./chart_axis_grid"

describe("chart axis grid helpers", () => {
  it("returns finite y-axis ticks for a numeric scale", () => {
    const y = scaleLinear().domain([0, 100]).range([80, 0])

    expect(yGridTicks(y, 4)).toEqual([0, 20, 40, 60, 80, 100])
  })

  it("drops ticks that cannot be mapped onto the chart", () => {
    const badScale = (value) => (value === "bad" ? Number.NaN : 1)
    badScale.domain = () => ["good", "bad"]

    expect(yGridTicks(badScale)).toEqual(["good"])
  })
})
