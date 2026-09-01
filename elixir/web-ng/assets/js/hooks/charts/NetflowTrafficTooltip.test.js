import {describe, expect, it, vi} from "vitest"

import NetflowTrafficTooltip from "./NetflowTrafficTooltip"

const buckets = [
  {x: 0, start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:04:59.999999Z"},
  {x: 500, start: "2026-08-27T10:05:00Z", end: "2026-08-27T10:09:59.999999Z"},
  {x: 1000, start: "2026-08-27T10:10:00Z", end: "2026-08-27T10:14:59.999999Z"},
]

class FakeNode {
  constructor(attributes = {}) {
    this.attributes = new Map(Object.entries(attributes))
    this.children = []
    this.listeners = new Map()
    this.capturedPointers = new Set()
    this.dataset = {}
    this.innerHTML = ""
    this.style = {}
    this.textContent = ""
    this.queryResults = new Map()
    this._classes = new Set()
    this.classList = {
      add: (...names) => names.forEach((name) => this._classes.add(name)),
      contains: (name) => this._classes.has(name),
      remove: (...names) => names.forEach((name) => this._classes.delete(name)),
    }
  }

  set className(value) {
    this._classes = new Set(String(value).split(/\s+/).filter(Boolean))
  }

  get className() {
    return [...this._classes].join(" ")
  }

  addEventListener(name, listener) {
    const listeners = this.listeners.get(name) || new Set()
    listeners.add(listener)
    this.listeners.set(name, listeners)
  }

  appendChild(child) {
    child.parentElement = this
    this.children.push(child)
    return child
  }

  dispatch(event) {
    event.target ??= this
    for (const listener of this.listeners.get(event.type) || []) listener(event)
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null
  }

  getBoundingClientRect() {
    return {height: 160, left: 0, top: 0, width: 1000}
  }

  hasPointerCapture(pointerId) {
    return this.capturedPointers.has(pointerId)
  }

  listenerCount(name) {
    return this.listeners.get(name)?.size || 0
  }

  querySelector(selector) {
    if (selector === ":scope > .nf-overlay") return this.children.find((child) => child.classList.contains("nf-overlay")) || null
    if (selector === ":scope > .nf-tooltip") return this.children.find((child) => child.classList.contains("nf-tooltip")) || null
    return null
  }

  querySelectorAll(selector) {
    return this.queryResults.get(selector) || []
  }

  releasePointerCapture(pointerId) {
    this.capturedPointers.delete(pointerId)
  }

  removeAttribute(name) {
    this.attributes.delete(name)
  }

  removeEventListener(name, listener) {
    const listeners = this.listeners.get(name)
    listeners?.delete(listener)
    if (listeners?.size === 0) this.listeners.delete(name)
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value))
  }

  setPointerCapture(pointerId) {
    this.capturedPointers.add(pointerId)
  }

  totalListenerCount() {
    return [...this.listeners.values()].reduce((total, listeners) => total + listeners.size, 0)
  }
}

function pointer(type, clientX, pointerId = 1, clientY = 80) {
  return {clientX, clientY, pointerId, type}
}

function key(keyName, shiftKey = false) {
  return {key: keyName, preventDefault: vi.fn(), shiftKey, type: "keydown"}
}

function click() {
  return {preventDefault: vi.fn(), stopImmediatePropagation: vi.fn(), type: "click"}
}

function chart() {
  const svg = new FakeNode({viewBox: "0 0 1000 160"})
  const overlay = new FakeNode()
  overlay.classList.add("hidden")
  const status = new FakeNode()
  const root = new FakeNode()
  const axisTime = new FakeNode()
  const rangeTitle = new FakeNode()
  const axisFallback = "2026-08-27T10:00:00Z"
  const titleFallback =
    "window: 2026-08-27T10:00:00Z → 2026-08-27T10:04:59.999999Z\nbytes: 100 B\navg rate: 2.67 bps"

  axisTime.setAttribute("data-netflow-time", "axis")
  axisTime.setAttribute("data-time-iso", buckets[0].start)
  axisTime.setAttribute("data-time-fallback", axisFallback)
  axisTime.textContent = axisFallback
  rangeTitle.setAttribute("data-netflow-time", "range-title")
  rangeTitle.setAttribute("data-time-start", buckets[0].start)
  rangeTitle.setAttribute("data-time-end", buckets[0].end)
  rangeTitle.setAttribute("data-time-fallback", titleFallback)
  rangeTitle.textContent = titleFallback

  root.dataset = {
    bucketSeconds: "300",
    chartHeight: "160",
    chartWidth: "1000",
    points: JSON.stringify(
      buckets.map((bucket, index) => ({...bucket, bucket_seconds: 300, bytes: (index + 1) * 100})),
    ),
    rangeBuckets: JSON.stringify(buckets),
    rangeEvent: "netflow_range_selected",
    timezone: "America/Chicago",
  }
  root.queryResults.set("[data-netflow-time='axis']", [axisTime])
  root.queryResults.set("[data-netflow-time='range-title']", [rangeTitle])
  root.querySelector = (selector) => {
    if (selector === "[data-range-svg]" || selector === "svg") return svg
    if (selector === "[data-range-overlay]") return overlay
    if (selector === "[data-range-status]") return status
    if (selector === ":scope > .nf-overlay") {
      return root.children.find((child) => child.classList.contains("nf-overlay")) || null
    }
    return null
  }
  return {axisFallback, axisTime, overlay, rangeTitle, root, status, svg, titleFallback}
}

function mount() {
  const nodes = chart()
  const pushEvent = vi.fn()
  const ctx = {el: nodes.root, pushEvent, ...NetflowTrafficTooltip}
  ctx.mounted()
  return {...nodes, ctx, pushEvent}
}

describe("NetflowTrafficTooltip shared range integration", () => {
  it("keeps tooltip movement while binding one shared range controller", () => {
    const oldDocument = globalThis.document
    const oldWindow = globalThis.window
    globalThis.document = {createElement: () => new FakeNode()}
    globalThis.window = {getComputedStyle: () => ({position: "relative"})}

    try {
      const {ctx, root, svg} = mount()

      expect(root.listenerCount("mousemove")).toBe(1)
      expect(root.listenerCount("mouseleave")).toBe(1)
      expect(root.listenerCount("click")).toBe(1)
      expect(root.listenerCount("keydown")).toBe(1)
      expect(svg.listenerCount("pointerdown")).toBe(1)

      root.dispatch({clientX: 500, clientY: 70, type: "mousemove"})
      const tooltip = root.children[0].children[0]
      expect(tooltip.classList.contains("hidden")).toBe(false)
      expect(tooltip.innerHTML).toContain("05:05:00")
      expect(tooltip.innerHTML).toContain("05:09:59")
      expect(tooltip.innerHTML).toContain("GMT-5")
      expect(tooltip.innerHTML.match(/<time /g)).toHaveLength(2)
      expect(tooltip.innerHTML).toContain('<time datetime="2026-08-27T10:05:00Z"')
      expect(tooltip.innerHTML).toContain(
        'data-canonical-utc="2026-08-27T10:09:59.999999Z"',
      )
      expect(tooltip.innerHTML).toContain("canonical UTC 2026-08-27T10:05:00Z")
      expect(tooltip.innerHTML).toContain("canonical UTC 2026-08-27T10:09:59.999999Z")

      ctx.destroyed()
      expect(root.totalListenerCount()).toBe(0)
      expect(svg.totalListenerCount()).toBe(0)
      expect(ctx.rangeController).toBeNull()
    } finally {
      globalThis.document = oldDocument
      globalThis.window = oldWindow
    }
  })

  it("localizes SVG time markers and restores their complete fallback after an invalid-zone update", () => {
    const oldDocument = globalThis.document
    const oldWindow = globalThis.window
    globalThis.document = {createElement: () => new FakeNode()}
    globalThis.window = {getComputedStyle: () => ({position: "relative"})}

    try {
      const {axisFallback, axisTime, ctx, rangeTitle, root, titleFallback} = mount()

      expect(axisTime.textContent).toContain("05:00")
      expect(axisTime.textContent).not.toBe(axisFallback)
      expect(rangeTitle.textContent).toContain("05:00:00")
      expect(rangeTitle.textContent).toContain("05:04:59")
      expect(rangeTitle.textContent).toContain("display zone America/Chicago")
      expect(rangeTitle.textContent).toContain(`canonical UTC ${buckets[0].start}`)
      expect(rangeTitle.textContent).toContain(`canonical UTC ${buckets[0].end}`)
      expect(rangeTitle.textContent.split("\n")).toEqual([
        expect.stringContaining("GMT-5"),
        "bytes: 100 B",
        "avg rate: 2.67 bps",
      ])

      root.dataset.timezone = "Mars/Olympus"
      ctx.updated()

      expect(axisTime.textContent).toBe(axisFallback)
      expect(rangeTitle.textContent).toBe(titleFallback)

      root.dispatch({clientX: 0, clientY: 70, type: "mousemove"})
      const tooltip = root.children[0].children[0]
      expect(tooltip.innerHTML).toContain(buckets[0].start)
      expect(tooltip.innerHTML).toContain(buckets[0].end)
    } finally {
      globalThis.document = oldDocument
      globalThis.window = oldWindow
    }
  })

  it("keeps sub-threshold and later clicks but suppresses exactly the post-drag click", () => {
    const oldDocument = globalThis.document
    const oldWindow = globalThis.window
    globalThis.document = {createElement: () => new FakeNode()}
    globalThis.window = {getComputedStyle: () => ({position: "relative"})}

    try {
      const {pushEvent, root, svg} = mount()

      svg.dispatch(pointer("pointerdown", 0, 1))
      svg.dispatch(pointer("pointerup", 6, 1))
      const ordinary = click()
      root.dispatch(ordinary)
      expect(ordinary.stopImmediatePropagation).not.toHaveBeenCalled()
      expect(pushEvent).not.toHaveBeenCalled()

      svg.dispatch(pointer("pointerdown", 1000, 2))
      svg.dispatch(pointer("pointerup", 0, 2))
      expect(pushEvent).toHaveBeenCalledWith("netflow_range_selected", {
        start: "2026-08-27T10:00:00Z",
        end: "2026-08-27T10:14:59.999999Z",
      })

      const synthetic = click()
      root.dispatch(synthetic)
      expect(synthetic.preventDefault).toHaveBeenCalledOnce()
      expect(synthetic.stopImmediatePropagation).toHaveBeenCalledOnce()

      const later = click()
      root.dispatch(later)
      expect(later.stopImmediatePropagation).not.toHaveBeenCalled()
    } finally {
      globalThis.document = oldDocument
      globalThis.window = oldWindow
    }
  })

  it("supports keyboard selection and preserves an unchanged captured gesture across updated", () => {
    const oldDocument = globalThis.document
    const oldWindow = globalThis.window
    globalThis.document = {createElement: () => new FakeNode()}
    globalThis.window = {getComputedStyle: () => ({position: "relative"})}

    try {
      const {ctx, pushEvent, root, svg} = mount()

      root.dispatch(key("ArrowLeft"))
      root.dispatch(key("ArrowLeft", true))
      root.dispatch(key("Enter"))
      expect(pushEvent).toHaveBeenCalledWith("netflow_range_selected", {
        start: "2026-08-27T10:00:00Z",
        end: "2026-08-27T10:09:59.999999Z",
      })

      svg.dispatch(pointer("pointerdown", 0, 9))
      svg.dispatch(pointer("pointermove", 10, 9))
      ctx.updated()
      expect(root.capturedPointers.has(9)).toBe(true)
      expect(svg.listenerCount("pointerdown")).toBe(1)
      svg.dispatch(pointer("pointerup", 1000, 9))
      expect(pushEvent).toHaveBeenLastCalledWith("netflow_range_selected", {
        start: "2026-08-27T10:00:00Z",
        end: "2026-08-27T10:14:59.999999Z",
      })
    } finally {
      globalThis.document = oldDocument
      globalThis.window = oldWindow
    }
  })

  it("commits a coalesced drag whose first sampled endpoint is below the plot", () => {
    const oldDocument = globalThis.document
    const oldWindow = globalThis.window
    globalThis.document = {createElement: () => new FakeNode()}
    globalThis.window = {getComputedStyle: () => ({position: "relative"})}

    try {
      const {pushEvent, svg} = mount()

      svg.dispatch(pointer("pointerdown", 0, 10, 80))
      svg.dispatch(pointer("pointerup", 1000, 10, 170))

      expect(pushEvent).toHaveBeenCalledOnce()
      expect(pushEvent).toHaveBeenCalledWith("netflow_range_selected", {
        start: "2026-08-27T10:00:00Z",
        end: "2026-08-27T10:14:59.999999Z",
      })
    } finally {
      globalThis.document = oldDocument
      globalThis.window = oldWindow
    }
  })

  it("rebinds changed metadata and rejects pointer starts outside the plot", () => {
    const oldDocument = globalThis.document
    const oldWindow = globalThis.window
    globalThis.document = {createElement: () => new FakeNode()}
    globalThis.window = {getComputedStyle: () => ({position: "relative"})}

    try {
      const {ctx, pushEvent, root, svg} = mount()

      svg.dispatch(pointer("pointerdown", 0, 3, 170))
      svg.dispatch(pointer("pointerup", 1000, 3, 170))
      expect(pushEvent).not.toHaveBeenCalled()

      root.dataset.rangeBuckets = JSON.stringify([
        {x: 250, start: "2026-08-28T10:00:00Z", end: "2026-08-28T10:04:59.999999Z"},
        {x: 750, start: "2026-08-28T10:05:00Z", end: "2026-08-28T10:09:59.999999Z"},
      ])
      ctx.updated()
      expect(svg.listenerCount("pointerdown")).toBe(1)
      svg.dispatch(pointer("pointerdown", 250, 4))
      svg.dispatch(pointer("pointerup", 750, 4))
      expect(pushEvent).toHaveBeenLastCalledWith("netflow_range_selected", {
        start: "2026-08-28T10:00:00Z",
        end: "2026-08-28T10:09:59.999999Z",
      })
    } finally {
      globalThis.document = oldDocument
      globalThis.window = oldWindow
    }
  })
})
