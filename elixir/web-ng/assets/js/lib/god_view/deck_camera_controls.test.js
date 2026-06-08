import {describe, expect, it} from "vitest"

import {deckScale, focalZoomViewState, panViewState, wheelZoomDelta} from "./deck_camera_controls"

function worldPoint(viewState, point) {
  const [targetX = 0, targetY = 0] = viewState.target || [0, 0, 0]
  const scale = deckScale(viewState.zoom)

  return {
    x: targetX + (point.x - point.width / 2) / scale,
    y: targetY + (point.y - point.height / 2) / scale,
  }
}

describe("deck_camera_controls", () => {
  it("focalZoomViewState preserves the world point under the pointer", () => {
    const viewState = {zoom: 1, minZoom: -2, maxZoom: 5, target: [100, 50, 0]}
    const point = {x: 700, y: 350, width: 1000, height: 500}
    const before = worldPoint(viewState, point)

    const next = focalZoomViewState(viewState, point, 1.8)
    const after = worldPoint(next, point)

    expect(next.zoom).toEqual(1.8)
    expect(after.x).toBeCloseTo(before.x, 5)
    expect(after.y).toBeCloseTo(before.y, 5)
  })

  it("focalZoomViewState clamps zoom to the viewState range", () => {
    const viewState = {zoom: 1, minZoom: -1, maxZoom: 2, target: [0, 0, 0]}

    expect(focalZoomViewState(viewState, null, 9).zoom).toEqual(2)
    expect(focalZoomViewState(viewState, null, -9).zoom).toEqual(-1)
  })

  it("panViewState translates the target by screen delta scaled by zoom", () => {
    const next = panViewState({zoom: 2, target: [50, 40, 0]}, 20, -12)

    expect(next.target[0]).toEqual(45)
    expect(next.target[1]).toEqual(43)
  })

  it("wheelZoomDelta normalizes wheel events into bounded zoom steps", () => {
    expect(wheelZoomDelta({deltaY: -10})).toBeCloseTo(0.22)
    expect(wheelZoomDelta({deltaY: 250})).toBeCloseTo(-0.55)
    expect(wheelZoomDelta({deltaY: -1000})).toBeCloseTo(0.66)
  })
})
