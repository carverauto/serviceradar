import * as d3 from "d3"

import {
  attachTimeTooltip as nfAttachTimeTooltip,
  buildLegend as nfBuildLegend,
  chartDims as nfChartDims,
  clearSVG as nfClearSVG,
  colorScale as nfColorScale,
  ensureSVG as nfEnsureSVG,
  fmtPct as nfFmtPct,
  parseSeriesData as nfParseSeriesData,
} from "../../netflow_charts/util"
import {nfFormatRateValue} from "../../utils/formatters"

export function numberOrZero(value) {
  const number = Number(value || 0)
  return Number.isFinite(number) ? number : 0
}

export function normalizeStacked100Rows(points, keys) {
  const visibleKeys = Array.isArray(keys) ? keys : []

  return (Array.isArray(points) ? points : [])
    .map((d) => {
      const t = new Date(d?.t)
      const values = {}
      let sum = 0

      for (const k of visibleKeys) {
        const v = numberOrZero(d?.[k])
        values[k] = v
        sum += v
      }

      const denom = sum || 1
      const out = {t, __sum: sum}
      for (const k of visibleKeys) out[k] = values[k] / denom
      return out
    })
    .filter((d) => d.t instanceof Date && !Number.isNaN(d.t.getTime()))
    .sort((a, b) => a.t - b.t)
}

export function absoluteTotalSeries(data) {
  return (Array.isArray(data) ? data : []).map((d) => ({
    t: d.t,
    v: numberOrZero(d?.__sum),
  }))
}

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

    const visibleKeys = keys.filter((k) => !this._hidden.has(k))
    if (visibleKeys.length === 0) return

    const data = normalizeStacked100Rows(raw, visibleKeys)

    if (data.length === 0) return

    const stack = d3.stack().keys(visibleKeys)
    const series = stack(data)
    const absoluteData = absoluteTotalSeries(data)
    const maxAbsolute = d3.max(absoluteData, (d) => d.v) || 1

    const x = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([0, iw])
    const y = d3.scaleLinear().domain([0, 1]).nice().range([ih, 0])
    const yAbsolute = d3.scaleLinear().domain([0, maxAbsolute]).nice().range([ih, 0])

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

    const normalizeToPct = (points) => {
      return normalizeStacked100Rows(points, visibleKeys)
    }

    const absoluteLine = d3
      .line()
      .defined((d) => Number.isFinite(d?.v))
      .x((d) => x(d.t))
      .y((d) => yAbsolute(d.v))
      .curve(d3.curveMonotoneX)

    g.append("path")
      .datum(absoluteData)
      .attr("class", "netflow-stacked100-absolute-total")
      .attr("data-testid", "netflow-stacked100-absolute-total")
      .attr("fill", "none")
      .attr("stroke", "currentColor")
      .attr("stroke-width", 1.5)
      .attr("stroke-opacity", 0.75)
      .attr("stroke-dasharray", "4,3")
      .attr("d", absoluteLine)

    g.append("g")
      .attr("class", "netflow-stacked100-absolute-axis")
      .attr("data-testid", "netflow-stacked100-absolute-axis")
      .attr("transform", `translate(${iw},0)`)
      .call(d3.axisRight(yAbsolute).ticks(3).tickFormat((v) => nfFormatRateValue(el.dataset.units, v)).tickSize(4))
      .call((gg) => {
        gg.selectAll("text").attr("x", -6).attr("text-anchor", "end").attr("font-size", 10).attr("opacity", 0.65)
        gg.selectAll("line").attr("opacity", 0.35)
        gg.select(".domain").attr("opacity", 0.25)
      })

    // Composition overlays: dashed boundary lines (y1) per series layer.
    // We keep the same keys so the overlay reads as "previous composition" / "reverse composition".
    if (Array.isArray(overlays) && overlays.length > 0) {
      const overlaysByType = overlays.filter((o) => o && typeof o.type === "string" && Array.isArray(o.points))

      const dashForType = (t) => {
        if (t === "prev") return "6,4"
        if (t === "rev") return "3,2"
        return "6,4"
      }

      const opacityForType = (t) => {
        if (t === "prev") return 0.45
        if (t === "rev") return 0.55
        return 0.45
      }

      for (const ov of overlaysByType) {
        const od = normalizeToPct(ov.points || [])
        if (!Array.isArray(od) || od.length === 0) continue

        const oseries = d3.stack().keys(visibleKeys)(od)
        const line = d3
          .line()
          .x((d) => x(d.data.t))
          .y((d) => y(d[1]))
          .curve(d3.curveMonotoneX)

        const og = g.append("g").attr("pointer-events", "none")

        og.selectAll("path")
          .data(oseries)
          .join("path")
          .attr("fill", "none")
          .attr("stroke", (d) => color(d.key))
          .attr("stroke-width", 1.1)
          .attr("stroke-opacity", opacityForType(ov.type))
          .attr("stroke-dasharray", dashForType(ov.type))
          .attr("d", (d) => line(d))
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
      .call(d3.axisLeft(y).ticks(4).tickFormat(d3.format(".0%")).tickSizeOuter(0))
      .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

    try {
      this._tooltipCleanup?.()
    } catch (_e) {}
    this._tooltipCleanup = nfAttachTimeTooltip(el, {
      data,
      keys: visibleKeys,
      x,
      xOffset: m.left,
      valueAt: (row, k) => row?.[k] || 0,
      formatValue: (v) => nfFmtPct(v),
    })
  },
}
