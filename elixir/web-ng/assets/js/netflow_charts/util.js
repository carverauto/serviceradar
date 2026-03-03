import * as d3 from "d3"

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
    const x = evt.clientX - rect.left
    const y = evt.clientY - rect.top
    const innerX = Math.max(0, Math.min(rect.width, x))
    const t = xScale.invert(innerX)
    const idx = bisect(data, t)
    const row = data[idx]
    if (!row) return

    const timeLabel = row.t instanceof Date ? row.t.toISOString() : String(row.t || "")
    const lines = keys
      .slice(0, 8)
      .map((k) => {
        const v = valueAt(row, k)
        return `<div class="flex items-center justify-between gap-2"><span class="truncate">${escapeHtml(
          k
        )}</span><span class="font-mono">${escapeHtml(formatValue(v))}</span></div>`
      })
      .join("")

    tooltip.innerHTML = `${lines}<div class="mt-1 text-[10px] text-base-content/60 font-mono">${escapeHtml(
      timeLabel
    )}</div>`
    tooltip.classList.remove("hidden")

    const pad = 8
    const ttRect = tooltip.getBoundingClientRect()
    const maxLeft = rect.width - (ttRect.width || 180) - pad
    const left = Math.max(pad, Math.min(maxLeft, innerX + 12))
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
