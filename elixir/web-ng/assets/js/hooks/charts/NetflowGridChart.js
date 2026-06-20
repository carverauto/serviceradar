import * as d3 from "d3"

import {
  buildLegend as nfBuildLegend,
  chartDims as nfChartDims,
  clearSVG as nfClearSVG,
  colorScale as nfColorScale,
  ensureTooltip as nfEnsureTooltip,
  ensureSVG as nfEnsureSVG,
  escapeHtml as nfEscapeHtml,
  normalizeTimeSeries as nfNormalizeTimeSeries,
  parseSeriesData as nfParseSeriesData,
} from "../../netflow_charts/util"
import {yGridTicks} from "../../utils/chart_axis_grid"
import {nfFormatRateValue} from "../../utils/formatters"

export function gridPanelAtPointer(clientX, clientY, rect, geometry) {
  const widthScale = Number(geometry.viewBoxWidth || rect.width || 1) / Math.max(1, Number(rect.width || 1))
  const heightScale = Number(geometry.viewBoxHeight || rect.height || 1) / Math.max(1, Number(rect.height || 1))
  const rootX = (Number(clientX || 0) - Number(rect.left || 0)) * widthScale - Number(geometry.marginLeft || 0)
  const rootY = (Number(clientY || 0) - Number(rect.top || 0)) * heightScale - Number(geometry.marginTop || 0)
  const stepX = Number(geometry.cellWidth || 0) + Number(geometry.pad || 0)
  const stepY = Number(geometry.cellHeight || 0) + Number(geometry.pad || 0)

  if (stepX <= 0 || stepY <= 0 || rootX < 0 || rootY < 0) return null

  const col = Math.floor(rootX / stepX)
  const row = Math.floor(rootY / stepY)
  const localX = rootX - col * stepX
  const localY = rootY - row * stepY

  if (
    col < 0 ||
    row < 0 ||
    col >= Number(geometry.cols || 0) ||
    row >= Number(geometry.rows || 0) ||
    localX < 0 ||
    localY < 0 ||
    localX > Number(geometry.cellWidth || 0) ||
    localY > Number(geometry.cellHeight || 0)
  ) {
    return null
  }

  const index = row * Number(geometry.cols || 0) + col
  return index < Number(geometry.count || 0) ? {index, row, col, localX, localY, rootX, rootY} : null
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

    const panelStates = []

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
      const yTicks = yGridTicks(py, 3)

      const grid = panel.append("g").attr("pointer-events", "none")

      grid
        .selectAll("line")
        .data(yTicks)
        .join("line")
        .attr("x1", 10)
        .attr("x2", cw - 10)
        .attr("y1", (d) => py(d))
        .attr("y2", (d) => py(d))
        .attr("stroke", "currentColor")
        .attr("stroke-opacity", 0.12)
        .attr("stroke-width", 1)

      grid
        .selectAll("text")
        .data(yTicks)
        .join("text")
        .attr("x", 8)
        .attr("y", (d) => py(d) + 3)
        .attr("text-anchor", "end")
        .attr("font-size", 8)
        .attr("fill", "currentColor")
        .attr("opacity", 0.55)
        .text((d) => nfFormatRateValue(el.dataset.units, d))

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

      const hover = panel.append("g").attr("pointer-events", "none").style("display", "none")

      hover
        .append("line")
        .attr("y1", 0)
        .attr("y2", ch)
        .attr("stroke", "currentColor")
        .attr("stroke-opacity", 0.35)
        .attr("stroke-width", 1)
        .attr("stroke-dasharray", "3,3")

      hover
        .append("circle")
        .attr("r", 3)
        .attr("fill", color(k))
        .attr("stroke", "currentColor")
        .attr("stroke-width", 1)

      panelStates.push({key: k, px, py, hover})
    }

    try {
      this._tooltipCleanup?.()
    } catch (_e) {}

    const tooltip = nfEnsureTooltip(el)
    const bisect = d3.bisector((d) => d.t).center
    const hideTooltip = () => {
      tooltip.classList.add("hidden")
      for (const state of panelStates) state.hover.style("display", "none")
    }

    const onMove = (event) => {
      const rect = el.getBoundingClientRect()
      const hit = gridPanelAtPointer(event.clientX, event.clientY, rect, {
        viewBoxWidth: width,
        viewBoxHeight: height,
        marginLeft: m.left,
        marginTop: m.top,
        cellWidth: cw,
        cellHeight: ch,
        pad,
        cols,
        rows,
        count: n,
      })

      if (!hit) {
        hideTooltip()
        return
      }

      const state = panelStates[hit.index]
      const t = state.px.invert(Math.max(10, Math.min(cw - 10, hit.localX)))
      const row = data[bisect(data, t)]
      if (!row) {
        hideTooltip()
        return
      }

      for (const candidate of panelStates) candidate.hover.style("display", "none")

      const x = state.px(row.t)
      const y = state.py(row[state.key] || 0)
      state.hover.style("display", null)
      state.hover.select("line").attr("x1", x).attr("x2", x)
      state.hover.select("circle").attr("cx", x).attr("cy", y)

      tooltip.innerHTML = `<div class="flex items-center justify-between gap-3"><span>${nfEscapeHtml(
        state.key
      )}</span><span class="font-mono">${nfEscapeHtml(
        nfFormatRateValue(el.dataset.units, row[state.key] || 0)
      )}</span></div><div class="mt-1 text-[10px] text-base-content/60 font-mono">${nfEscapeHtml(
        row.t instanceof Date ? row.t.toISOString() : String(row.t || "")
      )}</div>`
      tooltip.classList.remove("hidden")

      const padPx = 8
      const ttRect = tooltip.getBoundingClientRect()
      const panelX = m.left + hit.col * (cw + pad) + x
      const panelY = m.top + hit.row * (ch + pad) + y
      const maxLeft = rect.width - (ttRect.width || 180) - padPx
      tooltip.style.left = `${Math.max(padPx, Math.min(maxLeft, panelX + 12))}px`
      tooltip.style.top = `${Math.max(padPx, Math.min(rect.height - 48, panelY - 12))}px`
    }

    el.addEventListener("mousemove", onMove)
    el.addEventListener("mouseleave", hideTooltip)
    this._tooltipCleanup = () => {
      el.removeEventListener("mousemove", onMove)
      el.removeEventListener("mouseleave", hideTooltip)
    }
  },
}
