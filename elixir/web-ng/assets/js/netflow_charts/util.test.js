import * as d3 from "d3"
import {describe, expect, it} from "vitest"

import {clientXToScaleX, yTickValues} from "./util"

describe("netflow tooltip geometry", () => {
  const rect = {left: 100, width: 500}
  const xScale = {range: () => [0, 356]}

  it("subtracts translated plot offsets before x-scale inversion", () => {
    expect(clientXToScaleX(154, rect, xScale, {xOffset: 44})).toBe(10)
    expect(clientXToScaleX(322, rect, xScale, {xOffset: 44})).toBe(178)
  })

  it("clamps to the actual x-scale range", () => {
    expect(clientXToScaleX(120, rect, xScale, {xOffset: 44})).toBe(0)
    expect(clientXToScaleX(600, rect, xScale, {xOffset: 44})).toBe(356)
  })
})

describe("chart axis helpers", () => {
  it("derives finite y-axis tick values from a linear scale", () => {
    const scale = d3.scaleLinear().domain([0, 987]).nice()

    expect(yTickValues(scale, 4)).toEqual([0, 200, 400, 600, 800, 1000])
  })

  it("rejects missing or non-finite tick values", () => {
    expect(yTickValues(null, 4)).toEqual([])
    expect(yTickValues({ticks: () => [0, Number.NaN, Number.POSITIVE_INFINITY, 3]}, 4)).toEqual([0, 3])
  })
})
