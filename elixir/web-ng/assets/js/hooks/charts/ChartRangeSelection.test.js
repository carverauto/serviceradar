import {describe, expect, it, vi} from "vitest"

import ChartRangeSelection from "./ChartRangeSelection"

const initialBuckets = [
  {x: 36, start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:59:59.999999Z"},
  {x: 326, start: "2026-08-27T12:00:00Z", end: "2026-08-27T12:59:59.999999Z"},
  {x: 616, start: "2026-08-27T13:00:00Z", end: "2026-08-27T13:59:59.999999Z"},
]

function classList(initial = ["hidden"]) {
  const values = new Set(initial)

  return {
    add: (name) => values.add(name),
    contains: (name) => values.has(name),
    remove: (name) => values.delete(name),
  }
}

function eventTarget(attributes = {}) {
  const listeners = new Map()
  const values = new Map(Object.entries(attributes))

  return {
    classList: classList(),
    dataset: {},
    focused: false,
    listeners,
    capturedPointers: new Set(),
    addEventListener(name, listener) {
      listeners.set(name, listener)
    },
    dispatch(event) {
      listeners.get(event.type)?.(event)
    },
    focus() {
      this.focused = true
    },
    getAttribute(name) {
      return values.get(name) ?? null
    },
    hasAttribute(name) {
      return values.has(name)
    },
    releasePointerCapture(pointerId) {
      this.capturedPointers.delete(pointerId)
    },
    removeAttribute(name) {
      values.delete(name)
    },
    removeEventListener(name, listener) {
      if (listeners.get(name) === listener) listeners.delete(name)
    },
    setAttribute(name, value) {
      values.set(name, String(value))
    },
    setPointerCapture(pointerId) {
      this.capturedPointers.add(pointerId)
    },
  }
}

function pointer(type, clientX, pointerType = "mouse", pointerId = 1) {
  return {
    type,
    clientX,
    pointerId,
    pointerType,
    preventDefault: vi.fn(),
  }
}

function key(key, shiftKey = false) {
  return {key, preventDefault: vi.fn(), shiftKey, type: "keydown"}
}

function rangeElement({buckets = initialBuckets, eventName = "select_events_range"} = {}) {
  const svg = eventTarget({viewBox: "0 0 640 160"})
  svg.getBoundingClientRect = () => ({left: 0, width: 640})
  const overlay = eventTarget()
  const status = eventTarget()
  const root = eventTarget({
    "data-range-buckets": JSON.stringify(buckets),
    "data-range-event": eventName,
    "data-chart-left-pad": "36",
    "data-chart-right-pad": "24",
    "data-chart-width": "640",
  })
  root.dataset = {
    chartLeftPad: "36",
    chartRightPad: "24",
    chartWidth: "640",
    rangeBuckets: JSON.stringify(buckets),
    rangeEvent: eventName,
  }

  root.querySelector = (selector) => {
    if (selector === "[data-range-svg]") return svg
    if (selector === "[data-range-overlay]") return overlay
    if (selector === "[data-range-status]") return status
    return null
  }

  return {overlay, root, status, svg}
}

function mount(options) {
  const chart = rangeElement(options)
  const pushEvent = vi.fn()
  const ctx = {el: chart.root, pushEvent, ...ChartRangeSelection}
  ctx.mounted()
  return {...chart, ctx, pushEvent}
}

function drag(svg, from, to, pointerType = "mouse") {
  svg.dispatch(pointer("pointerdown", from, pointerType))
  svg.dispatch(pointer("pointermove", to, pointerType))
  svg.dispatch(pointer("pointerup", to, pointerType))
}

describe("ChartRangeSelection hook", () => {
  it.each(["mouse", "pen", "touch"])("normalizes %s drags into one emitted range", (pointerType) => {
    const {overlay, pushEvent, root, status, svg} = mount()

    expect(root.getAttribute("tabindex")).toBe("0")
    expect(status.getAttribute("aria-live")).toBe("polite")

    drag(svg, 616, 36, pointerType)

    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T13:59:59.999999Z",
    })
    expect(overlay.getAttribute("x")).toBe("36")
    expect(overlay.getAttribute("width")).toBe("580")
    expect(overlay.classList.contains("hidden")).toBe(false)
  })

  it("renders the same overlay for a forward drag", () => {
    const {overlay, pushEvent, svg} = mount()

    drag(svg, 36, 616)

    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T13:59:59.999999Z",
    })
    expect(overlay.getAttribute("x")).toBe("36")
    expect(overlay.getAttribute("width")).toBe("580")
  })

  it("does not emit sub-threshold, cancelled, or lost-capture drags", () => {
    const {overlay, pushEvent, svg} = mount()

    svg.dispatch(pointer("pointerdown", 36))
    svg.dispatch(pointer("pointermove", 42))
    svg.dispatch(pointer("pointerup", 42))
    svg.dispatch(pointer("pointerdown", 36, "mouse", 2))
    svg.dispatch(pointer("pointermove", 616, "mouse", 2))
    svg.dispatch(pointer("pointercancel", 616, "mouse", 2))
    svg.dispatch(pointer("pointerdown", 36, "mouse", 3))
    svg.dispatch(pointer("pointermove", 616, "mouse", 3))
    svg.dispatch(pointer("lostpointercapture", 616, "mouse", 3))

    expect(pushEvent).not.toHaveBeenCalled()
    expect(overlay.classList.contains("hidden")).toBe(true)
    expect(overlay.hasAttribute("x")).toBe(false)
    expect(overlay.hasAttribute("width")).toBe(false)
  })

  it("implements the approved keyboard selection state machine", () => {
    const {ctx, overlay, pushEvent, root, status} = mount()
    const left = key("ArrowLeft")
    root.dispatch(left)

    expect(left.preventDefault).toHaveBeenCalledOnce()
    expect(overlay.getAttribute("x")).toBe("181")
    expect(overlay.getAttribute("width")).toBe("290")

    const shiftLeft = key("ArrowLeft", true)
    root.dispatch(shiftLeft)

    expect(shiftLeft.preventDefault).toHaveBeenCalledOnce()
    expect(overlay.getAttribute("x")).toBe("36")
    expect(overlay.getAttribute("width")).toBe("435")
    expect(status.textContent).toContain("2026-08-27T10:00:00Z")
    expect(status.textContent).toContain("2026-08-27T12:59:59.999999Z")

    root.dispatch(key("ArrowRight", true))
    root.dispatch(key("ArrowRight", true))
    expect(overlay.getAttribute("x")).toBe("181")
    expect(overlay.getAttribute("width")).toBe("435")

    const enter = key("Enter")
    root.dispatch(enter)
    expect(enter.preventDefault).toHaveBeenCalledOnce()
    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T12:00:00Z",
      end: "2026-08-27T13:59:59.999999Z",
    })

    const escape = key("Escape")
    root.focused = true
    root.dispatch(escape)
    expect(escape.preventDefault).toHaveBeenCalledOnce()
    expect(root.focused).toBe(true)
    expect(overlay.classList.contains("hidden")).toBe(true)
    expect(ctx.rangeAnchorIndex).toBeNull()
    expect(ctx.rangeActiveIndex).toBeNull()
  })

  it("clears stale state and rebinds fresh metadata after a LiveView update", () => {
    const {ctx, overlay, pushEvent, root, status, svg} = mount()
    drag(svg, 36, 616)
    root.dataset = {
      ...root.dataset,
      rangeBuckets: JSON.stringify([
        {x: 36, start: "2026-08-28T10:00:00Z", end: "2026-08-28T10:59:59.999999Z"},
        {x: 616, start: "2026-08-28T12:00:00Z", end: "2026-08-28T12:59:59.999999Z"},
      ]),
    }
    ctx.updated()

    expect(overlay.classList.contains("hidden")).toBe(true)
    expect(status.textContent).toBe("")
    expect(svg.listeners.size).toBe(5)
    drag(svg, 36, 616)
    expect(pushEvent).toHaveBeenLastCalledWith("select_events_range", {
      start: "2026-08-28T10:00:00Z",
      end: "2026-08-28T12:59:59.999999Z",
    })

    ctx.destroyed()
    expect(svg.listeners.size).toBe(0)
    expect(root.listeners.size).toBe(0)
  })

  it("disables itself for malformed metadata", () => {
    const {ctx, pushEvent, root, svg} = mount({buckets: []})

    expect(root.hasAttribute("tabindex")).toBe(false)
    expect(root.getAttribute("aria-disabled")).toBe("true")
    drag(svg, 36, 616)
    root.dispatch(key("Enter"))

    expect(pushEvent).not.toHaveBeenCalled()
    ctx.destroyed()
  })
})
