import {describe, expect, it} from "vitest"

import {
  timeseriesClientXToPointIndex,
  timeseriesNearestPointIndexByX,
  timeseriesPointIndexToLocalX,
  timeseriesPointToLocalX,
} from "./geometry"

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
    expect(timeseriesPointIndexToLocalX(0, rect, 5)).toBe(36)
    expect(timeseriesPointIndexToLocalX(2, rect, 5)).toBeCloseTo(210)
    expect(timeseriesPointIndexToLocalX(4, rect, 5)).toBe(384)
  })

  it("keeps backwards-compatible symmetric padding overrides", () => {
    expect(timeseriesPointIndexToLocalX(0, rect, 5, {chartPad: 8})).toBe(4)
    expect(timeseriesPointIndexToLocalX(2, rect, 5, {chartPad: 8})).toBe(200)
    expect(timeseriesPointIndexToLocalX(4, rect, 5, {chartPad: 8})).toBe(396)
  })

  it("uses server-provided timestamp x coordinates when present", () => {
    const points = [{x: 72}, {x: 141.6}, {x: 768}]

    expect(timeseriesNearestPointIndexByX(points, 150)).toBe(1)
    expect(timeseriesPointToLocalX(points[1], 1, rect, 3)).toBeCloseTo(70.8)
  })

  it("falls back to index geometry when timestamp x coordinates are absent", () => {
    expect(timeseriesNearestPointIndexByX([{v: 1}, {v: 2}], 150)).toBeNull()
    expect(timeseriesPointToLocalX({v: 2}, 1, rect, 3)).toBeCloseTo(210)
  })
})
