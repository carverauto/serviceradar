import * as d3 from "d3"
import {describe, expect, it, vi} from "vitest"

import * as stackedChartModule from "./NetflowStackedAreaChart"

const {
  default: NetflowStackedAreaChart,
  rangeBucketsForScale,
  renderStackedBrush,
  renderStackedFrame,
  renderStackedRangeOverlay,
  stackedChartFingerprint,
} = stackedChartModule

const intervals = [
  {start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:04:59.999999Z"},
  {start: "2026-08-27T10:05:00Z", end: "2026-08-27T10:09:59.999999Z"},
  {start: "2026-08-27T10:10:00Z", end: "2026-08-27T10:14:59.999999Z"},
]

class FakeNode {
  constructor() {
    this.attributes = new Map()
    this.listeners = new Map()
    this.capturedPointers = new Set()
    this.textContent = ""
    this._classes = new Set(["hidden"])
    this.childrenBySelector = new Map()
    this.classList = {
      add: (name) => this._classes.add(name),
      contains: (name) => this._classes.has(name),
      remove: (name) => this._classes.delete(name),
    }
  }

  addEventListener(name, listener, options = undefined) {
    const listeners = this.listeners.get(name) || new Set()
    listeners.add({listener, options})
    this.listeners.set(name, listeners)
  }

  dispatch(event) {
    for (const {listener} of this.listeners.get(event.type) || []) listener(event)
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null
  }

  hasPointerCapture(pointerId) {
    return this.capturedPointers.has(pointerId)
  }

  listenerCount(name) {
    return this.listeners.get(name)?.size || 0
  }

  listenerOptions(name) {
    return [...(this.listeners.get(name) || [])].map(({options}) => options)
  }

  querySelector(selector) {
    return this.childrenBySelector.get(selector) || null
  }

  releasePointerCapture(pointerId) {
    this.capturedPointers.delete(pointerId)
  }

  removeAttribute(name) {
    this.attributes.delete(name)
  }

  removeEventListener(name, listener) {
    const listeners = this.listeners.get(name)
    for (const entry of listeners || []) {
      if (entry.listener === listener) listeners.delete(entry)
    }
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

class RecordingSelection {
  constructor(
    records,
    {boundData = [], node = new FakeNode(), ownerSvg = null, parentSelection = null, tag = "root"} = {},
  ) {
    this.boundData = boundData
    this.handlers = new Map()
    this.nodeValue = node
    this.ownerSvg = ownerSvg
    this.parentSelection = parentSelection
    this.records = records
    this.tag = tag
    this.nodeValue.tagName = tag
    this.nodeValue.parentNode = parentSelection?.nodeValue || null
    records.selections.push(this)
  }

  append(tag) {
    return new RecordingSelection(this.records, {
      ownerSvg: this.ownerSvg,
      parentSelection: this,
      tag,
    })
  }

  attr(name, value) {
    const resolved = typeof value === "function" ? value(this.boundData[0], 0) : value
    if (resolved !== undefined && resolved !== null) this.nodeValue.setAttribute(name, resolved)

    if (name === "data-netflow-stacked-render-root") {
      this.ownerSvg?.childrenBySelector.set("[data-netflow-stacked-render-root]", this.nodeValue)
    }
    if (name === "data-range-overlay") {
      this.ownerSvg?.childrenBySelector.set("[data-range-overlay]", this.nodeValue)
      this.records.overlays.push(this.nodeValue)
    }
    if (name === "class") {
      for (const className of String(resolved || "").split(/\s+/).filter(Boolean)) {
        this.nodeValue.classList.add(className)
        this.ownerSvg?.childrenBySelector.set(`.${className}`, this.nodeValue)
      }
    }
    return this
  }

  call(callback, ...args) {
    this.records.calls.push({args, callback, selection: this})
    if (callback?.recordingInvoke) callback(this, ...args)
    return this
  }

  data(values) {
    this.boundData = Array.from(values || [])
    return this
  }

  datum(value) {
    this.boundData = [value]
    return this
  }

  join(tag) {
    return new RecordingSelection(this.records, {
      boundData: this.boundData,
      ownerSvg: this.ownerSvg,
      parentSelection: this.parentSelection,
      tag,
    })
  }

  node() {
    return this.nodeValue
  }

  on(name, callback) {
    this.handlers.set(name, callback)
    this.records.handlers.push({callback, name, selection: this})
    return this
  }

  selectAll(selector) {
    return new RecordingSelection(this.records, {
      ownerSvg: this.ownerSvg,
      parentSelection: this,
      tag: `selectAll:${selector}`,
    })
  }

  style() {
    return this
  }

  text(value) {
    this.nodeValue.textContent = typeof value === "function" ? value(this.boundData[0], 0) : value
    return this
  }
}

function pointer(type, clientX, pointerId = 1, clientY = 100) {
  return {clientX, clientY, pointerId, type}
}

function key(keyName, shiftKey = false) {
  return {key: keyName, preventDefault: vi.fn(), shiftKey, type: "keydown"}
}

function root() {
  const el = new FakeNode()
  el.clientHeight = 224
  el.clientWidth = 600
  el.dataset = {
    colors: "{}",
    keys: JSON.stringify(["web", "db"]),
    overlays: "[]",
    points: JSON.stringify([
      {t: intervals[0].start, web: 10, db: 20},
      {t: intervals[1].start, web: 20, db: 10},
      {t: intervals[2].start, web: 30, db: 15},
    ]),
    rangeEvent: "netflow_range_selected",
    rangeIntervals: JSON.stringify(intervals),
    seriesField: "",
    timezone: "America/Chicago",
    units: "Bps",
    zoomable: "false",
  }
  return el
}

function rangeNodes() {
  const svg = new FakeNode()
  const overlay = new FakeNode()
  const status = new FakeNode()
  svg.getBoundingClientRect = () => ({height: 224, left: 0, top: 0, width: 600})
  svg.setAttribute("viewBox", "0 0 600 224")
  return {overlay, status, svg}
}

function renderSeams(el) {
  const svg = new FakeNode()
  const status = new FakeNode()
  const records = {calls: [], handlers: [], overlays: [], selections: []}
  const tooltipCleanups = []
  el.childrenBySelector.set("svg", svg)
  el.childrenBySelector.set("[data-range-status]", status)
  svg.getBoundingClientRect = () => ({height: 224, left: 0, top: 0, width: 600})
  svg.setAttribute("viewBox", "0 0 600 224")

  const selectRoot = vi.fn(() => new RecordingSelection(records, {node: svg, ownerSvg: svg, tag: "svg"}))
  const buildLegend = vi.fn((container, _keys, _color, _hidden, onToggle) => {
    records.legendToggle = onToggle
    container.append("g").attr("class", "legend")
  })
  const brushFactory = vi.fn(() => {
    const brush = vi.fn()
    brush.recordingInvoke = true
    brush.extent = vi.fn((extent) => {
      records.brushExtent = extent
      return brush
    })
    brush.on = vi.fn((name, callback) => {
      if (name === "end") records.brushEnd = callback
      return brush
    })
    brush.move = vi.fn()
    brush.move.recordingInvoke = true
    return brush
  })
  const attachTimeTooltip = vi.fn(() => {
    const cleanup = vi.fn()
    tooltipCleanups.push(cleanup)
    return cleanup
  })

  return {
    attachTimeTooltip,
    dependencies: {brushFactory, buildLegend, selectRoot},
    records,
    status,
    svg,
    tooltipCleanups,
  }
}

function directFrameArgs(el, svg, overrides = {}) {
  const data = JSON.parse(el.dataset.points).map((row) => ({...row, t: new Date(row.t)}))
  return {
    colors: {},
    data,
    el,
    hidden: new Set(),
    ih: 180,
    iw: 446,
    keys: ["web", "db"],
    margin: {bottom: 18, left: 44, right: 110, top: 8},
    onLegendToggle: vi.fn(),
    onSeriesClick: vi.fn(),
    overlays: [],
    svg,
    visibleKeys: ["web", "db"],
    ...overrides,
  }
}

function dispatchChartClick(el, seriesClick, keyValue, target = new FakeNode()) {
  const event = {
    immediateStopped: false,
    preventDefault: vi.fn(),
    stopImmediatePropagation: vi.fn(function () {
      event.immediateStopped = true
    }),
    target,
    type: "click",
  }
  el.dispatch(event)
  if (!event.immediateStopped && keyValue !== null) seriesClick.callback(event, {key: keyValue})
  return event
}

describe("NetflowStackedAreaChart range geometry", () => {
  it("uses the actual D3 time scale while preserving exact server intervals", () => {
    const x = d3
      .scaleTime()
      .domain([new Date(intervals[0].start), new Date(intervals[2].start)])
      .range([0, 446])

    expect(rangeBucketsForScale(intervals, x)).toEqual([
      {...intervals[0], x: 0},
      {...intervals[1], x: 223},
      {...intervals[2], x: 446},
    ])
  })

  it("fingerprints all render inputs and effective dimensions", () => {
    const el = root()
    const baseline = stackedChartFingerprint(el, {height: 224, width: 600})

    for (const [field, value] of [
      ["points", "[]"],
      ["keys", '["web"]'],
      ["colors", '{"web":"red"}'],
      ["overlays", '[{"key":"rev:web"}]'],
      ["units", "percent"],
      ["seriesField", "protocol_group"],
      ["rangeIntervals", "[]"],
      ["rangeEvent", "other_event"],
      ["timezone", "Etc/UTC"],
      ["zoomable", "true"],
    ]) {
      const changed = root()
      changed.dataset[field] = value
      expect(stackedChartFingerprint(changed, {height: 224, width: 600})).not.toBe(baseline)
    }

    expect(stackedChartFingerprint(el, {height: 224, width: 601})).not.toBe(baseline)
    expect(stackedChartFingerprint(el, {height: 225, width: 600})).not.toBe(baseline)
  })
})

describe("NetflowStackedAreaChart production render helpers", () => {
  it("renders the marked frame and wires the real series and legend callbacks", () => {
    const el = root()
    const seams = renderSeams(el)
    const args = directFrameArgs(el, seams.svg)

    const frame = renderStackedFrame(args, seams.dependencies)

    const rootSelection = seams.dependencies.selectRoot.mock.results[0].value
    const renderRoot = seams.svg.querySelector("[data-netflow-stacked-render-root]")
    expect(frame.g).not.toBe(rootSelection)
    expect(frame.g.node()).toBe(renderRoot)
    expect(renderRoot.tagName).toBe("g")
    expect(renderRoot.parentNode).toBe(seams.svg)
    expect(seams.svg.getAttribute("data-netflow-stacked-render-root")).toBeNull()
    const seriesClick = seams.records.handlers.find(
      ({name, selection}) => name === "click" && selection.tag === "path",
    )
    expect(seriesClick).toBeDefined()
    seriesClick.callback({}, {key: "web"})
    expect(args.onSeriesClick).toHaveBeenCalledWith("web")

    expect(seams.dependencies.buildLegend).toHaveBeenCalledOnce()
    expect(seams.svg.querySelector(".legend")).not.toBeNull()
    seams.records.legendToggle("db")
    expect(args.onLegendToggle).toHaveBeenCalledWith("db")

    const xAxisCall = seams.records.calls.find(
      ({callback}) => typeof callback?.scale === "function" && callback.scale() === frame.x,
    )
    const axisFormatter = xAxisCall?.callback?.tickFormat()

    expect(axisFormatter).toBeTypeOf("function")
    expect(axisFormatter(new Date(intervals[0].start))).toContain("05:00")
    expect(new Date(intervals[0].start).toISOString()).toBe("2026-08-27T10:00:00.000Z")
  })

  it("creates the real range overlay attributes and returns its current node", () => {
    const el = root()
    const seams = renderSeams(el)
    const g = new RecordingSelection(seams.records, {ownerSvg: seams.svg, tag: "g"})

    const overlay = renderStackedRangeOverlay({g, height: 180})

    expect(overlay).toBe(seams.svg.querySelector("[data-range-overlay]"))
    expect(overlay).not.toBe(g.node())
    expect(overlay.tagName).toBe("rect")
    expect(overlay.parentNode).toBe(g.node())
    expect(g.node().getAttribute("data-range-overlay")).toBeNull()
    expect(overlay.getAttribute("data-range-overlay")).toBe("")
    expect(overlay.getAttribute("height")).toBe("180")
    expect(overlay.getAttribute("pointer-events")).toBe("none")
    expect(overlay.getAttribute("class")).toBe("hidden fill-sr-brand/15 stroke-sr-brand/70")
  })

  it("creates the real brush and runs its installed end callback", () => {
    const el = root()
    const seams = renderSeams(el)
    const g = new RecordingSelection(seams.records, {ownerSvg: seams.svg, tag: "g"})
    const onZoom = vi.fn()
    const x = d3
      .scaleTime()
      .domain([new Date(intervals[0].start), new Date(intervals[2].start)])
      .range([0, 446])

    renderStackedBrush({g, height: 180, onZoom, width: 446, x}, seams.dependencies)

    const brush = seams.dependencies.brushFactory.mock.results[0].value
    const brushNode = seams.svg.querySelector(".brush")
    const brushSelection = seams.records.selections.find((selection) => selection.node() === brushNode)
    expect(brushNode).not.toBe(g.node())
    expect(brushNode.tagName).toBe("g")
    expect(brushNode.parentNode).toBe(g.node())
    expect(g.node().classList.contains("brush")).toBe(false)
    expect(brush).toHaveBeenCalledOnce()
    expect(brush).toHaveBeenCalledWith(brushSelection)
    expect(seams.records.calls.filter(({callback}) => callback === brush)).toEqual([
      {args: [], callback: brush, selection: brushSelection},
    ])
    expect(seams.records.brushExtent).toEqual([
      [0, 0],
      [446, 180],
    ])
    expect(seams.records.brushEnd).toBeTypeOf("function")
    seams.records.brushEnd({selection: [0, 446]})
    expect(onZoom).toHaveBeenCalledWith({
      start: new Date(intervals[0].start).toISOString(),
      end: new Date(intervals[2].start).toISOString(),
    })
    expect(brush).toHaveBeenCalledOnce()
    expect(brush.move).toHaveBeenCalledOnce()
    expect(brush.move).toHaveBeenCalledWith(brushSelection, null)
    expect(seams.records.calls.filter(({callback}) => callback === brush.move)).toEqual([
      {args: [null], callback: brush.move, selection: brushSelection},
    ])
  })
})

describe("NetflowStackedAreaChart lifecycle", () => {
  it.each([
    {
      color: "#2563EB",
      field: "protocol_group",
      key: "tcp",
      other: "udp",
    },
    {
      color: "#059669",
      field: "app",
      key: "https",
      other: "dns",
    },
  ])(
    "arbitrates range and $field series actions through the production hook",
    ({color, field, key: seriesKey, other}) => {
      const oldResizeObserver = globalThis.ResizeObserver
      globalThis.ResizeObserver = class {
        disconnect = vi.fn()
        observe = vi.fn()
      }

      try {
        const el = root()
        el.dataset.seriesField = field
        el.dataset.keys = JSON.stringify([seriesKey, other])
        el.dataset.colors = JSON.stringify({[seriesKey]: color, [other]: "#F97316"})
        el.dataset.points = JSON.stringify([
          {[seriesKey]: 80, [other]: 20, t: intervals[0].start},
          {[seriesKey]: 90, [other]: 10, t: intervals[1].start},
          {[seriesKey]: 70, [other]: 30, t: intervals[2].start},
        ])

        const seams = renderSeams(el)
        const pushEvent = vi.fn()
        const ctx = {
          el,
          pushEvent,
          ...NetflowStackedAreaChart,
          _attachTimeTooltip: seams.attachTimeTooltip,
          _stackedRenderDependencies: seams.dependencies,
        }
        ctx.mounted()

        const seriesPath = seams.records.selections.find((selection) => selection.tag === "path")
        const seriesClick = seams.records.handlers.find(
          ({name, selection}) => name === "click" && selection === seriesPath,
        )
        expect(seriesClick).toBeDefined()
        expect(seriesPath.node().getAttribute("fill")).toBe(color)
        expect(seriesPath.node().getAttribute("cursor")).toBe("pointer")
        expect(seams.svg.querySelector(".legend")).not.toBeNull()
        expect(seams.attachTimeTooltip).toHaveBeenCalledOnce()
        expect(seams.attachTimeTooltip).toHaveBeenLastCalledWith(
          el,
          expect.objectContaining({timeZone: "America/Chicago"}),
        )

        seams.svg.dispatch(pointer("pointerdown", 44, 10))
        seams.svg.dispatch(pointer("pointerup", 50, 10))
        expect(pushEvent).not.toHaveBeenCalledWith("netflow_range_selected", expect.anything())

        dispatchChartClick(el, seriesClick, seriesKey)
        expect(pushEvent.mock.calls).toEqual([
          ["netflow_stack_series", {field, value: seriesKey}],
        ])

        pushEvent.mockClear()
        seams.svg.dispatch(pointer("pointerdown", 44, 11))
        seams.svg.dispatch(pointer("pointerup", 490, 11))
        expect(pushEvent.mock.calls).toEqual([
          [
            "netflow_range_selected",
            {start: intervals[0].start, end: intervals[2].end},
          ],
        ])

        const backgroundClick = dispatchChartClick(el, seriesClick, null, seams.svg)
        expect(backgroundClick.preventDefault).toHaveBeenCalledOnce()
        expect(backgroundClick.stopImmediatePropagation).toHaveBeenCalledOnce()
        expect(pushEvent).toHaveBeenCalledTimes(1)

        pushEvent.mockClear()
        seams.svg.dispatch(pointer("pointerdown", 490, 12))
        seams.svg.dispatch(pointer("pointerup", 44, 12))
        expect(pushEvent.mock.calls).toEqual([
          [
            "netflow_range_selected",
            {start: intervals[0].start, end: intervals[2].end},
          ],
        ])
        const syntheticSeriesClick = dispatchChartClick(el, seriesClick, seriesKey)
        expect(syntheticSeriesClick.stopImmediatePropagation).toHaveBeenCalledOnce()
        expect(pushEvent).toHaveBeenCalledTimes(1)

        dispatchChartClick(el, seriesClick, seriesKey)
        expect(pushEvent).toHaveBeenLastCalledWith("netflow_stack_series", {
          field,
          value: seriesKey,
        })

        pushEvent.mockClear()
        el.dispatch(key("Escape"))
        el.dispatch(key("ArrowRight", true))
        el.dispatch(key("ArrowRight", true))
        el.dispatch(key("Enter"))
        expect(pushEvent.mock.calls).toEqual([
          [
            "netflow_range_selected",
            {start: intervals[0].start, end: intervals[2].end},
          ],
        ])

        const afterKeyboardClick = dispatchChartClick(el, seriesClick, seriesKey)
        expect(afterKeyboardClick.stopImmediatePropagation).not.toHaveBeenCalled()
        expect(pushEvent).toHaveBeenLastCalledWith("netflow_stack_series", {
          field,
          value: seriesKey,
        })

        const firstCleanup = seams.tooltipCleanups[0]
        seams.records.legendToggle(seriesKey)
        expect(ctx._hidden.has(seriesKey)).toBe(true)
        expect(firstCleanup).toHaveBeenCalledOnce()
        expect(seams.attachTimeTooltip).toHaveBeenCalledTimes(2)

        ctx.destroyed()
        expect(seams.tooltipCleanups.at(-1)).toHaveBeenCalledOnce()
        expect(seams.svg.totalListenerCount()).toBe(0)
        expect(el.listenerCount("click")).toBe(0)
      } finally {
        globalThis.ResizeObserver = oldResizeObserver
      }
    },
  )

  it("uses the real draw lifecycle, skips intact trees, and redraws a cleared unchanged tree", () => {
    const oldResizeObserver = globalThis.ResizeObserver
    let resizeCallback
    globalThis.ResizeObserver = class {
      constructor(callback) {
        resizeCallback = callback
      }
      disconnect = vi.fn()
      observe = vi.fn()
    }

    try {
      const el = root()
      el.dataset.seriesField = "protocol_group"
      const seams = renderSeams(el)
      const pushEvent = vi.fn()
      const ctx = {
        el,
        pushEvent,
        ...NetflowStackedAreaChart,
        _attachTimeTooltip: seams.attachTimeTooltip,
        _stackedRenderDependencies: seams.dependencies,
      }
      ctx.mounted()
      expect(seams.dependencies.selectRoot).toHaveBeenCalledOnce()
      expect(seams.records.overlays).toHaveLength(1)
      expect(seams.attachTimeTooltip).toHaveBeenCalledOnce()
      expect(seams.svg.querySelector(".legend")).not.toBeNull()
      expect(seams.svg.getAttribute("data-netflow-stacked-interaction")).toBe("range")
      expect(ctx.rangeController?.options.enabled).toBe(true)
      expect(ctx.rangeController?.options.overlay).toBe(seams.records.overlays[0])
      expect(ctx.rangeController?.options.overlay.tagName).toBe("rect")
      expect(ctx.rangeController?.options.overlay.parentNode).toBe(
        seams.svg.querySelector("[data-netflow-stacked-render-root]"),
      )
      expect(ctx.rangeController?.options.svg).toBe(seams.svg)
      expect(el.listenerCount("click")).toBe(1)
      expect(el.listenerOptions("click")).toContain(true)

      const firstSeriesClick = seams.records.handlers.find(
        ({name, selection}) => name === "click" && selection.tag === "path",
      )
      seams.svg.dispatch(pointer("pointerdown", 44, 21))
      seams.svg.dispatch(pointer("pointerup", 490, 21))
      expect(pushEvent).toHaveBeenCalledWith("netflow_range_selected", {
        start: intervals[0].start,
        end: intervals[2].end,
      })

      const backgroundClick = {
        preventDefault: vi.fn(),
        stopImmediatePropagation: vi.fn(),
        target: seams.svg,
        type: "click",
      }
      el.dispatch(backgroundClick)
      expect(backgroundClick.preventDefault).toHaveBeenCalledOnce()
      expect(backgroundClick.stopImmediatePropagation).toHaveBeenCalledOnce()

      const nextSeriesClick = {
        preventDefault: vi.fn(),
        stopImmediatePropagation: vi.fn(),
        target: seams.svg,
        type: "click",
      }
      el.dispatch(nextSeriesClick)
      expect(nextSeriesClick.preventDefault).not.toHaveBeenCalled()
      expect(nextSeriesClick.stopImmediatePropagation).not.toHaveBeenCalled()
      firstSeriesClick.callback({}, {key: "web"})
      expect(pushEvent).toHaveBeenCalledWith("netflow_stack_series", {
        field: "protocol_group",
        value: "web",
      })

      const hidden = ctx._hidden
      ctx.updated()
      resizeCallback()
      expect(seams.dependencies.selectRoot).toHaveBeenCalledOnce()
      expect(ctx._hidden).toBe(hidden)

      seams.svg.childrenBySelector.delete("[data-netflow-stacked-render-root]")
      ctx.updated()
      expect(seams.dependencies.selectRoot).toHaveBeenCalledTimes(2)
      expect(seams.records.overlays).toHaveLength(2)
      expect(seams.tooltipCleanups[0]).toHaveBeenCalledOnce()
      expect(ctx.rangeController?.options.overlay).toBe(seams.records.overlays[1])
      expect(ctx.rangeController?.options.overlay).not.toBe(seams.records.overlays[0])
      expect(seams.svg.listenerCount("pointerdown")).toBe(1)
      expect(el.listenerCount("click")).toBe(1)

      seams.records.legendToggle("web")
      expect(ctx._hidden.has("web")).toBe(true)
      expect(seams.dependencies.selectRoot).toHaveBeenCalledTimes(3)

      el.dataset.points = JSON.stringify([{t: intervals[0].start, web: 99, db: 1}])
      ctx.updated()
      expect(seams.dependencies.selectRoot).toHaveBeenCalledTimes(4)

      el.clientWidth = 720
      resizeCallback()
      expect(seams.dependencies.selectRoot).toHaveBeenCalledTimes(5)

      ctx.destroyed()
      expect(seams.tooltipCleanups.at(-1)).toHaveBeenCalledOnce()
      expect(seams.svg.totalListenerCount()).toBe(0)
      expect(el.listenerCount("click")).toBe(0)
    } finally {
      globalThis.ResizeObserver = oldResizeObserver
    }
  })

  it("redraws for a zone-only update while preserving points and canonical range intervals", () => {
    const oldResizeObserver = globalThis.ResizeObserver
    globalThis.ResizeObserver = class {
      disconnect = vi.fn()
      observe = vi.fn()
    }

    try {
      const el = root()
      const canonicalPoints = el.dataset.points
      const canonicalIntervals = el.dataset.rangeIntervals
      const seams = renderSeams(el)
      const ctx = {
        el,
        pushEvent: vi.fn(),
        ...NetflowStackedAreaChart,
        _attachTimeTooltip: seams.attachTimeTooltip,
        _stackedRenderDependencies: seams.dependencies,
      }

      ctx.mounted()
      expect(seams.dependencies.selectRoot).toHaveBeenCalledOnce()
      expect(seams.attachTimeTooltip).toHaveBeenLastCalledWith(
        el,
        expect.objectContaining({timeZone: "America/Chicago"}),
      )

      el.dataset.timezone = "Etc/UTC"
      ctx.updated()

      expect(seams.dependencies.selectRoot).toHaveBeenCalledTimes(2)
      expect(seams.attachTimeTooltip).toHaveBeenLastCalledWith(
        el,
        expect.objectContaining({timeZone: "Etc/UTC"}),
      )
      expect(el.dataset.points).toBe(canonicalPoints)
      expect(el.dataset.rangeIntervals).toBe(canonicalIntervals)

      ctx.destroyed()
    } finally {
      globalThis.ResizeObserver = oldResizeObserver
    }
  })

  it("commits forward, reverse, and keyboard ranges through one long-lived controller", () => {
    const el = root()
    const pushEvent = vi.fn()
    const ctx = {el, pushEvent, ...NetflowStackedAreaChart}
    const nodes = rangeNodes()
    const x = d3
      .scaleTime()
      .domain([new Date(intervals[0].start), new Date(intervals[2].start)])
      .range([0, 446])

    ctx._updateRangeSelection({...nodes, height: 180, intervals, marginLeft: 44, plotWidth: 446, x})
    const controller = ctx.rangeController

    el.dispatch(key("ArrowLeft"))
    el.dispatch(key("ArrowLeft", true))
    el.dispatch(key("Enter"))
    expect(pushEvent).toHaveBeenLastCalledWith("netflow_range_selected", {
      start: intervals[0].start,
      end: intervals[1].end,
    })

    nodes.svg.dispatch(pointer("pointerdown", 44, 1))
    nodes.svg.dispatch(pointer("pointerup", 490, 1))
    expect(pushEvent).toHaveBeenCalledWith("netflow_range_selected", {
      start: intervals[0].start,
      end: intervals[2].end,
    })

    ctx._updateRangeSelection({...nodes, height: 180, intervals, marginLeft: 44, plotWidth: 446, x})
    expect(ctx.rangeController).toBe(controller)
    expect(nodes.svg.listenerCount("pointerdown")).toBe(1)

    nodes.svg.dispatch(pointer("pointerdown", 490, 2))
    nodes.svg.dispatch(pointer("pointerup", 44, 2))
    expect(pushEvent).toHaveBeenLastCalledWith("netflow_range_selected", {
      start: intervals[0].start,
      end: intervals[2].end,
    })
  })

  it("commits the visible range when release lands in the bottom-axis margin", () => {
    const el = root()
    const pushEvent = vi.fn()
    const ctx = {el, pushEvent, ...NetflowStackedAreaChart}
    const nodes = rangeNodes()
    const x = d3
      .scaleTime()
      .domain([new Date(intervals[0].start), new Date(intervals[2].start)])
      .range([0, 446])

    ctx._updateRangeSelection({...nodes, height: 198, intervals, marginLeft: 44, plotWidth: 446, x})
    nodes.svg.dispatch(pointer("pointerdown", 44, 13, 100))
    nodes.svg.dispatch(pointer("pointermove", 490, 13, 100))

    expect(nodes.overlay.classList.contains("hidden")).toBe(false)
    expect(nodes.overlay.getAttribute("x")).toBe("0")
    expect(nodes.overlay.getAttribute("width")).toBe("446")

    nodes.svg.dispatch(pointer("pointerup", 490, 13, 215))

    expect(pushEvent).toHaveBeenCalledOnce()
    expect(pushEvent).toHaveBeenCalledWith("netflow_range_selected", {
      start: intervals[0].start,
      end: intervals[2].end,
    })
    expect(ctx.rangeController.consumeChartClick()).toBe(true)
    expect(ctx.rangeController.consumeChartClick()).toBe(false)
  })

  it("commits a coalesced drag whose first sampled endpoint is below the plot", () => {
    const el = root()
    const pushEvent = vi.fn()
    const ctx = {el, pushEvent, ...NetflowStackedAreaChart}
    const nodes = rangeNodes()
    const x = d3
      .scaleTime()
      .domain([new Date(intervals[0].start), new Date(intervals[2].start)])
      .range([0, 446])

    ctx._updateRangeSelection({...nodes, height: 198, intervals, marginLeft: 44, plotWidth: 446, x})

    nodes.svg.dispatch(pointer("pointerdown", 44, 14, 100))
    nodes.svg.dispatch(pointer("pointerup", 490, 14, 215))

    expect(pushEvent).toHaveBeenCalledOnce()
    expect(pushEvent).toHaveBeenCalledWith("netflow_range_selected", {
      start: intervals[0].start,
      end: intervals[2].end,
    })
    expect(ctx.rangeController.consumeChartClick()).toBe(true)
  })

  it("preserves capture on unchanged update, rebinds changed geometry, and destroys listeners", () => {
    const el = root()
    const ctx = {el, pushEvent: vi.fn(), ...NetflowStackedAreaChart}
    const first = rangeNodes()
    const x = d3
      .scaleTime()
      .domain([new Date(intervals[0].start), new Date(intervals[2].start)])
      .range([0, 446])

    ctx._updateRangeSelection({...first, height: 180, intervals, marginLeft: 44, plotWidth: 446, x})
    first.svg.dispatch(pointer("pointerdown", 44, 8))
    first.svg.dispatch(pointer("pointermove", 54, 8))
    ctx._updateRangeSelection({...first, height: 180, intervals, marginLeft: 44, plotWidth: 446, x})
    expect(el.capturedPointers.has(8)).toBe(true)

    const second = rangeNodes()
    const resizedX = x.copy().range([0, 566])
    ctx._updateRangeSelection({...second, height: 180, intervals, marginLeft: 44, plotWidth: 566, x: resizedX})
    expect(el.capturedPointers.has(8)).toBe(true)
    expect(first.svg.totalListenerCount()).toBe(0)
    expect(second.svg.listenerCount("pointerdown")).toBe(1)

    ctx.destroyed()
    expect(el.capturedPointers.has(8)).toBe(false)
    expect(second.svg.totalListenerCount()).toBe(0)
    expect(el.totalListenerCount()).toBe(0)
    expect(ctx.rangeController).toBeNull()
  })

  it("preserves the device-detail brush, legend, and tooltip lifecycle without enabling range selection", () => {
    const oldResizeObserver = globalThis.ResizeObserver
    globalThis.ResizeObserver = class {
      disconnect = vi.fn()
      observe = vi.fn()
    }

    const el = root()
    el.dataset.zoomable = "true"
    const seams = renderSeams(el)
    const ctx = {
      el,
      pushEvent: vi.fn(),
      ...NetflowStackedAreaChart,
      _attachTimeTooltip: seams.attachTimeTooltip,
      _stackedRenderDependencies: seams.dependencies,
    }

    try {
      ctx.mounted()
      expect(seams.dependencies.selectRoot).toHaveBeenCalledOnce()
      expect(seams.dependencies.brushFactory).toHaveBeenCalledOnce()
      expect(seams.records.overlays).toHaveLength(0)
      expect(seams.attachTimeTooltip).toHaveBeenCalledOnce()
      expect(seams.attachTimeTooltip).toHaveBeenLastCalledWith(
        el,
        expect.objectContaining({timeZone: "America/Chicago"}),
      )
      expect(seams.svg.querySelector(".legend")).not.toBeNull()
      expect(seams.svg.querySelector(".brush")).not.toBeNull()
      expect(seams.svg.getAttribute("data-netflow-stacked-interaction")).toBe("brush")
      expect(ctx.rangeController).toBeNull()
      ctx.destroyed()
    } finally {
      globalThis.ResizeObserver = oldResizeObserver
    }
  })

  it("rejects range starts on axes or legend geometry", () => {
    const el = root()
    const pushEvent = vi.fn()
    const ctx = {el, pushEvent, ...NetflowStackedAreaChart}
    const nodes = rangeNodes()
    const x = d3
      .scaleTime()
      .domain([new Date(intervals[0].start), new Date(intervals[2].start)])
      .range([0, 446])

    ctx._updateRangeSelection({...nodes, height: 180, intervals, marginLeft: 44, plotWidth: 446, x})
    nodes.svg.dispatch(pointer("pointerdown", 20, 3))
    nodes.svg.dispatch(pointer("pointerup", 490, 3))
    nodes.svg.dispatch(pointer("pointerdown", 44, 4, 210))
    nodes.svg.dispatch(pointer("pointerup", 490, 4, 210))
    expect(pushEvent).not.toHaveBeenCalled()
  })
})
