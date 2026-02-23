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
  },
  _draw() {
    const el = this.el
    const svg = nfEnsureSVG(el)
    if (!svg) return

    const {raw, keys, colors} = nfParseSeriesData(el)
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

    const maxY = d3.max(visibleKeys, (k) => d3.max(data, (d) => d[k])) || 1
    const x = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([0, iw])
    const y = d3.scaleLinear().domain([0, maxY]).nice().range([ih, 0])

    const g = d3.select(svg).append("g").attr("transform", `translate(${m.left},${m.top})`)

    const color = nfColorScale(keys, colors)

    const strokeForKey = (k) => {
      if (String(k).startsWith("prev:")) return "#94a3b8"
      if (String(k).startsWith("rev:")) return color(String(k).slice(4))
      return color(k)
    }

    const dashForKey = (k) => {
      if (String(k).startsWith("prev:")) return "6,4"
      if (String(k).startsWith("rev:")) return "3,2"
      return null
    }

    const opacityForKey = (k) => {
      if (String(k).startsWith("prev:")) return 0.75
      if (String(k).startsWith("rev:")) return 0.65
      return 0.85
    }

    const line = (k) =>
      d3
        .line()
        .x((d) => x(d.t))
        .y((d) => y(d[k]))
        .curve(d3.curveMonotoneX)

    g.append("g")
      .selectAll("path")
      .data(visibleKeys)
      .join("path")
      .attr("fill", "none")
      .attr("stroke", (k) => strokeForKey(k))
      .attr("stroke-opacity", (k) => opacityForKey(k))
      .attr("stroke-width", 1.75)
      .attr("stroke-dasharray", (k) => dashForKey(k))
      .attr("d", (k) => line(k)(data))

    const legend = g.append("g").attr("transform", `translate(${iw + 12}, 6)`)
    nfBuildLegend(legend, keys, strokeForKey, this._hidden, (k) => {
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
