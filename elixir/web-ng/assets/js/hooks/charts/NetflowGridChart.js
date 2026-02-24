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
    const {width, height, margin: m, iw, ih} = nfChartDims(el, {
      minW: 360,
      minH: 220,
      margin: {top: 10, right: 110, bottom: 10, left: 10},
    })

    nfClearSVG(svg, width, height)

    if (!Array.isArray(raw) || raw.length === 0 || !Array.isArray(keys) || keys.length === 0) {
      return
    }

    const data = nfNormalizeTimeSeries(raw, keys)

    if (data.length === 0) return

    const visibleKeys = keys.filter((k) => !this._hidden.has(k))
    if (visibleKeys.length === 0) return

    const n = visibleKeys.length
    const cols = Math.ceil(Math.sqrt(n))
    const rows = Math.ceil(n / cols)
    const pad = 10
    const cw = Math.max(1, (iw - pad * (cols - 1)) / cols)
    const ch = Math.max(1, (ih - pad * (rows - 1)) / rows)

    const color = nfColorScale(keys, colors)

    const root = d3.select(svg).append("g").attr("transform", `translate(${m.left},${m.top})`)

    const legend = root.append("g").attr("transform", `translate(${iw + 12}, 6)`)
    nfBuildLegend(legend, keys, color, this._hidden, (k) => {
      if (this._hidden.has(k)) {
        this._hidden.delete(k)
      } else {
        this._hidden.add(k)
      }
      this._render()
    })

    for (let i = 0; i < n; i += 1) {
      const k = visibleKeys[i]
      const c = i % cols
      const r = Math.floor(i / cols)
      const x0 = c * (cw + pad)
      const y0 = r * (ch + pad)

      const panel = root.append("g").attr("transform", `translate(${x0},${y0})`)
      panel
        .append("rect")
        .attr("x", 0)
        .attr("y", 0)
        .attr("width", cw)
        .attr("height", ch)
        .attr("rx", 8)
        .attr("fill", "none")
        .attr("stroke", "currentColor")
        .attr("opacity", 0.12)

      const px = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([10, cw - 10])
      const maxY = d3.max(data, (d) => d[k]) || 1
      const py = d3.scaleLinear().domain([0, maxY]).nice().range([ch - 18, 18])

      const ln = d3
        .line()
        .x((d) => px(d.t))
        .y((d) => py(d[k]))
        .curve(d3.curveMonotoneX)

      panel
        .append("path")
        .datum(data)
        .attr("fill", "none")
        .attr("stroke", color(k))
        .attr("stroke-width", 1.75)
        .attr("stroke-opacity", 0.85)
        .attr("d", ln)

      panel
        .append("text")
        .attr("x", 10)
        .attr("y", 14)
        .attr("font-size", 10)
        .attr("opacity", 0.75)
        .attr("fill", "currentColor")
        .text(String(k).length > 18 ? `${String(k).slice(0, 15)}...` : String(k))
    }

    // Shared tooltip across all series (matches other time-series charts).
    const x = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([0, iw])
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
