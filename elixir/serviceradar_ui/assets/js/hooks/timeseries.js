import {formatInstant, formatValue} from "../lib/format.js"
import {hoverPosition, nearestByX, plotGeometryFromDataset} from "../lib/hover.js"

// Hover line, tooltip and axis labels for ServiceRadarUI.Charts.area/1.
// `data-timezone` is an IANA name (browser zone when omitted).
// `data-time-format` is "auto", "time", "datetime" or "date".
// `data-locale` is a BCP 47 tag. There is no user_time coupling.
export const SrTimeseries = {
  mounted() {
    this.bind()
  },

  updated() {
    this.bind()
  },

  destroyed() {
    this.unbind()
  },

  bind() {
    this.unbind()
    const el = this.el
    const svg = el.querySelector("[data-chart-svg]")
    const tooltip = el.querySelector("[data-tooltip]")
    const hover = el.querySelector("[data-hover-line]")
    const model = parseModel(el.dataset.points)
    const time = {
      timeZone: el.dataset.timezone || undefined,
      format: el.dataset.timeFormat || "auto",
      locale: el.dataset.locale || undefined,
    }
    relabelAxis(el, time)
    if (!svg || !tooltip || !hover || !model || model.points.length === 0) return

    const frame = el.querySelector(".sr-chart-frame") || svg
    const unit = el.dataset.unit || "number"
    const onMove = (event) => show(el, svg, hover, tooltip, model, unit, time, event)
    const onLeave = () => hide(hover, tooltip)
    frame.addEventListener("pointermove", onMove)
    frame.addEventListener("pointerleave", onLeave)
    this._unbind = () => {
      frame.removeEventListener("pointermove", onMove)
      frame.removeEventListener("pointerleave", onLeave)
    }
  },

  unbind() {
    if (this._unbind) this._unbind()
    this._unbind = null
  },
}

function show(el, svg, hover, tooltip, model, unit, time, event) {
  const geometry = plotGeometryFromDataset(el, svg)
  const rect = svg.getBoundingClientRect()
  const position = hoverPosition(event.clientX, rect, geometry)
  const viewX = geometry.plotLeft + position.pct * geometry.plotWidth
  const point = nearestByX(model.points, viewX)
  if (!point) return

  hover.setAttribute("x1", String(point.x))
  hover.setAttribute("x2", String(point.x))
  hover.setAttribute("visibility", "visible")

  const rows = model.series.map((name, i) => {
    const value = Array.isArray(point.v) ? point.v[i] : null
    return `${name} ${formatValue(value, unit)}`
  })
  tooltip.replaceChildren()
  const stamp = document.createElement("div")
  stamp.className = "sr-chart-tooltip-time"
  stamp.textContent = formatInstant(point.t, {...time, format: "datetime"})
  tooltip.append(stamp)
  for (const row of rows) {
    const node = document.createElement("div")
    node.className = "sr-chart-tooltip-row"
    node.textContent = row
    tooltip.append(node)
  }
  tooltip.hidden = false
  const width = tooltip.offsetWidth || 0
  const left = Math.min(Math.max(event.offsetX - width / 2, 8), Math.max(8, rect.width - width - 8))
  tooltip.style.left = `${left}px`
  tooltip.style.top = "8px"
}

function hide(hover, tooltip) {
  hover.setAttribute("visibility", "hidden")
  tooltip.hidden = true
}

function relabelAxis(el, time) {
  const nodes = [...el.querySelectorAll("[data-sr-time]")]
  const stamps = nodes.map((node) => Date.parse(node.dataset.srTime)).filter(Number.isFinite)
  const spanMs = stamps.length ? Math.max(...stamps) - Math.min(...stamps) : 0
  for (const node of nodes) {
    const label = formatInstant(node.dataset.srTime, {...time, spanMs})
    if (label) node.textContent = label
  }
}

function parseModel(raw) {
  try {
    const parsed = JSON.parse(raw || "null")
    if (!parsed || !Array.isArray(parsed.points)) return null
    return {
      series: Array.isArray(parsed.series) ? parsed.series.map(String) : [],
      points: parsed.points,
    }
  } catch (_error) {
    return null
  }
}
