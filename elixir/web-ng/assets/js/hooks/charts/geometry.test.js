import {describe, expect, it} from "vitest"

import {timeseriesClientXToPointIndex, timeseriesPointIndexToLocalX} from "./geometry"

describe("timeseries hover geometry", () => {
  const rect = {left: 100, width: 400}

  it("maps pointer x with the same padded viewBox geometry as idx_to_x", () => {
    expect(timeseriesClientXToPointIndex(104, rect, 5)).toBe(0)
    expect(timeseriesClientXToPointIndex(300, rect, 5)).toBe(2)
    expect(timeseriesClientXToPointIndex(496, rect, 5)).toBe(4)
  })

  it("clamps outside pointer x to the nearest rendered endpoint", () => {
    expect(timeseriesClientXToPointIndex(0, rect, 5)).toBe(0)
    expect(timeseriesClientXToPointIndex(800, rect, 5)).toBe(4)
  })

  it("maps point indices back to rendered local x positions", () => {
    expect(timeseriesPointIndexToLocalX(0, rect, 5)).toBe(18)
    expect(timeseriesPointIndexToLocalX(2, rect, 5)).toBeCloseTo(203)
    expect(timeseriesPointIndexToLocalX(4, rect, 5)).toBe(388)
  })

  it("keeps backwards-compatible symmetric padding overrides", () => {
    expect(timeseriesPointIndexToLocalX(0, rect, 5, {chartPad: 8})).toBe(4)
    expect(timeseriesPointIndexToLocalX(2, rect, 5, {chartPad: 8})).toBe(200)
    expect(timeseriesPointIndexToLocalX(4, rect, 5, {chartPad: 8})).toBe(396)
  })
})
