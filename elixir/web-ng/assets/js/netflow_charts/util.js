import * as d3 from "d3"

import {hoverPosition} from "../utils/chart_hover_geometry"
import {axisUserTimeFormatter, canonicalUtcInstant, formatUserTime} from "../utils/user_time"

const DEFAULT_NETFLOW_TIME_ZONE = "Etc/UTC"

export function netflowDisplayTimeZone(timeZone) {
  return typeof timeZone === "string" && timeZone.trim() !== ""
    ? timeZone
    : DEFAULT_NETFLOW_TIME_ZONE
}

export function netflowAxisTimeFormatter(timeZone) {
  return axisUserTimeFormatter({timeZone: netflowDisplayTimeZone(timeZone)})
}

export function netflowTooltipTimeLabel(canonical, timeZone) {
  if (typeof canonical !== "string") return String(canonical || "")

  return (
    formatUserTime(canonical, {
      timeZone: netflowDisplayTimeZone(timeZone),
      style: "tooltip",
    })?.text || canonical
  )
}

export function netflowTooltipTimeHtml(value, timeZone) {
  const canonical = canonicalUtcInstant(value)
  if (!canonical) return escapeHtml(String(value || ""))

  const displayZone = netflowDisplayTimeZone(timeZone)
  const label = netflowTooltipTimeLabel(canonical, displayZone)
  const title = `${canonical} (UTC); display zone ${displayZone}`
  const ariaLabel = `${label}; display zone ${displayZone}; canonical UTC ${canonical}`

  return `<time datetime="${escapeHtml(canonical)}" data-canonical-utc="${escapeHtml(
    canonical,
  )}" title="${escapeHtml(title)}" aria-label="${escapeHtml(ariaLabel)}">${escapeHtml(label)}</time>`
}

export function netflowRangeSelectionStatus({start, end}, timeZone) {
  const displayZone = netflowDisplayTimeZone(timeZone)

  return `Selected ${netflowTooltipTimeLabel(start, displayZone)} to ${netflowTooltipTimeLabel(end, displayZone)}; display zone ${displayZone}; canonical UTC ${start} to ${end}`
}

export function parseJSON(value, fallback) {
  try {
    return JSON.parse(value)
  } catch (_e) {
    return fallback
  }
}

export function ensureOverlay(el) {
  // Create a relative-position overlay for tooltip UI without touching SVG layout.
  try {
    const style = window.getComputedStyle(el)
    if (style.position === "static") {
      el.style.position = "relative"
    }
  } catch (_e) {}

  let overlay = el.querySelector(":scope > .nf-overlay")
  if (!overlay) {
    overlay = document.createElement("div")
    overlay.className = "nf-overlay"
    overlay.style.position = "absolute"
    overlay.style.inset = "0"
    overlay.style.pointerEvents = "none"
    el.appendChild(overlay)
  }
  return overlay
}

export function ensureTooltip(el) {
  const overlay = ensureOverlay(el)
  let tt = overlay.querySelector(":scope > .nf-tooltip")
  if (!tt) {
    tt = document.createElement("div")
    tt.className =
      "nf-tooltip hidden rounded-md border border-base-300 bg-base-100/95 px-2 py-1 text-[11px] shadow-sm"
    tt.style.position = "absolute"
    tt.style.pointerEvents = "none"
    tt.style.maxWidth = "280px"
    overlay.appendChild(tt)
  }
  return tt
}

export function attachTimeTooltip(el, opts) {
  const svg = ensureSVG(el)
  if (!svg) return () => {}

  const data = opts.data || []
  const keys = opts.keys || []
  const xScale = opts.x
  const plotLeft = opts.plotLeft ?? 0
  const plotWidth = opts.plotWidth
  const viewBoxWidth = opts.viewBoxWidth
  const valueAt = opts.valueAt
  const formatValue = opts.formatValue || ((v) => fmtNumber(v))

  if (!Array.isArray(data) || data.length === 0) return () => {}
  if (!Array.isArray(keys) || keys.length === 0) return () => {}
  if (!xScale || typeof xScale.invert !== "function") return () => {}
  if (typeof valueAt !== "function") return () => {}

  const tooltip = ensureTooltip(el)
  const bisect = d3.bisector((d) => d.t).center

  const onMove = (evt) => {
    const rect = el.getBoundingClientRect()
    const position = hoverPosition(evt.clientX, rect, {
      plotLeft,
      plotWidth: plotWidth ?? rect.width,
      viewBoxWidth: viewBoxWidth ?? rect.width,
    })
    const x = position.lineX
    const y = evt.clientY - rect.top
    const innerX = position.plotX
    const t = xScale.invert(innerX)
    const idx = bisect(data, t)
    const row = data[idx]
    if (!row) return

    const timeHtml = netflowTooltipTimeHtml(row.t, opts.timeZone)
    const lines = keys
      .slice(0, 8)
      .map((k) => {
        const v = valueAt(row, k)
        return `<div class="flex items-center justify-between gap-2"><span class="truncate">${escapeHtml(
          k
        )}</span><span class="font-mono">${escapeHtml(formatValue(v))}</span></div>`
      })
      .join("")

    tooltip.innerHTML = `${lines}<div class="mt-1 text-[10px] text-base-content/60 font-mono">${timeHtml}</div>`
    tooltip.classList.remove("hidden")

    const pad = 8
    const ttRect = tooltip.getBoundingClientRect()
    const maxLeft = rect.width - (ttRect.width || 180) - pad
    const left = Math.max(pad, Math.min(maxLeft, x + 12))
    const top = Math.max(pad, Math.min(rect.height - 48, y - 12))
    tooltip.style.left = `${left}px`
    tooltip.style.top = `${top}px`
  }

  const onLeave = () => {
    tooltip.classList.add("hidden")
  }

  el.addEventListener("mousemove", onMove)
  el.addEventListener("mouseleave", onLeave)
  return () => {
    el.removeEventListener("mousemove", onMove)
    el.removeEventListener("mouseleave", onLeave)
  }
}

export function clientXToScaleX(clientX, rect, xScale, opts = {}) {
  const xOffset = Number(opts.xOffset || 0)
  const localX = clientX - Number(rect?.left || 0) - xOffset
  const range = typeof xScale?.range === "function" ? xScale.range() : [0, Number(rect?.width || 0)]
  const finiteRange = range.map((value) => Number(value)).filter((value) => Number.isFinite(value))
  const min = finiteRange.length > 0 ? Math.min(...finiteRange) : 0
  const max = finiteRange.length > 0 ? Math.max(...finiteRange) : Math.max(1, Number(rect?.width || 0))

  return Math.max(min, Math.min(max, localX))
}

export function ensureSVG(el) {
  const svg = el.querySelector("svg")
  return svg || null
}

export function clearSVG(svg, width, height) {
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
  svg.setAttribute("preserveAspectRatio", "xMidYMid meet")
  while (svg.firstChild) svg.removeChild(svg.firstChild)
}

export function chartDims(el, opts = {}) {
  const minW = opts.minW ?? 360
  const minH = opts.minH ?? 220
  const margin = opts.margin ?? { top: 8, right: 10, bottom: 18, left: 44 }

  const width = Math.max(minW, el.clientWidth || 0)
  const height = Math.max(minH, el.clientHeight || 0)
  const iw = Math.max(1, width - margin.left - margin.right)
  const ih = Math.max(1, height - margin.top - margin.bottom)

  return { width, height, margin, iw, ih }
}

export function yTickValues(scale, count = 4) {
  if (!scale || typeof scale.ticks !== "function") return []

  const tickCount = Math.max(2, Number(count) || 4)
  return scale.ticks(tickCount).filter((value) => Number.isFinite(Number(value)))
}

export function styleChartAxis(axis) {
  axis.selectAll("text").attr("font-size", 10).attr("opacity", 0.7).attr("fill", "currentColor")
  axis.selectAll("line").attr("stroke", "currentColor").attr("opacity", 0.28)
  axis.select(".domain").attr("stroke", "currentColor").attr("opacity", 0.25)
  return axis
}

export function renderYGrid(container, yScale, width, opts = {}) {
  const ticks = opts.ticks || yTickValues(yScale, opts.tickCount || 4)
  const grid = container.append("g").attr("class", opts.className || "nf-y-grid").attr("pointer-events", "none")

  grid
    .selectAll("line")
    .data(ticks)
    .join("line")
    .attr("x1", 0)
    .attr("x2", width)
    .attr("y1", (value) => yScale(value))
    .attr("y2", (value) => yScale(value))
    .attr("stroke", "currentColor")
    .attr("stroke-width", 1)
    .attr("stroke-dasharray", opts.dasharray || "2 3")
    .attr("opacity", opts.opacity ?? 0.12)

  return grid
}

export function parseSeriesData(el) {
  const raw = parseJSON(el.dataset.points || "[]", [])
  const keys = parseJSON(el.dataset.keys || "[]", [])
  const colors = parseJSON(el.dataset.colors || "{}", {})
  return { raw, keys, colors }
}

export function normalizeTimeSeries(raw, keys) {
  const data = (Array.isArray(raw) ? raw : [])
    .map((d) => {
      const t = new Date(d.t)
      const out = { t }
      for (const k of keys) out[k] = Number(d[k] || 0)
      return out
    })
    .filter((d) => d.t instanceof Date && !isNaN(d.t.getTime()))
    .sort((a, b) => a.t - b.t)

  return data
}

export function colorScale(keys, provided = {}) {
  const fallback = d3.schemeTableau10.concat(d3.schemeSet3).slice(0, Math.max(3, keys.length))
  return d3
    .scaleOrdinal()
    .domain(keys)
    .range(keys.map((k, i) => provided?.[k] || fallback[i % fallback.length]))
}

export function fmtNumber(v) {
  const n = Number(v || 0)
  if (!Number.isFinite(n)) return "0"
  if (Math.abs(n) >= 1e9) return `${(n / 1e9).toFixed(2)}G`
  if (Math.abs(n) >= 1e6) return `${(n / 1e6).toFixed(2)}M`
  if (Math.abs(n) >= 1e3) return `${(n / 1e3).toFixed(2)}K`
  return `${n.toFixed(0)}`
}

export function fmtPct(v) {
  const n = Number(v || 0)
  if (!Number.isFinite(n)) return "0%"
  return `${(n * 100).toFixed(0)}%`
}

export function buildLegend(container, keys, color, hiddenSet, onToggle) {
  const wrap = container.append("g").attr("class", "legend")

  const items = wrap
    .selectAll("g")
    .data(keys)
    .join("g")
    .attr("transform", (_d, i) => `translate(0, ${i * 14})`)
    .style("cursor", "pointer")
    .on("click", (_evt, k) => onToggle?.(k))

  items
    .append("rect")
    .attr("x", 0)
    .attr("y", -9)
    .attr("width", 10)
    .attr("height", 10)
    .attr("rx", 2)
    .attr("fill", (k) => color(k))
    .attr("fill-opacity", (k) => (hiddenSet?.has(k) ? 0.15 : 0.85))

  items
    .append("text")
    .attr("x", 14)
    .attr("y", 0)
    .attr("dy", "0.32em")
    .attr("font-size", 10)
    .attr("opacity", (k) => (hiddenSet?.has(k) ? 0.4 : 0.75))
    .attr("fill", "currentColor")
    .text((k) => {
      const s = String(k || "")
      return s.length > 22 ? s.slice(0, 19) + "..." : s
    })

  return wrap
}

export function escapeHtml(s) {
  return String(s || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}
