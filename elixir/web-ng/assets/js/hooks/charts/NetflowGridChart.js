import * as d3 from "d3"

import {
  buildLegend as nfBuildLegend,
  chartDims as nfChartDims,
  clearSVG as nfClearSVG,
  colorScale as nfColorScale,
  ensureTooltip as nfEnsureTooltip,
  ensureSVG as nfEnsureSVG,
  escapeHtml as nfEscapeHtml,
  renderYGrid as nfRenderYGrid,
  styleChartAxis as nfStyleChartAxis,
  normalizeTimeSeries as nfNormalizeTimeSeries,
  parseSeriesData as nfParseSeriesData,
  yTickValues as nfYTickValues,
} from "../../netflow_charts/util"
import {nfFormatRateValue} from "../../utils/formatters"
import {canonicalUtcInstant, userTimeFormatter} from "../../utils/user_time"

export function gridTooltipTimeLabel(value, {timeZone = "Etc/UTC", locale} = {}) {
  return userTimeFormatter({timeZone, locale, style: "tooltip"})(value)
}

export function gridTooltipTimeHtml(value, {timeZone = "Etc/UTC", locale} = {}) {
  const canonical = canonicalUtcInstant(value)
  const label = gridTooltipTimeLabel(value, {timeZone, locale})
  if (!canonical) return nfEscapeHtml(label)

  const title = `${canonical} (UTC); display zone ${timeZone}`
  const ariaLabel = `${label}; display zone ${timeZone}; canonical UTC ${canonical}`

  return `<time datetime="${nfEscapeHtml(canonical)}" data-canonical-utc="${nfEscapeHtml(
    canonical,
  )}" title="${nfEscapeHtml(title)}" aria-label="${nfEscapeHtml(ariaLabel)}">${nfEscapeHtml(label)}</time>`
}

export function gridPanelLayout(keys, iw, ih, pad = 10) {
  const visibleKeys = Array.isArray(keys) ? keys : []
  const n = visibleKeys.length
  if (n === 0) return []

  const cols = Math.ceil(Math.sqrt(n))
  const rows = Math.ceil(n / cols)
  const cw = Math.max(1, (iw - pad * (cols - 1)) / cols)
  const ch = Math.max(1, (ih - pad * (rows - 1)) / rows)

  return visibleKeys.map((key, i) => {
    const col = i % cols
    const row = Math.floor(i / cols)
    return {
      key,
      x0: col * (cw + pad),
      y0: row * (ch + pad),
      width: cw,
      height: ch,
    }
  })
}

export function gridPanelAt(localX, localY, panels) {
  return (Array.isArray(panels) ? panels : []).find(
    (panel) =>
      localX >= panel.x0 &&
      localX <= panel.x0 + panel.width &&
      localY >= panel.y0 &&
      localY <= panel.y0 + panel.height,
  )
}

export function gridPanelAtPointer(clientX, clientY, rect, geometry) {
  if (!rect || !geometry) return null

  const viewBoxWidth = Number(geometry.viewBoxWidth) || Number(rect.width) || 1
  const viewBoxHeight = Number(geometry.viewBoxHeight) || Number(rect.height) || 1
  const scaleX = viewBoxWidth / Math.max(1, Number(rect.width) || 1)
  const scaleY = viewBoxHeight / Math.max(1, Number(rect.height) || 1)
  const localX = (clientX - Number(rect.left || 0)) * scaleX - Number(geometry.marginLeft || 0)
  const localY = (clientY - Number(rect.top || 0)) * scaleY - Number(geometry.marginTop || 0)

  const cellWidth = Number(geometry.cellWidth) || 1
  const cellHeight = Number(geometry.cellHeight) || 1
  const pad = Number(geometry.pad) || 0
  const cols = Math.max(1, Number(geometry.cols) || 1)
  const count = Math.max(0, Number(geometry.count) || 0)
  const col = Math.floor(localX / (cellWidth + pad))
  const row = Math.floor(localY / (cellHeight + pad))
  const panelX = localX - col * (cellWidth + pad)
  const panelY = localY - row * (cellHeight + pad)
  const index = row * cols + col

  if (
    col < 0 ||
    row < 0 ||
    index < 0 ||
    index >= count ||
    panelX < 0 ||
    panelY < 0 ||
    panelX > cellWidth ||
    panelY > cellHeight
  ) {
    return null
  }

  return {index, row, col, localX: panelX, localY: panelY}
}

export function nearestTimeRow(data, targetTime) {
  if (!Array.isArray(data) || data.length === 0) return null
  const target = targetTime instanceof Date ? targetTime : new Date(targetTime)
  if (Number.isNaN(target.getTime())) return null

  const bisect = d3.bisector((d) => d.t).center
  return data[bisect(data, target)] || null
}

export function gridYTicks(yScale, units, count = 3) {
  return nfYTickValues(yScale, count).map((value) => ({
    value,
    label: nfFormatRateValue(units, value),
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

    const pad = 10
    const panels = gridPanelLayout(visibleKeys, iw, ih, pad)

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

    const panelState = new Map()

    for (const panelSpec of panels) {
      const k = panelSpec.key
      const {x0, y0, width: cw, height: ch} = panelSpec
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

      const chartLeft = 42
      const chartRight = Math.max(chartLeft + 1, cw - 10)
      const px = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([chartLeft, chartRight])
      const maxY = d3.max(data, (d) => d[k]) || 1
      const py = d3.scaleLinear().domain([0, maxY]).nice().range([ch - 18, 18])
      panelState.set(k, {...panelSpec, xScale: px, yScale: py})

      const yTicks = gridYTicks(py, el.dataset.units, 3)
      nfRenderYGrid(panel, py, chartRight - chartLeft, {
        ticks: yTicks.map((tick) => tick.value),
        opacity: 0.1,
      }).attr("transform", `translate(${chartLeft},0)`)

      const yAxis = panel
        .append("g")
        .attr("transform", `translate(${chartLeft},0)`)
        .call(
          d3
            .axisLeft(py)
            .tickValues(yTicks.map((tick) => tick.value))
            .tickFormat((value) => yTicks.find((tick) => tick.value === value)?.label || nfFormatRateValue(el.dataset.units, value))
            .tickSizeOuter(0)
            .tickSize(3),
        )
      nfStyleChartAxis(yAxis)

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

    const tooltip = nfEnsureTooltip(el)
    const hover = root.append("g").attr("pointer-events", "none").attr("display", "none")
    const hoverLine = hover
      .append("line")
      .attr("y1", 0)
      .attr("y2", 0)
      .attr("stroke", "currentColor")
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "3 3")
      .attr("opacity", 0.5)
    const hoverPoint = hover.append("circle").attr("r", 3).attr("fill", "currentColor").attr("stroke", "white")

    const hideHover = () => {
      tooltip.classList.add("hidden")
      hover.attr("display", "none")
    }

    const onMove = (evt) => {
      const rect = el.getBoundingClientRect()
      const localX = evt.clientX - rect.left - m.left
      const localY = evt.clientY - rect.top - m.top
      const panel = gridPanelAt(localX, localY, panels)
      const state = panel && panelState.get(panel.key)

      if (!state) {
        hideHover()
        return
      }

      const [minX, maxX] = state.xScale.range()
      const panelX = Math.max(Math.min(minX, maxX), Math.min(Math.max(minX, maxX), localX - state.x0))
      const row = nearestTimeRow(data, state.xScale.invert(panelX))
      if (!row) {
        hideHover()
        return
      }

      const value = row?.[state.key] || 0
      const markerX = state.x0 + state.xScale(row.t)
      const markerY = state.y0 + state.yScale(value)
      const timeHtml = gridTooltipTimeHtml(row.t, {
        timeZone: el.dataset.timezone || "Etc/UTC",
      })

      hover.attr("display", null)
      hoverLine
        .attr("x1", markerX)
        .attr("x2", markerX)
        .attr("y1", state.y0 + 6)
        .attr("y2", state.y0 + state.height - 6)
        .attr("stroke", color(state.key))
      hoverPoint.attr("cx", markerX).attr("cy", markerY).attr("fill", color(state.key))

      tooltip.innerHTML = `<div class="flex items-center justify-between gap-2"><span class="truncate">${nfEscapeHtml(
        state.key,
      )}</span><span class="font-mono">${nfEscapeHtml(nfFormatRateValue(el.dataset.units, value))}</span></div>
        <div class="mt-1 text-[10px] text-base-content/60 font-mono">${timeHtml}</div>`
      tooltip.classList.remove("hidden")

      const padPx = 8
      const ttRect = tooltip.getBoundingClientRect()
      const maxLeft = rect.width - (ttRect.width || 180) - padPx
      const left = Math.max(padPx, Math.min(maxLeft, markerX + m.left + 12))
      const top = Math.max(padPx, Math.min(rect.height - 48, markerY + m.top - 12))
      tooltip.style.left = `${left}px`
      tooltip.style.top = `${top}px`
    }

    try {
      this._tooltipCleanup?.()
    } catch (_e) {}
    el.addEventListener("mousemove", onMove)
    el.addEventListener("mouseleave", hideHover)
    this._tooltipCleanup = () => {
      el.removeEventListener("mousemove", onMove)
      el.removeEventListener("mouseleave", hideHover)
    }
  },
}
