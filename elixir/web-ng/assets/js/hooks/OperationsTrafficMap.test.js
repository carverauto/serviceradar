import {describe, expect, it, vi} from "vitest"

import OperationsTrafficMap from "./OperationsTrafficMap"

function classListMock() {
  return {
    add: vi.fn(),
    remove: vi.fn(),
    toggle: vi.fn(),
  }
}

function pointerEvent({x = 100, y = 100, pointerId = 7, button = 0} = {}) {
  return {
    button,
    clientX: x,
    clientY: y,
    pointerId,
    preventDefault: vi.fn(),
    stopPropagation: vi.fn(),
    target: {closest: vi.fn(() => null)},
  }
}

function makeContext() {
  const parentClassList = classListMock()

  return {
    mapView: "netflow",
    currentViewBox: "0 0 100 50",
    autoViewBox: "0 0 100 50",
    dragState: null,
    suppressNextClick: false,
    svgOverlay: {
      getBoundingClientRect: vi.fn(() => ({width: 1000, height: 500})),
      setPointerCapture: vi.fn(),
      releasePointerCapture: vi.fn(),
    },
    el: {
      parentElement: {
        classList: parentClassList,
      },
    },
    _setMapViewBox: vi.fn(),
    parentClassList,
  }
}

describe("OperationsTrafficMap netflow panning", () => {
  it("does not translate the viewBox for a click-sized pointer move", () => {
    const ctx = makeContext()
    const down = pointerEvent()
    const move = pointerEvent({x: 103, y: 102})
    const up = pointerEvent()

    OperationsTrafficMap._onMapPointerDown.call(ctx, down)
    OperationsTrafficMap._onMapPointerMove.call(ctx, move)
    OperationsTrafficMap._onMapPointerUp.call(ctx, up)

    expect(ctx.currentViewBox).toEqual("0 0 100 50")
    expect(ctx._setMapViewBox).not.toHaveBeenCalled()
    expect(ctx.suppressNextClick).toEqual(false)
    expect(ctx.parentClassList.add).not.toHaveBeenCalledWith("is-netflow-panning")
  })

  it("translates the viewBox once pointer movement exceeds the pan threshold", () => {
    const ctx = makeContext()
    const down = pointerEvent()
    const move = pointerEvent({x: 130, y: 115})
    const up = pointerEvent()

    OperationsTrafficMap._onMapPointerDown.call(ctx, down)
    OperationsTrafficMap._onMapPointerMove.call(ctx, move)
    OperationsTrafficMap._onMapPointerUp.call(ctx, up)

    expect(ctx.currentViewBox).not.toEqual("0 0 100 50")
    expect(ctx._setMapViewBox).toHaveBeenCalledWith(ctx.currentViewBox)
    expect(ctx.suppressNextClick).toEqual(true)
    expect(ctx.parentClassList.add).toHaveBeenCalledWith("is-netflow-panning")
    expect(ctx.parentClassList.remove).toHaveBeenCalledWith("is-netflow-panning")
  })
})
