import {describe, expect, it, vi} from "vitest"
import {Window} from "happy-dom"

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
      const callbacks = listeners.get(name) || new Set()
      callbacks.add(listener)
      listeners.set(name, callbacks)
    },
    dispatch(event) {
      for (const listener of listeners.get(event.type) || []) listener(event)
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
      const callbacks = listeners.get(name)
      if (!callbacks) return

      callbacks.delete(listener)
      if (callbacks.size === 0) listeners.delete(name)
    },
    setAttribute(name, value) {
      values.set(name, String(value))
    },
    setPointerCapture(pointerId) {
      this.capturedPointers.add(pointerId)
    },
    listenerCount(name) {
      return listeners.get(name)?.size || 0
    },
    totalListenerCount() {
      return [...listeners.values()].reduce((total, callbacks) => total + callbacks.size, 0)
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

function rangeElement({buckets = initialBuckets, eventName = "select_events_range", timeZone = "Etc/UTC", axisTimes = []} = {}) {
  const svg = eventTarget({viewBox: "0 0 640 160"})
  svg.getBoundingClientRect = () => ({left: 0, width: 640})
  const overlay = eventTarget()
  const status = eventTarget()
  const root = eventTarget({
    "data-range-buckets": JSON.stringify(buckets),
    "data-range-event": eventName,
    "data-timezone": timeZone,
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
    timezone: timeZone,
  }

  root.querySelector = (selector) => {
    if (selector === "[data-range-svg]") return svg
    if (selector === "[data-range-overlay]") return overlay
    if (selector === "[data-range-status]") return status
    return null
  }
  const labels = axisTimes.map((iso, index) => {
    const label = eventTarget({x: String(36 + index * 80)})
    label.dataset.timeAxisIso = iso
    return label
  })
  const grid = labels.map(() => eventTarget())
  root.querySelectorAll = (selector) => {
    if (selector === "[data-time-axis-iso]") return labels
    if (selector === "[data-time-axis-grid]") return grid
    return []
  }

  return {overlay, root, status, svg, labels, grid}
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
  it("localizes the nested Events SVG on mount and after a whole server-rendered chart replacement", () => {
    const window = new Window()
    const {document} = window
    const chart = (dates) => `
      <div id="dashboard-events-range-selector" phx-hook="ChartRangeSelection"
        data-timezone="America/Chicago" data-range-event="select_events_range"
        data-range-buckets='${JSON.stringify(initialBuckets)}'
        data-chart-width="640" data-chart-left-pad="36" data-chart-right-pad="24">
        <svg data-range-svg viewBox="0 0 640 220">
          <g>${dates.map(() => '<line data-time-axis-grid x1="36" x2="36"/>').join("")}</g>
          <g class="sr-ops-events-axis">${dates.map((iso, index) => `<text id="event-axis-${index}" data-time-axis-iso="${iso}" data-time-axis-fallback="UTC tick ${index}" x="${36 + index * 80}">UTC tick ${index}</text>`).join("")}</g>
          <rect data-range-overlay class="hidden"/>
        </svg>
        <span data-range-status></span>
      </div>`
    document.body.innerHTML = chart(["2030-01-01T10:00:00Z", "2030-01-01T12:00:00Z"])
    const root = document.querySelector("#dashboard-events-range-selector")
    const ctx = {el: root, pushEvent: vi.fn(), ...ChartRangeSelection}
    const labels = () => Array.from(root.querySelectorAll(".sr-ops-events-axis text"))
    ctx.mounted()
    expect(labels().map((node) => node.textContent)).toEqual(["04:00 AM", "06:00 AM"])

    const replacement = document.createElement("div")
    replacement.innerHTML = chart(["2030-01-01T12:00:00Z", "2030-01-16T12:00:00Z", "2030-04-01T12:00:00Z"])
    root.innerHTML = replacement.firstElementChild.innerHTML
    ctx.updated()
    expect(labels().map((node) => node.textContent)).toEqual(["Jan 2030", "Jan 2030", "Apr 2030"])
    expect(labels().map((node) => node.getAttribute("visibility"))).toEqual(["visible", "hidden", "visible"])
    expect(root.querySelectorAll("[data-time-axis-grid][visibility='hidden']").length).toBe(1)
    root.dataset.timezone = "Mars/Olympus"
    ctx.updated()
    expect(labels().map((node) => node.textContent)).toEqual(["UTC tick 0", "UTC tick 1", "UTC tick 2"])
    expect(labels().every((node) => node.textContent !== node.dataset.timeAxisIso)).toBe(true)
    ctx.destroyed()
    window.happyDOM.cancelAsync()
  })

  it.each([
    [["2030-01-01", "2030-01-07", "2030-01-31"], ["Jan 1", "Jan 7", "Jan 31"]],
    [["2030-01-01", "2030-01-16", "2030-02-01", "2030-02-16", "2030-03-01", "2030-03-16", "2030-04-01"], ["Jan 2030", "Feb 2030", "Mar 2030", "Apr 2030"]],
    [["2027-01-01", "2027-07-01", "2028-01-01", "2029-01-01", "2030-01-01"], ["2027", "2028", "2029", "2030"]],
  ])("uses unique calendar labels for long event windows %j", (dates, expected) => {
    const {labels, grid, pushEvent} = mount({axisTimes: dates.map((date) => `${date}T12:00:00Z`)})
    const visible = labels.filter((label) => label.getAttribute("visibility") === "visible")

    expect(visible.map((label) => label.textContent)).toEqual(expected)
    expect(grid.map((line) => line.getAttribute("visibility"))).toEqual(labels.map((label) => label.getAttribute("visibility")))
    expect(labels.map((label) => label.getAttribute("x"))).toEqual(dates.map((_, index) => String(36 + index * 80)))
    expect(pushEvent).not.toHaveBeenCalled()
  })

  it("uses the viewer timezone and restores hidden ticks when returning to hours", () => {
    const {ctx, labels, grid} = mount({
      timeZone: "America/Chicago",
      axisTimes: ["2030-01-01T00:00:00Z", "2030-01-16T00:00:00Z", "2030-02-01T00:00:00Z", "2030-04-01T00:00:00Z"],
    })

    expect(labels[0].textContent).toBe("Dec 2029")
    expect(labels[2].getAttribute("visibility")).toBe("hidden")
    labels.forEach((label, index) => { label.dataset.timeAxisIso = `2030-04-01T${String(10 + index).padStart(2, "0")}:00:00Z` })
    ctx.updated()

    expect(labels.every((label) => label.getAttribute("visibility") === "visible")).toBe(true)
    expect(grid.every((line) => line.getAttribute("visibility") === "visible")).toBe(true)
    expect(labels.map((label) => label.textContent)).toEqual(["05:00 AM", "06:00 AM", "07:00 AM", "08:00 AM"])
  })

  it("commits the latest focused bucket when Enter is pressed initially", () => {
    const {pushEvent, root} = mount()
    const enter = key("Enter")

    root.dispatch(enter)

    expect(enter.preventDefault).toHaveBeenCalledOnce()
    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T13:00:00Z",
      end: "2026-08-27T13:59:59.999999Z",
    })
  })

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

  it("localizes accessible status in the selected zone while emitting canonical UTC bounds", () => {
    const {pushEvent, status, svg} = mount({timeZone: "America/Chicago"})

    drag(svg, 36, 616)

    expect(status.textContent).toContain("GMT-5")
    expect(status.textContent).toContain("display zone America/Chicago")
    expect(status.textContent).toContain("2026-08-27T10:00:00Z")
    expect(status.textContent).toContain("2026-08-27T13:59:59.999999Z")
    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T13:59:59.999999Z",
    })
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

  it.each([
    {
      buckets: [initialBuckets[0]],
      label: "a one-bucket chart",
      startX: 36,
      endX: 43,
    },
    {
      buckets: initialBuckets,
      label: "one bucket of a multi-bucket chart",
      startX: 36,
      endX: 43,
    },
  ])("commits a drag over 6px within $label", ({buckets, startX, endX}) => {
    const {pushEvent, svg} = mount({buckets})

    drag(svg, startX, endX)

    expect(pushEvent).toHaveBeenCalledOnce()
    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T10:59:59.999999Z",
    })
  })

  it("commits a fast drag when qualifying displacement first arrives on pointerup", () => {
    const {pushEvent, svg} = mount()

    svg.dispatch(pointer("pointerdown", 36))
    svg.dispatch(pointer("pointerup", 616))

    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T13:59:59.999999Z",
    })
  })

  it("preserves a captured gesture across an unrelated LiveView update", () => {
    const {ctx, pushEvent, svg} = mount()

    svg.dispatch(pointer("pointerdown", 36, "mouse", 8))
    ctx.updated()
    svg.dispatch(pointer("pointerup", 616, "mouse", 8))

    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T13:59:59.999999Z",
    })
  })

  it("does not emit sub-threshold, cancelled, or lost-capture drags", () => {
    const {overlay, pushEvent, root, svg} = mount()

    svg.dispatch(pointer("pointerdown", 36))
    svg.dispatch(pointer("pointermove", 42))
    svg.dispatch(pointer("pointerup", 42))
    svg.dispatch(pointer("pointerdown", 36, "mouse", 2))
    svg.dispatch(pointer("pointermove", 616, "mouse", 2))
    svg.dispatch(pointer("pointercancel", 616, "mouse", 2))
    svg.dispatch(pointer("pointerdown", 36, "mouse", 3))
    svg.dispatch(pointer("pointermove", 616, "mouse", 3))
    root.dispatch(pointer("lostpointercapture", 616, "mouse", 3))

    expect(pushEvent).not.toHaveBeenCalled()
    expect(overlay.classList.contains("hidden")).toBe(true)
    expect(overlay.hasAttribute("x")).toBe(false)
    expect(overlay.hasAttribute("width")).toBe(false)
  })

  it("implements the approved keyboard selection state machine", () => {
    const {overlay, pushEvent, root, status} = mount()
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
  })

  it("Escape cancels transient state while retaining the active cursor", () => {
    const {ctx, overlay, pushEvent, root, status, svg} = mount()
    svg.dispatch(pointer("pointerdown", 36, "mouse", 8))
    svg.dispatch(pointer("pointermove", 326, "mouse", 8))
    expect(ctx.rangeController.activeIndex).toBe(1)
    expect(root.capturedPointers.has(8)).toBe(true)

    const escape = key("Escape")
    root.focused = true
    root.dispatch(escape)

    expect(escape.preventDefault).toHaveBeenCalledOnce()
    expect(root.focused).toBe(true)
    expect(root.capturedPointers.has(8)).toBe(false)
    expect(ctx.rangeController.pointer).toBeNull()
    expect(ctx.rangeController.anchorIndex).toBeNull()
    expect(ctx.rangeController.activeIndex).toBe(1)
    expect(overlay.classList.contains("hidden")).toBe(true)
    expect(overlay.hasAttribute("x")).toBe(false)
    expect(overlay.hasAttribute("width")).toBe(false)
    expect(status.textContent).toBe("")

    root.dispatch(key("Enter"))
    expect(pushEvent).toHaveBeenCalledOnce()
    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T12:00:00Z",
      end: "2026-08-27T12:59:59.999999Z",
    })

    root.dispatch(key("ArrowLeft"))
    expect(ctx.rangeController.activeIndex).toBe(0)
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
    expect(svg.listenerCount("pointerdown")).toBe(1)
    expect(svg.listenerCount("pointermove")).toBe(1)
    expect(svg.listenerCount("pointerup")).toBe(1)
    expect(svg.listenerCount("pointercancel")).toBe(1)
    expect(root.listenerCount("lostpointercapture")).toBe(1)
    expect(root.listenerCount("keydown")).toBe(1)
    drag(svg, 36, 616)
    expect(pushEvent).toHaveBeenLastCalledWith("select_events_range", {
      start: "2026-08-28T10:00:00Z",
      end: "2026-08-28T12:59:59.999999Z",
    })

    ctx.destroyed()
    expect(svg.totalListenerCount()).toBe(0)
    expect(root.totalListenerCount()).toBe(0)
  })

  it("releases capture on LiveView update and destroy", () => {
    const {ctx, root, svg} = mount()

    svg.dispatch(pointer("pointerdown", 36, "mouse", 8))
    svg.dispatch(pointer("pointermove", 50, "mouse", 8))
    expect(root.capturedPointers.has(8)).toBe(true)

    root.dataset = {...root.dataset, rangeEvent: "select_refreshed_events_range"}
    ctx.updated()
    expect(root.capturedPointers.has(8)).toBe(false)
    expect(svg.listenerCount("pointerdown")).toBe(1)

    svg.dispatch(pointer("pointerdown", 36, "mouse", 9))
    svg.dispatch(pointer("pointermove", 50, "mouse", 9))
    expect(root.capturedPointers.has(9)).toBe(true)
    ctx.destroyed()

    expect(root.capturedPointers.has(9)).toBe(false)
  })

  it("keeps the active pointer gesture when another pointer starts", () => {
    const {pushEvent, root, svg} = mount()

    svg.dispatch(pointer("pointerdown", 36, "mouse", 1))
    svg.dispatch(pointer("pointermove", 50, "mouse", 1))
    svg.dispatch(pointer("pointerdown", 616, "mouse", 2))
    svg.dispatch(pointer("pointermove", 36, "mouse", 2))
    svg.dispatch(pointer("pointerup", 36, "mouse", 2))

    expect(root.capturedPointers.has(1)).toBe(true)
    expect(root.capturedPointers.has(2)).toBe(false)
    expect(pushEvent).not.toHaveBeenCalled()

    svg.dispatch(pointer("pointermove", 616, "mouse", 1))
    svg.dispatch(pointer("pointerup", 616, "mouse", 1))

    expect(pushEvent).toHaveBeenCalledOnce()
    expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T13:59:59.999999Z",
    })
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

  it("disables itself when its event name is empty", () => {
    const {ctx, pushEvent, root, svg} = mount({eventName: ""})

    expect(root.hasAttribute("tabindex")).toBe(false)
    expect(root.getAttribute("aria-disabled")).toBe("true")
    drag(svg, 36, 616)

    expect(pushEvent).not.toHaveBeenCalled()
    ctx.destroyed()
  })
})
