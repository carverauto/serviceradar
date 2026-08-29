import {describe, expect, it, vi} from "vitest"

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

function replacementSvgThatBubblesTo(root) {
  const svg = element()
  const dispatch = svg.dispatch.bind(svg)

  svg.dispatch = (event) => {
    dispatch(event)
    root.dispatch({...event, target: event.target || svg})
  }

  return svg
}

function bubbleToRoot(target, root) {
  const dispatch = target.dispatch.bind(target)

  target.dispatch = (event) => {
    dispatch(event)
    root.dispatch({...event, target: event.target || target})
  }

  return target
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
    svg: bubbleToRoot(svg, root),
    viewXForEvent: (event) => event.clientX,
  }
}

describe("ChartRangeSelectionController", () => {
  it("commits the first drag started on a replacement SVG before a compatible update", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const config = options({root})
    const controller = new ChartRangeSelectionController(config)
    const replacementSvg = replacementSvgThatBubblesTo(root)

    replacementSvg.dispatch(pointer("pointerdown", 0, 9))
    controller.update({...config, bindingKey: "replacement-svg", overlay: element(), svg: replacementSvg})
    documentTarget.dispatch(pointer("pointerup", 100, 9))

    expect(config.emit).toHaveBeenCalledOnce()
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
  })

  it("resolves a detached binding press with compatible current geometry before release", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const staleSvg = element()
    staleSvg.isConnected = false
    const config = {
      ...options({root, svg: staleSvg}),
      viewXForEvent: () => null,
    }
    const controller = new ChartRangeSelectionController(config)

    root.dispatch(pointer("pointerdown", 0, 19))
    controller.update({
      ...config,
      bindingKey: "replacement-geometry",
      overlay: element(),
      svg: element(),
      viewXForEvent: (event) => event.clientX,
    })
    documentTarget.dispatch(pointer("pointerup", 100, 19))

    expect(config.emit).toHaveBeenCalledOnce()
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
  })

  it("restores readiness during a compatible detached-geometry handoff", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const staleSvg = element()
    staleSvg.isConnected = false
    const config = {
      ...options({root, svg: staleSvg}),
      viewXForEvent: () => null,
    }
    const controller = new ChartRangeSelectionController(config)

    root.dispatch(pointer("pointerdown", 0, 25))
    root.setAttribute("aria-disabled", "true")
    root.removeAttribute("tabindex")
    controller.update({
      ...config,
      bindingKey: "replacement-geometry",
      overlay: element(),
      svg: element(),
      viewXForEvent: (event) => event.clientX,
    })

    expect(root.getAttribute("aria-disabled")).toBeNull()
    expect(root.getAttribute("tabindex")).toBe("0")
    expect(root.listenerCount("pointerdown")).toBe(1)

    documentTarget.dispatch(pointer("pointerup", 100, 25))

    expect(config.emit).toHaveBeenCalledOnce()
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
  })

  it.each(["pointerup", "pointercancel"])(
    "cancels a detached binding press released outside before a compatible update (%s)",
    (releaseType) => {
      const documentTarget = element()
      const root = element()
      root.ownerDocument = documentTarget
      const staleSvg = element()
      staleSvg.isConnected = false
      const config = {
        ...options({root, svg: staleSvg}),
        viewXForEvent: () => null,
      }
      const controller = new ChartRangeSelectionController(config)

      root.dispatch(pointer("pointerdown", 0, 24))
      documentTarget.dispatch(pointer(releaseType, 100, 24))
      controller.update({
        ...config,
        bindingKey: "replacement-after-release",
        overlay: element(),
        svg: element(),
        viewXForEvent: (event) => event.clientX,
      })
      documentTarget.dispatch(pointer("pointerup", 100, 24))

      expect(config.emit).not.toHaveBeenCalled()
      expect(documentTarget.totalListenerCount()).toBe(0)
      expect(controller.consumeChartClick()).toBe(false)
    },
  )

  it("cancels a detached binding press that remains outside current geometry", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const staleSvg = element()
    staleSvg.isConnected = false
    const config = {
      ...options({root, svg: staleSvg}),
      viewXForEvent: () => null,
    }
    const controller = new ChartRangeSelectionController(config)

    root.dispatch(pointer("pointerdown", -10, 20))
    controller.update({
      ...config,
      bindingKey: "replacement-geometry",
      overlay: element(),
      svg: element(),
      viewXForEvent: (event) => (event.clientX < 0 ? null : event.clientX),
    })
    documentTarget.dispatch(pointer("pointerup", 100, 20))

    expect(config.emit).not.toHaveBeenCalled()
    expect(documentTarget.totalListenerCount()).toBe(0)
    expect(controller.consumeChartClick()).toBe(false)
  })

  it("leaves a detached binding click unsuppressed without a compatible update", () => {
    const root = element()
    const staleSvg = element()
    staleSvg.isConnected = false
    const config = {
      ...options({root, svg: staleSvg}),
      viewXForEvent: () => null,
    }
    const controller = new ChartRangeSelectionController(config)

    root.dispatch(pointer("pointerdown", 0, 21))
    root.dispatch(pointer("pointerup", 4, 21))

    expect(config.emit).not.toHaveBeenCalled()
    expect(controller.consumeChartClick()).toBe(false)
  })

  it("clears a detached binding press when semantic identity changes or the controller is destroyed", () => {
    const root = element()
    const staleSvg = element()
    staleSvg.isConnected = false
    const config = {
      ...options({root, svg: staleSvg, bindingKey: "initial"}),
      eventKey: "netflow_range_selected",
      viewXForEvent: () => null,
    }
    const controller = new ChartRangeSelectionController(config)

    root.dispatch(pointer("pointerdown", 0, 22))
    controller.update({...config, bindingKey: "different-event", eventKey: "other_range_selected"})
    root.dispatch(pointer("pointerup", 100, 22))

    expect(config.emit).not.toHaveBeenCalled()
    expect(controller.consumeChartClick()).toBe(false)

    root.dispatch(pointer("pointerdown", 0, 23))
    controller.destroy()
    root.dispatch(pointer("pointerup", 100, 23))

    expect(root.totalListenerCount()).toBe(0)
    expect(config.emit).not.toHaveBeenCalled()
  })

  it("commits a release whose first qualifying sample is pointerup", () => {
    const config = options()
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 10))
    config.svg.dispatch(pointer("pointerup", 100, 10))

    expect(config.emit).toHaveBeenCalledOnce()
    expect(controller.consumeChartClick()).toBe(true)
  })

  it("cancels a changed interval gesture and removes its document tracking", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const config = options({root})
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 11))
    controller.update({
      ...config,
      bindingKey: "new-intervals",
      buckets: [
        {x: 0, start: "2026-08-28T10:00:00Z", end: "2026-08-28T10:59:59.999999Z"},
        {x: 100, start: "2026-08-28T12:00:00Z", end: "2026-08-28T12:59:59.999999Z"},
      ],
    })
    documentTarget.dispatch(pointer("pointerup", 100, 11))

    expect(config.emit).not.toHaveBeenCalled()
    expect(documentTarget.totalListenerCount()).toBe(0)
  })

  it("destroy removes root and document listeners for a pending gesture", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const config = options({root})
    const controller = new ChartRangeSelectionController(config)

    config.svg.dispatch(pointer("pointerdown", 0, 12))
    controller.destroy()

    expect(root.totalListenerCount()).toBe(0)
    expect(documentTarget.totalListenerCount()).toBe(0)
  })

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
    expect(first.root.listenerCount("pointerdown")).toBe(1)
    expect(secondSvg.listenerCount("pointerdown")).toBe(0)

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

    expect(config.root.listenerCount("pointerdown")).toBe(1)
    expect(config.root.listenerCount("keydown")).toBe(1)
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
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

  it("restores readiness during an active compatible replacement", () => {
    const documentTarget = element()
    const root = element()
    root.ownerDocument = documentTarget
    const config = options({root})
    const controller = new ChartRangeSelectionController(config)
    const replacementOverlay = element()

    config.svg.dispatch(pointer("pointerdown", 0, 26))
    config.svg.dispatch(pointer("pointermove", 100, 26))
    root.setAttribute("aria-disabled", "true")
    root.removeAttribute("tabindex")
    controller.update({
      ...config,
      bindingKey: "replacement-svg",
      overlay: replacementOverlay,
      svg: element(),
    })

    expect(root.getAttribute("aria-disabled")).toBeNull()
    expect(root.getAttribute("tabindex")).toBe("0")
    expect(root.listenerCount("pointerdown")).toBe(1)
    expect(root.capturedPointers.has(26)).toBe(true)

    documentTarget.dispatch(pointer("pointerup", 100, 26))

    expect(config.emit).toHaveBeenCalledOnce()
    expect(config.emit).toHaveBeenCalledWith({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })
    expect(root.capturedPointers.has(26)).toBe(false)
  })

  it("transfers an in-flight gesture when a redraw replaces the SVG for the same intervals", () => {
    const config = options()
    const controller = new ChartRangeSelectionController(config)
    const replacementSvg = replacementSvgThatBubblesTo(config.root)

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
    const replacementSvg = replacementSvgThatBubblesTo(config.root)

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
