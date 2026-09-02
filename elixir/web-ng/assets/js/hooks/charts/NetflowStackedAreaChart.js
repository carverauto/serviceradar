import * as d3 from "d3"

import {
  attachTimeTooltip as nfAttachTimeTooltip,
  buildLegend as nfBuildLegend,
  chartDims as nfChartDims,
  clearSVG as nfClearSVG,
  colorScale as nfColorScale,
  ensureSVG as nfEnsureSVG,
  netflowAxisTimeFormatter,
  netflowDisplayTimeZone,
  netflowRangeSelectionStatus,
  normalizeTimeSeries as nfNormalizeTimeSeries,
  parseSeriesData as nfParseSeriesData,
  renderYGrid as nfRenderYGrid,
  styleChartAxis as nfStyleChartAxis,
} from "../../netflow_charts/util"
import {yGridTicks} from "../../utils/chart_axis_grid"
import {nfFormatRateValue} from "../../utils/formatters"
import ChartRangeSelectionController from "./ChartRangeSelectionController"

const RENDER_FINGERPRINT_ATTRIBUTE = "data-netflow-stacked-render-fingerprint"
const RENDER_ROOT_SELECTOR = "[data-netflow-stacked-render-root]"

export function rangeBucketsForScale(intervals, xScale, renderedTimes = null) {
  if (!Array.isArray(intervals) || typeof xScale !== "function") return []

  const rendered =
    Array.isArray(renderedTimes) && renderedTimes.length > 0
      ? new Set(renderedTimes.map((value) => new Date(value).getTime()).filter(Number.isFinite))
      : null

  return intervals.flatMap((interval) => {
    const timestamp = new Date(interval?.start)
    const time = timestamp.getTime()
    const x = xScale(timestamp)
    if (!Number.isFinite(time) || !Number.isFinite(x) || (rendered && !rendered.has(time))) return []
    if (typeof interval?.start !== "string" || typeof interval?.end !== "string") return []
    return [{x, start: interval.start, end: interval.end}]
  })
}

export function stackedChartFingerprint(el, dimensions) {
  const dataset = el?.dataset || {}
  return JSON.stringify([
    dataset.points || "",
    dataset.keys || "",
    dataset.colors || "",
    dataset.overlays || "",
    dataset.units || "",
    dataset.seriesField || "",
    dataset.rangeIntervals || "",
    dataset.rangeEvent || "",
    dataset.timezone || "",
    dataset.zoomable || "",
    Number(dimensions?.width || 0),
    Number(dimensions?.height || 0),
  ])
}

export function stackedRenderTreeIntact(el, fingerprint) {
  const svg = nfEnsureSVG(el)
  return (
    svg?.getAttribute(RENDER_FINGERPRINT_ATTRIBUTE) === fingerprint &&
    svg.querySelector(RENDER_ROOT_SELECTOR) !== null
  )
}

export default {
  mounted() {
    this._render = (force = false) => this._renderIfChanged(force)
    this._chartClickArbiter = (event) => {
      if (!this.rangeController?.consumeChartClick()) return
      event.preventDefault()
      event.stopImmediatePropagation()
    }
    this.el.addEventListener("click", this._chartClickArbiter, true)
    this._resizeObserver = new ResizeObserver(() => this._render())
    this._resizeObserver.observe(this.el)
    this._hidden = this._hidden || new Set()
    this._render()
  },
  updated() {
    this._render()
  },
  destroyed() {
    try {
      this._resizeObserver?.disconnect()
    } catch (_e) {}
    try {
      this._tooltipCleanup?.()
    } catch (_e) {}
    this._tooltipCleanup = null
    this.el.removeEventListener("click", this._chartClickArbiter, true)
    this._chartClickArbiter = null
    this.rangeController?.destroy()
    this.rangeController = null
    this._rangeEmitter = null
    this._lastRenderFingerprint = null
  },
  _renderIfChanged(force = false) {
    const dimensions = nfChartDims(this.el, {
      minW: 360,
      minH: 220,
      margin: {top: 8, right: 110, bottom: 18, left: 44},
    })
    const fingerprint = stackedChartFingerprint(this.el, dimensions)
    if (!force && fingerprint === this._lastRenderFingerprint && stackedRenderTreeIntact(this.el, fingerprint)) {
      return
    }

    this._lastRenderFingerprint = fingerprint
    this._draw(dimensions)
  },
  _draw(dimensions = null) {
    const el = this.el
    const svg = nfEnsureSVG(el)
    if (!svg) return

    svg.removeAttribute(RENDER_FINGERPRINT_ATTRIBUTE)
    svg.removeAttribute("data-netflow-stacked-interaction")

    const {raw, keys, colors} = nfParseSeriesData(el)
    let overlays = []
    try {
      overlays = JSON.parse(el.dataset.overlays || "[]")
    } catch (_e) {
      overlays = []
    }

    const {width, height, margin: m, iw, ih} =
      dimensions ||
      nfChartDims(el, {
        minW: 360,
        minH: 220,
        margin: {top: 8, right: 110, bottom: 18, left: 44},
      })

    try {
      this._tooltipCleanup?.()
    } catch (_e) {}
    this._tooltipCleanup = null

    nfClearSVG(svg, width, height)

    if (!Array.isArray(raw) || raw.length === 0 || !Array.isArray(keys) || keys.length === 0) {
      this._disableRangeSelection()
      return
    }

    const data = nfNormalizeTimeSeries(raw, keys)

    if (data.length === 0) {
      this._disableRangeSelection()
      return
    }

    const visibleKeys = keys.filter((k) => !this._hidden.has(k))
    if (visibleKeys.length === 0) {
      this._disableRangeSelection()
      return
    }

    const onLegendToggle = (k) => {
      if (this._hidden.has(k)) {
        this._hidden.delete(k)
      } else {
        this._hidden.add(k)
      }
      this._render(true)
    }
    const onSeriesClick = (key) => {
      const field = el.dataset.seriesField || ""
      if (field) this.pushEvent("netflow_stack_series", {field, value: key})
    }
    const frame = renderStackedFrame(
      {
        colors,
        data,
        el,
        hidden: this._hidden,
        ih,
        iw,
        keys,
        margin: m,
        onLegendToggle,
        onSeriesClick,
        overlays,
        svg,
        visibleKeys,
      },
      this._stackedRenderDependencies,
    )
    if (!frame?.g || typeof frame.x !== "function") {
      this._disableRangeSelection()
      return
    }
    const {g, x} = frame

    // Brush-zoom: opt-in via data-zoomable="true"
    let interaction = "static"
    if (el.dataset.zoomable === "true") {
      interaction = "brush"
      this._disableRangeSelection()
      renderStackedBrush(
        {
          g,
          height: ih,
          onZoom: ({start, end}) => this.pushEvent("chart_zoom", {start, end}),
          width: iw,
          x,
        },
        this._stackedRenderDependencies,
      )
    } else if (el.dataset.rangeEvent) {
      interaction = "range"
      const overlay = renderStackedRangeOverlay({g, height: ih})

      this._updateRangeSelection({
        height: ih,
        intervals: parseRangeIntervals(el.dataset.rangeIntervals),
        marginLeft: m.left,
        marginTop: m.top,
        overlay,
        plotWidth: iw,
        status: el.querySelector("[data-range-status]"),
        svg,
        x,
        renderedTimes: data.map((row) => row.t),
      })
    } else {
      this._disableRangeSelection()
    }

    const attachTimeTooltip = this._attachTimeTooltip || nfAttachTimeTooltip
    this._tooltipCleanup = attachTimeTooltip(el, {
      data,
      keys: visibleKeys,
      timeZone: netflowDisplayTimeZone(el.dataset.timezone),
      x,
      xOffset: m.left,
      plotLeft: m.left,
      plotWidth: iw,
      viewBoxWidth: width,
      valueAt: (row, k) => row?.[k] || 0,
      formatValue: (v) => nfFormatRateValue(el.dataset.units, v),
    })

    svg.setAttribute(RENDER_FINGERPRINT_ATTRIBUTE, this._lastRenderFingerprint || "")
    svg.setAttribute("data-netflow-stacked-interaction", interaction)
  },
  _updateRangeSelection({
    height,
    intervals,
    marginLeft,
    marginTop = 8,
    overlay,
    plotWidth,
    renderedTimes = null,
    status,
    svg,
    x,
  }) {
    const eventName = this.el.dataset.rangeEvent
    if (this.el.dataset.zoomable === "true" || !eventName) {
      this._disableRangeSelection()
      return
    }

    const buckets = rangeBucketsForScale(intervals, x, renderedTimes)
    const timeZone = netflowDisplayTimeZone(this.el.dataset.timezone)
    this._rangeEmitter ||= ({start, end}) => this.pushEvent(this.el.dataset.rangeEvent, {start, end})

    const viewPointForEvent = (event, continuing = false) => {
      const rect = svg?.getBoundingClientRect()
      if (!rect || rect.width <= 0 || rect.height <= 0) return null

      const [viewWidth, viewHeight] = svgViewBoxSize(svg, rect)
      const svgX = ((event.clientX - rect.left) / rect.width) * viewWidth
      const svgY = ((event.clientY - rect.top) / rect.height) * viewHeight
      const plotX = svgX - marginLeft
      const plotY = svgY - marginTop

      if (!continuing && (plotX < 0 || plotX > plotWidth || plotY < 0 || plotY > height)) return null
      return Math.max(0, Math.min(plotWidth, plotX))
    }

    const options = {
      bindingKey: JSON.stringify([eventName, buckets, marginLeft, marginTop, plotWidth, height]),
      buckets,
      continuationXForEvent: (event) => viewPointForEvent(event, true),
      emit: this._rangeEmitter,
      eventKey: eventName,
      formatStatus: (range) => netflowRangeSelectionStatus(range, timeZone),
      overlay,
      plotBounds: () => ({left: 0, right: plotWidth}),
      root: this.el,
      status,
      statusKey: timeZone,
      svg,
      viewXForEvent: viewPointForEvent,
    }

    if (this.rangeController) {
      this.rangeController.update(options)
    } else {
      this.rangeController = new ChartRangeSelectionController(options)
    }
  },
  _disableRangeSelection() {
    this.rangeController?.destroy()
    this.rangeController = null
  },
}

function parseRangeIntervals(serialized) {
  try {
    const parsed = JSON.parse(serialized || "[]")
    return Array.isArray(parsed) ? parsed : []
  } catch (_error) {
    return []
  }
}

function svgViewBoxSize(svg, rect) {
  const values = svg?.getAttribute("viewBox")?.trim().split(/\s+/).map(Number)
  if (values?.length === 4 && Number.isFinite(values[2]) && Number.isFinite(values[3])) {
    return [values[2], values[3]]
  }
  return [rect.width, rect.height]
}

export function renderStackedFrame(
  {
    colors,
    data,
    el,
    hidden,
    ih,
    iw,
    keys,
    margin,
    onLegendToggle,
    onSeriesClick,
    overlays,
    svg,
    visibleKeys,
  },
  dependencies = {},
) {
  const selectRoot = dependencies?.selectRoot || d3.select
  const buildLegend = dependencies?.buildLegend || nfBuildLegend
  // Draw order matters: if the largest series is drawn last, it visually hides thin layers.
  // Sort keys by descending total so big series go "under" smaller ones.
  const keyTotals = new Map()
  for (const key of visibleKeys) {
    let sum = 0
    for (const row of data) sum += Number(row?.[key] || 0)
    keyTotals.set(key, sum)
  }
  const stackKeys = visibleKeys
    .slice()
    .sort((a, b) => (keyTotals.get(b) || 0) - (keyTotals.get(a) || 0))
  const series = d3.stack().keys(stackKeys)(data)
  const maxY = d3.max(series, (stackedSeries) => d3.max(stackedSeries, (point) => point[1])) || 1
  const x = d3.scaleTime().domain(d3.extent(data, (row) => row.t)).range([0, iw])
  const y = d3.scaleLinear().domain([0, maxY]).nice().range([ih, 0])
  const g = selectRoot(svg)
    .append("g")
    .attr("data-netflow-stacked-render-root", "")
    .attr("transform", `translate(${margin.left},${margin.top})`)
  const color = nfColorScale(keys, colors)
  const yTicks = yGridTicks(y, 4)

  g.append("g")
    .attr("pointer-events", "none")
    .selectAll("line")
    .data(yTicks)
    .join("line")
    .attr("x1", 0)
    .attr("x2", iw)
    .attr("y1", (value) => y(value))
    .attr("y2", (value) => y(value))
    .attr("stroke", "currentColor")
    .attr("stroke-opacity", 0.12)
    .attr("stroke-width", 1)

  nfRenderYGrid(g, y, iw, {tickCount: 4})

  const area = d3
    .area()
    .x((point) => x(point.data.t))
    .y0((point) => y(point[0]))
    .y1((point) => y(point[1]))
    .curve(d3.curveMonotoneX)

  g.append("g")
    .selectAll("path")
    .data(series)
    .join("path")
    .attr("d", area)
    .attr("fill", (stackedSeries) => color(stackedSeries.key))
    .attr("fill-opacity", 0.55)
    .attr("cursor", el.dataset.seriesField ? "pointer" : "default")
    .on("click", (_event, stackedSeries) => onSeriesClick(stackedSeries.key))

  renderTotalOverlays({g, iw, overlays, x, y})

  const legend = g.append("g").attr("transform", `translate(${iw + 12}, 6)`)
  buildLegend(legend, keys, color, hidden, onLegendToggle)

  g.append("g")
    .attr("transform", `translate(0,${ih})`)
    .call(
      d3
        .axisBottom(x)
        .ticks(5)
        .tickFormat(netflowAxisTimeFormatter(el.dataset.timezone))
        .tickSizeOuter(0),
    )
    .call(nfStyleChartAxis)

  g.append("g")
    .call(
      d3
        .axisLeft(y)
        .ticks(4)
        .tickFormat((value) => nfFormatRateValue(el.dataset.units, value))
        .tickSizeOuter(0),
    )
    .call(nfStyleChartAxis)

  return {g, x}
}

function renderTotalOverlays({g, iw, overlays, x, y}) {
  if (!Array.isArray(overlays) || overlays.length === 0) return

  const overlayStrokeForKey = (key) => {
    if (String(key).startsWith("prev:")) return "#A1A1AA"
    if (String(key).startsWith("rev:")) return "#00E676"
    return "#A1A1AA"
  }
  const overlayDashForKey = (key) => {
    if (String(key).startsWith("prev:")) return "6,4"
    if (String(key).startsWith("rev:")) return "3,2"
    return "6,4"
  }
  const line = d3
    .line()
    .x((point) => x(point.t))
    .y((point) => y(point.v))
    .curve(d3.curveMonotoneX)
  const overlayGroup = g.append("g").attr("pointer-events", "none")

  for (const overlay of overlays) {
    if (!overlay || typeof overlay.key !== "string") continue
    const key = String(overlay.key || "")
    const dataPoints = (Array.isArray(overlay.points) ? overlay.points : [])
      .map((point) => ({t: new Date(point.t), v: Number(point.v || 0)}))
      .filter(
        (point) =>
          point.t instanceof Date && !Number.isNaN(point.t.getTime()) && Number.isFinite(point.v),
      )
      .sort((a, b) => a.t - b.t)
    if (dataPoints.length === 0) continue

    overlayGroup
      .append("path")
      .datum(dataPoints)
      .attr("fill", "none")
      .attr("stroke", overlayStrokeForKey(key))
      .attr("stroke-width", 1.75)
      .attr("stroke-opacity", 0.8)
      .attr("stroke-dasharray", overlayDashForKey(key))
      .attr("d", line)

    const last = dataPoints[dataPoints.length - 1]
    const label = key.startsWith("prev:") ? "prev" : key.startsWith("rev:") ? "rev" : key
    overlayGroup
      .append("text")
      .attr("x", Math.min(iw - 2, x(last.t) + 4))
      .attr("y", y(last.v))
      .attr("dy", "0.35em")
      .attr("font-size", 10)
      .attr("opacity", 0.7)
      .attr("fill", "currentColor")
      .text(label)
  }
}

export function renderStackedBrush({g, height, onZoom, width, x}, dependencies = {}) {
  const brushFactory = dependencies?.brushFactory || d3.brushX
  const brushGroup = g.append("g").attr("class", "brush")
  const brush = brushFactory()
    .extent([
      [0, 0],
      [width, height],
    ])
    .on("end", (event) => {
      if (!event.selection) return
      const [start, end] = event.selection.map(x.invert)
      brushGroup.call(brush.move, null)
      onZoom({start: start.toISOString(), end: end.toISOString()})
    })

  brushGroup.call(brush)
}

export function renderStackedRangeOverlay({g, height}) {
  return g
    .append("rect")
    .attr("data-range-overlay", "")
    .attr("y", 0)
    .attr("height", height)
    .attr("class", "hidden fill-sr-brand/15 stroke-sr-brand/70")
    .attr("stroke-width", 1)
    .attr("pointer-events", "none")
    .node()
}
