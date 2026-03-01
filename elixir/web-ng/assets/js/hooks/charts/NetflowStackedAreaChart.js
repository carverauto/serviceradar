import * as d3 from "d3"

import {
  attachTimeTooltip as nfAttachTimeTooltip,
  buildLegend as nfBuildLegend,
  chartDims as nfChartDims,
  clearSVG as nfClearSVG,
  colorScale as nfColorScale,
  ensureSVG as nfEnsureSVG,
  normalizeTimeSeries as nfNormalizeTimeSeries,
  parseSeriesData as nfParseSeriesData,
} from "../../netflow_charts/util"
import {nfFormatRateValue} from "../../utils/formatters"

export default {
  mounted() {
    this._render = () => this._draw()
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
  },
  _draw() {
    const el = this.el
    const svg = nfEnsureSVG(el)
    if (!svg) return

    const {raw, keys, colors} = nfParseSeriesData(el)
    let overlays = []
    try {
      overlays = JSON.parse(el.dataset.overlays || "[]")
    } catch (_e) {
      overlays = []
    }

    const {width, height, margin: m, iw, ih} = nfChartDims(el, {
      minW: 360,
      minH: 220,
      margin: {top: 8, right: 110, bottom: 18, left: 44},
    })

    nfClearSVG(svg, width, height)

    if (!Array.isArray(raw) || raw.length === 0 || !Array.isArray(keys) || keys.length === 0) {
      return
    }

    const data = nfNormalizeTimeSeries(raw, keys)

    if (data.length === 0) return

    const visibleKeys = keys.filter((k) => !this._hidden.has(k))
    if (visibleKeys.length === 0) return

    // Draw order matters: if the largest series is drawn last, it visually hides thin layers.
    // Sort keys by descending total so big series go "under" smaller ones.
    const keyTotals = new Map()
    for (const k of visibleKeys) {
      let sum = 0
      for (const row of data) sum += Number(row?.[k] || 0)
      keyTotals.set(k, sum)
    }
    const stackKeys = visibleKeys.slice().sort((a, b) => (keyTotals.get(b) || 0) - (keyTotals.get(a) || 0))

    const stack = d3.stack().keys(stackKeys)
    const series = stack(data)

    const maxY = d3.max(series, (s) => d3.max(s, (d) => d[1])) || 1
    const x = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([0, iw])
    const y = d3.scaleLinear().domain([0, maxY]).nice().range([ih, 0])

    const g = d3.select(svg).append("g").attr("transform", `translate(${m.left},${m.top})`)

    const color = nfColorScale(keys, colors)

    const area = d3
      .area()
      .x((d) => x(d.data.t))
      .y0((d) => y(d[0]))
      .y1((d) => y(d[1]))
      .curve(d3.curveMonotoneX)

    g.append("g")
      .selectAll("path")
      .data(series)
      .join("path")
      .attr("d", area)
      .attr("fill", (d) => color(d.key))
      .attr("fill-opacity", 0.55)
      .attr("cursor", el.dataset.seriesField ? "pointer" : "default")
      .on("click", (_event, d) => {
        const field = el.dataset.seriesField || ""
        if (!field) return
        this.pushEvent("netflow_stack_series", {field, value: d.key})
      })

    // Total overlays: render dashed lines on top of the stacked area.
    // These come from SRQL (series-less) downsample queries and are keyed as `rev:*` and `prev:*`.
    if (Array.isArray(overlays) && overlays.length > 0) {
      const overlayStrokeForKey = (k) => {
        if (String(k).startsWith("prev:")) return "#94a3b8"
        if (String(k).startsWith("rev:")) return "#10b981"
        return "#94a3b8"
      }

      const overlayDashForKey = (k) => {
        if (String(k).startsWith("prev:")) return "6,4"
        if (String(k).startsWith("rev:")) return "3,2"
        return "6,4"
      }

      const line = d3
        .line()
        .x((d) => x(d.t))
        .y((d) => y(d.v))
        .curve(d3.curveMonotoneX)

      const og = g.append("g").attr("pointer-events", "none")

      for (const ov of overlays) {
        if (!ov || typeof ov.key !== "string") continue
        const k = String(ov.key || "")
        const pts = Array.isArray(ov?.points) ? ov.points : []
        const dataPts = pts
          .map((p) => ({t: new Date(p.t), v: Number(p.v || 0)}))
          .filter((d) => d.t instanceof Date && !Number.isNaN(d.t.getTime()) && Number.isFinite(d.v))
          .sort((a, b) => a.t - b.t)

        if (dataPts.length === 0) continue

        og.append("path")
          .datum(dataPts)
          .attr("fill", "none")
          .attr("stroke", overlayStrokeForKey(k))
          .attr("stroke-width", 1.75)
          .attr("stroke-opacity", 0.8)
          .attr("stroke-dasharray", overlayDashForKey(k))
          .attr("d", line)

        const last = dataPts[dataPts.length - 1]
        const label = k.startsWith("prev:") ? "prev" : k.startsWith("rev:") ? "rev" : k

        og.append("text")
          .attr("x", Math.min(iw - 2, x(last.t) + 4))
          .attr("y", y(last.v))
          .attr("dy", "0.35em")
          .attr("font-size", 10)
          .attr("opacity", 0.7)
          .attr("fill", "currentColor")
          .text(label)
      }
    }

    const legend = g.append("g").attr("transform", `translate(${iw + 12}, 6)`)
    nfBuildLegend(legend, keys, color, this._hidden, (k) => {
      if (this._hidden.has(k)) {
        this._hidden.delete(k)
      } else {
        this._hidden.add(k)
      }
      this._render()
    })

    g.append("g")
      .attr("transform", `translate(0,${ih})`)
      .call(d3.axisBottom(x).ticks(5).tickSizeOuter(0))
      .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

    g.append("g")
      .call(d3.axisLeft(y).ticks(4).tickSizeOuter(0))
      .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

    // Brush-zoom: opt-in via data-zoomable="true"
    if (el.dataset.zoomable === "true") {
      const brush = d3
        .brushX()
        .extent([
          [0, 0],
          [iw, ih],
        ])
        .on("end", (event) => {
          if (!event.selection) return
          const [x0, x1] = event.selection.map(x.invert)
          d3.select(event.target).call(brush.move, null)
          this.pushEvent("chart_zoom", {
            start: x0.toISOString(),
            end: x1.toISOString(),
          })
        })

      g.append("g").attr("class", "brush").call(brush)
    }

    try {
      this._tooltipCleanup?.()
    } catch (_e) {}
    this._tooltipCleanup = nfAttachTimeTooltip(el, {
      data,
      keys: visibleKeys,
      x,
      valueAt: (row, k) => row?.[k] || 0,
      formatValue: (v) => nfFormatRateValue(el.dataset.units, v),
    })
  },
}
