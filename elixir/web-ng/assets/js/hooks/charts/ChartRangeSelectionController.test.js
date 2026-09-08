import {describe, expect, it, vi} from "vitest"

import {netflowRangeSelectionStatus} from "../../netflow_charts/util"
import ChartRangeSelectionController from "./ChartRangeSelectionController"

const buckets = [
  {x: 0, start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:59:59.999999Z"},
  {x: 100, start: "2026-08-27T12:00:00Z", end: "2026-08-27T12:59:59.999999Z"},
]

function classList() {
  const values = new Set(["hidden"])
  return {add: (name) => values.add(name), contains: (name) => values.has(name), remove: (name) => values.delete(name)}
}

function element() {
  const attributes = new Map()
  const listeners = new Map()
  return {
    classList: classList(),
    capturedPointers: new Set(),
    listeners,
    addEventListener(name, listener) {
      const callbacks = listeners.get(name) || new Set()
      callbacks.add(listener)
      listeners.set(name, callbacks)
    },
    dispatch(event) {
      for (const listener of listeners.get(event.type) || []) listener(event)
    },
    getAttribute(name) {
      return attributes.get(name) ?? null
    },
    hasPointerCapture(pointerId) {
      return this.capturedPointers.has(pointerId)
    },
    listenerCount(name) {
      return listeners.get(name)?.size || 0
    },
    releasePointerCapture(pointerId) {
      this.capturedPointers.delete(pointerId)
    },
    removeAttribute(name) {
      attributes.delete(name)
    },
    removeEventListener(name, listener) {
      const callbacks = listeners.get(name)
      callbacks?.delete(listener)
      if (callbacks?.size === 0) listeners.delete(name)
    },
    setAttribute(name, value) {
      attributes.set(name, String(value))
    },
    setPointerCapture(pointerId) {
      this.capturedPointers.add(pointerId)
    },
    totalListenerCount() {
      return [...listeners.values()].reduce((count, callbacks) => count + callbacks.size, 0)
    },
  }
}

function pointer(type, clientX, pointerId = 1) {
  return {clientX, pointerId, type}
}

function options({bindingKey = "buckets-a", buckets: selectedBuckets = buckets, root = element(), svg = element()} = {}) {
  const overlay = element()
  const status = element()
  return {
    bindingKey,
    buckets: selectedBuckets,
    emit: vi.fn(),
    overlay,
    plotBounds: () => ({left: 0, right: 100}),
    root,
    status,
    svg,
    viewXForEvent: (event) => event.clientX,
  }
}

describe("ChartRangeSelectionController", () => {
  it("rebinds to renderer-supplied nodes and geometry when the binding changes", () => {
    const first = options()
    const controller = new ChartRangeSelectionController(first)
    const secondSvg = element()
    const second = {
      ...options({bindingKey: "buckets-b", root: first.root, svg: secondSvg}),
      buckets: [
        {x: 20, start: "2026-08-28T10:00:00Z", end: "2026-08-28T10:59:59.999999Z"},
        {x: 80, start: "2026-08-28T12:00:00Z", end: "2026-08-28T12:59:59.999999Z"},
      ],
      plotBounds: () => ({left: 10, right: 90}),
    }

    first.svg.dispatch(pointer("pointerdown", 0, 4))
    controller.update(second)
    expect(first.svg.totalListenerCount()).toBe(0)
    expect(first.root.capturedPointers.has(4)).toBe(false)
    expect(secondSvg.listenerCount("pointerdown")).toBe(1)

    secondSvg.dispatch(pointer("pointerdown", 20))
    secondSvg.dispatch(pointer("pointerup", 80))

    expect(second.emit).toHaveBeenCalledWith({
      start: "2026-08-28T10:00:00Z",
      end: "2026-08-28T12:59:59.999999Z",
    })
    expect(second.overlay.getAttribute("x")).toBe("10")
    expect(second.overlay.getAttribute("width")).toBe("80")
  })

  it("preserves an unchanged captured gesture without accumulating listeners", () => {
    const config = options()
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 7))
    controller.update({...config})
    controller.update({...config})
    config.svg.dispatch(pointer("pointerup", 100, 7))

    expect(config.svg.listenerCount("pointerdown")).toBe(1)
    expect(config.root.listenerCount("keydown")).toBe(1)
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
  })

  it("formats only the accessible status while emitting the original canonical strings", () => {
    const config = {
      ...options(),
      formatStatus: (range) => netflowRangeSelectionStatus(range, "America/Chicago"),
      statusKey: 1,
    }
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 17))
    config.svg.dispatch(pointer("pointerup", 100, 17))

    expect(config.status.textContent).toContain("GMT-5")
    expect(config.status.textContent).toContain("display zone America/Chicago")
    expect(config.status.textContent).toContain("2026-08-27T10:00:00Z")
    expect(config.status.textContent).toContain("2026-08-27T12:59:59.999999Z")
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })

    controller.update({
      ...config,
      formatStatus: (range) => netflowRangeSelectionStatus(range, "Mars/Olympus"),
      statusKey: 2,
    })

    expect(config.status.textContent).toBe(
      "Selected 2026-08-27T10:00:00Z to 2026-08-27T12:59:59.999999Z; display zone Mars/Olympus; canonical UTC 2026-08-27T10:00:00Z to 2026-08-27T12:59:59.999999Z",
    )
    expect(config.emit).toHaveBeenCalledOnce()
  })

  it("ignores a status-only update while range selection is disabled", () => {
    const config = {...options(), overlay: null, statusKey: 1}
    const controller = new ChartRangeSelectionController(config)

    expect(() => controller.update({...config, statusKey: 2})).not.toThrow()
    expect(config.emit).not.toHaveBeenCalled()
  })

  it("commits an in-flight gesture when a redraw only replaces geometry for the same intervals", () => {
    const config = options()
    const controller = new ChartRangeSelectionController(config)
    const replacementOverlay = element()

    config.svg.dispatch(pointer("pointerdown", 0, 7))
    controller.update({
      ...config,
      bindingKey: "buckets-resized",
      buckets: [
        {...buckets[0], x: 10},
        {...buckets[1], x: 90},
      ],
      overlay: replacementOverlay,
      plotBounds: () => ({left: 10, right: 90}),
    })
    config.svg.dispatch(pointer("pointerup", 90, 7))

    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
    expect(replacementOverlay.getAttribute("x")).toBe("10")
    expect(replacementOverlay.getAttribute("width")).toBe("80")
  })

  it("transfers an in-flight gesture when a redraw replaces the SVG for the same intervals", () => {
    const config = options()
    const controller = new ChartRangeSelectionController(config)
    const replacementSvg = element()

    config.svg.dispatch(pointer("pointerdown", 0, 7))
    config.svg.dispatch(pointer("lostpointercapture", 0, 7))
    controller.update({
      ...config,
      bindingKey: "replacement-svg",
      overlay: element(),
      svg: replacementSvg,
    })
    replacementSvg.dispatch(pointer("pointerup", 100, 7))

    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
    expect(config.root.capturedPointers.has(7)).toBe(false)
  })

  it("tracks a pending gesture on the document while its SVG is replaced", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const config = options({root})
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 7))
    expect(root.capturedPointers.has(7)).toBe(false)

    controller.update({...config, bindingKey: "replacement-svg", overlay: element(), svg: element()})
    documentTarget.dispatch(pointer("pointermove", 100, 7))
    expect(root.capturedPointers.has(7)).toBe(true)

    documentTarget.dispatch(pointer("pointerup", 100, 7))

    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
    expect(root.capturedPointers.has(7)).toBe(false)
    expect(documentTarget.listenerCount("pointerup")).toBe(0)
    expect(documentTarget.listenerCount("click")).toBe(1)
    documentTarget.dispatch({type: "click"})
    expect(documentTarget.totalListenerCount()).toBe(0)
  })

  it("commits the last rendered range when release lands just outside the plot", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const config = {
      ...options({root}),
      viewXForEvent: (event) => (event.outside ? null : event.clientX),
    }
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 9))
    config.svg.dispatch(pointer("pointermove", 100, 9))

    expect(config.overlay.classList.contains("hidden")).toBe(false)
    expect(root.capturedPointers.has(9)).toBe(true)
    expect(documentTarget.listenerCount("pointerup")).toBe(1)

    documentTarget.dispatch({...pointer("pointerup", 100, 9), outside: true})

    expect(config.emit).toHaveBeenCalledOnce()
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
    expect(root.capturedPointers.has(9)).toBe(false)
    expect(documentTarget.listenerCount("pointerup")).toBe(0)
    expect(documentTarget.listenerCount("click")).toBe(1)
    expect(controller.consumeChartClick()).toBe(true)
    expect(documentTarget.totalListenerCount()).toBe(0)
    expect(controller.consumeChartClick()).toBe(false)
  })

  it("clears click suppression when a coalesced drag clicks outside the chart root", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const config = {
      ...options({root}),
      continuationXForEvent: (event) => event.clientX,
      viewXForEvent: (event) => (event.outside ? null : event.clientX),
    }
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 15))
    documentTarget.dispatch({...pointer("pointerup", 100, 15), outside: true})

    expect(config.emit).toHaveBeenCalledOnce()
    expect(documentTarget.listenerCount("click")).toBe(1)
    documentTarget.dispatch({type: "click"})
    expect(documentTarget.listenerCount("click")).toBe(0)
    expect(controller.consumeChartClick()).toBe(false)
  })

  it("does not commit an outside release unless the gesture rendered a valid range", () => {
    const config = {
      ...options(),
      viewXForEvent: (event) => (event.outside ? null : event.clientX),
    }
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 10))
    config.svg.dispatch({...pointer("pointermove", 100, 10), outside: true})
    config.svg.dispatch({...pointer("pointerup", 100, 10), outside: true})

    expect(config.emit).not.toHaveBeenCalled()
    expect(config.overlay.classList.contains("hidden")).toBe(true)
    expect(controller.consumeChartClick()).toBe(false)
  })

  it("does not commit an outside release when invalid bounds prevented rendering", () => {
    const config = {
      ...options(),
      plotBounds: () => null,
      viewXForEvent: (event) => (event.outside ? null : event.clientX),
    }
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 11))
    config.svg.dispatch(pointer("pointermove", 100, 11))
    config.svg.dispatch({...pointer("pointerup", 100, 11), outside: true})

    expect(config.emit).not.toHaveBeenCalled()
    expect(config.overlay.classList.contains("hidden")).toBe(true)
    expect(controller.consumeChartClick()).toBe(false)
  })

  it("does not commit an outside release whose final displacement is below threshold", () => {
    const config = {
      ...options(),
      viewXForEvent: (event) => (event.outside ? null : event.clientX),
    }
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 12))
    config.svg.dispatch(pointer("pointermove", 100, 12))
    config.svg.dispatch({...pointer("pointerup", 4, 12), outside: true})

    expect(config.emit).not.toHaveBeenCalled()
    expect(config.overlay.classList.contains("hidden")).toBe(true)
    expect(controller.consumeChartClick()).toBe(false)
  })

  it("preserves the rendered fallback across a compatible SVG redraw", () => {
    const config = {
      ...options(),
      viewXForEvent: (event) => (event.outside ? null : event.clientX),
    }
    const controller = new ChartRangeSelectionController(config)
    const replacementOverlay = element()
    const replacementSvg = element()

    config.svg.dispatch(pointer("pointerdown", 0, 13))
    config.svg.dispatch(pointer("pointermove", 100, 13))
    controller.update({
      ...config,
      bindingKey: "replacement-svg",
      overlay: replacementOverlay,
      svg: replacementSvg,
    })

    expect(replacementOverlay.classList.contains("hidden")).toBe(false)

    replacementSvg.dispatch({...pointer("pointerup", 100, 13), outside: true})

    expect(config.emit).toHaveBeenCalledOnce()
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
    expect(controller.consumeChartClick()).toBe(true)
  })

  it("clears the rendered fallback when an incompatible update cancels the gesture", () => {
    const config = {
      ...options(),
      eventKey: "netflow_range_selected",
      viewXForEvent: (event) => (event.outside ? null : event.clientX),
    }
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 14))
    config.svg.dispatch(pointer("pointermove", 100, 14))
    controller.update({...config, bindingKey: "different-event", eventKey: "other_range_selected"})
    config.svg.dispatch({...pointer("pointerup", 100, 14), outside: true})

    expect(config.emit).not.toHaveBeenCalled()
    expect(config.overlay.classList.contains("hidden")).toBe(true)
    expect(controller.consumeChartClick()).toBe(false)
  })

  it("ignores bubbled implicit touch capture loss while transferring capture to the stable root", () => {
    const config = options()
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch({...pointer("pointerdown", 0, 7), pointerType: "touch"})
    config.svg.dispatch({...pointer("pointermove", 40, 7), pointerType: "touch"})
    config.root.dispatch({
      ...pointer("lostpointercapture", 40, 7),
      pointerType: "touch",
      target: config.svg,
    })
    config.root.dispatch({...pointer("pointermove", 100, 7), pointerType: "touch"})
    config.root.dispatch({...pointer("pointerup", 100, 7), pointerType: "touch"})

    expect(config.emit).toHaveBeenCalledOnce()
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
    expect(config.root.capturedPointers.has(7)).toBe(false)
    expect(controller.pointer).toBeNull()
  })

  it("clears invalidated metadata and tears down every listener", () => {
    const config = options()
    const controller = new ChartRangeSelectionController(config)
    config.svg.dispatch(pointer("pointerdown", 0, 7))

    controller.update({...config, bindingKey: "invalid", buckets: []})

    expect(config.root.capturedPointers.has(7)).toBe(false)
    expect(config.root.getAttribute("aria-disabled")).toBe("true")
    expect(config.overlay.classList.contains("hidden")).toBe(true)
    expect(config.svg.totalListenerCount()).toBe(0)
    expect(config.root.totalListenerCount()).toBe(0)

    controller.destroy()
    expect(config.svg.totalListenerCount()).toBe(0)
    expect(config.root.totalListenerCount()).toBe(0)
  })

  it("suppresses exactly the immediate click after a committed drag", () => {
    const config = options()
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0))
    config.svg.dispatch(pointer("pointerup", 100))

    expect(controller.consumeChartClick()).toBe(true)
    expect(controller.consumeChartClick()).toBe(false)

    config.svg.dispatch(pointer("pointerdown", 0, 2))
    config.svg.dispatch(pointer("pointerup", 6, 2))
    expect(controller.consumeChartClick()).toBe(false)
  })

  it("leaves a sub-threshold pointer uncaptured so nested chart marks keep the native click target", () => {
    const config = options()
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 20, 5))

    expect(config.root.capturedPointers.has(5)).toBe(false)

    config.svg.dispatch(pointer("pointerup", 24, 5))

    expect(config.emit).not.toHaveBeenCalled()
    expect(controller.consumeChartClick()).toBe(false)
  })
})
