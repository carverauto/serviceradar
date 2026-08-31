/**
 * FlowRateChart — canvas time-series with axes, gridlines, and labels.
 *
 * Data attrs:
 *   data-points — JSON array of {t: timestamp, v: number}
 *   data-color  — stroke/fill color
 */
import {
  axisUserTimeFormatter,
  canonicalUtcInstant,
  formatUserTime,
} from "../../utils/user_time"

const DEFAULT_TIME_ZONE = "Etc/UTC"

function displayTimeZone(timeZone) {
  return typeof timeZone === "string" && timeZone.trim() !== ""
    ? timeZone
    : DEFAULT_TIME_ZONE
}

export function numberOrNull(value) {
  if (value === null || value === undefined || value === "") return null

  const number = Number(value)
  return Number.isFinite(number) ? number : null
}

export function parsePoints(raw) {
  let parsed = []
  try {
    parsed = JSON.parse(raw || "[]")
  } catch (_e) {
    parsed = []
  }

  if (!Array.isArray(parsed)) return []

  return parsed
    .map((p) => ({
      t: p?.t,
      v: numberOrNull(p?.v),
    }))
}

export function contiguousValidSegments(points) {
  const segments = []
  let current = []

  for (let i = 0; i < points.length; i += 1) {
    const point = points[i]
    if (point?.v === null || !Number.isFinite(point?.v)) {
      if (current.length > 0) segments.push(current)
      current = []
      continue
    }

    current.push({...point, idx: i})
  }

  if (current.length > 0) segments.push(current)
  return segments
}

export function contiguousValueRuns(points) {
  return contiguousValidSegments(points).map((segment) =>
    segment.map(({idx: _idx, ...point}) => point),
  )
}

function formatRate(value) {
  const abs = Math.abs(value)
  if (abs >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`
  if (abs >= 1_000) return `${(value / 1_000).toFixed(1)}K`
  return `${Math.round(value)}`
}

export function flowRateTimeLabel(raw, {timeZone = "Etc/UTC", locale} = {}) {
  return axisUserTimeFormatter({timeZone, locale})(raw)
}

export function flowRateAccessibility(points, {timeZone = DEFAULT_TIME_ZONE, locale} = {}) {
  const zone = displayTimeZone(timeZone)
  const canonical = (Array.isArray(points) ? points : [])
    .map(point => canonicalUtcInstant(point?.t))
    .filter(Boolean)

  if (canonical.length === 0) {
    return {
      start: null,
      end: null,
      timeZone: zone,
      ariaLabel: `Flow rate chart; no canonical time range; display zone ${zone}`,
    }
  }

  const start = canonical[0]
  const end = canonical[canonical.length - 1]
  const label = instant =>
    formatUserTime(instant, {timeZone: zone, style: "tooltip", locale})?.text || instant

  return {
    start,
    end,
    timeZone: zone,
    ariaLabel: `Flow rate from ${label(start)} to ${label(end)}; display zone ${zone}; canonical UTC range ${start} to ${end}`,
  }
}

function applyFlowRateAccessibility(el, metadata) {
  el.setAttribute("role", "img")
  el.setAttribute("aria-label", metadata.ariaLabel)
  el.setAttribute("title", metadata.ariaLabel)
  el.dataset.timeAxisZone = metadata.timeZone

  if (metadata.start && metadata.end) {
    el.dataset.timeAxisStart = metadata.start
    el.dataset.timeAxisEnd = metadata.end
  } else {
    delete el.dataset.timeAxisStart
    delete el.dataset.timeAxisEnd
  }
}

export default {
  mounted() {
    this.draw()
    this._resizeObserver = new ResizeObserver(() => this.draw())
    this._resizeObserver.observe(this.el)
  },

  updated() {
    this.draw()
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
  },

  draw() {
    const canvas = this.el.querySelector("canvas")
    if (!canvas) return

    const points = parsePoints(this.el.dataset.points)
    applyFlowRateAccessibility(
      this.el,
      flowRateAccessibility(points, {timeZone: this.el.dataset.timezone}),
    )

    const dpr = window.devicePixelRatio || 1
    const rect = this.el.getBoundingClientRect()
    const w = Math.max(0, Math.floor(rect.width))
    const h = Math.max(0, Math.floor(rect.height))
    if (w === 0 || h === 0) return

    canvas.width = w * dpr
    canvas.height = h * dpr
    canvas.style.width = `${w}px`
    canvas.style.height = `${h}px`

    const ctx = canvas.getContext("2d")
    if (!ctx) return
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.scale(dpr, dpr)
    ctx.clearRect(0, 0, w, h)

    const padLeft = 48
    const padRight = 12
    const padTop = 10
    const padBottom = 24
    const plotW = Math.max(1, w - padLeft - padRight)
    const plotH = Math.max(1, h - padTop - padBottom)

    const color = this.el.dataset.color || "oklch(0.65 0.24 150)"

    const validPoints = points.filter((p) => Number.isFinite(p.v))

    if (validPoints.length < 2 || points.length < 2) {
      ctx.fillStyle = "rgba(115, 115, 115, 0.85)"
      ctx.font = "12px ui-sans-serif, system-ui, sans-serif"
      ctx.fillText("No flow-rate data", padLeft, padTop + 16)
      return
    }

    const values = validPoints.map((p) => p.v)
    const minVal = Math.min(0, ...values)
    const maxVal = Math.max(...values)
    const paddedMax = maxVal <= minVal ? minVal + 1 : maxVal * 1.05
    const range = paddedMax - minVal

    const xFor = (i) => padLeft + (i / (points.length - 1)) * plotW
    const yFor = (v) => padTop + (1 - (v - minVal) / range) * plotH
    const segments = contiguousValidSegments(points)

    // Horizontal grid + y labels
    const yTicks = 4
    ctx.font = "11px ui-sans-serif, system-ui, sans-serif"
    for (let i = 0; i <= yTicks; i++) {
      const t = i / yTicks
      const y = padTop + t * plotH
      const value = paddedMax - t * range

      ctx.strokeStyle = "rgba(148, 163, 184, 0.25)"
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(padLeft, y)
      ctx.lineTo(w - padRight, y)
      ctx.stroke()

      ctx.fillStyle = "rgba(100, 116, 139, 0.95)"
      ctx.textAlign = "right"
      ctx.textBaseline = "middle"
      ctx.fillText(formatRate(value), padLeft - 6, y)
    }

    // Vertical guide lines
    const xTicks = [0, Math.floor((points.length - 1) / 2), points.length - 1]
    for (const idx of xTicks) {
      const x = xFor(idx)
      ctx.strokeStyle = "rgba(148, 163, 184, 0.2)"
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(x, padTop)
      ctx.lineTo(x, h - padBottom)
      ctx.stroke()
    }

    // Area
    ctx.fillStyle = color
    ctx.globalAlpha = 0.15
    for (const segment of segments) {
      if (segment.length < 2) continue
      ctx.beginPath()
      ctx.moveTo(xFor(segment[0].idx), h - padBottom)
      for (const point of segment) {
        ctx.lineTo(xFor(point.idx), yFor(point.v))
      }
      ctx.lineTo(xFor(segment[segment.length - 1].idx), h - padBottom)
      ctx.closePath()
      ctx.fill()
    }

    // Line
    ctx.globalAlpha = 1
    ctx.strokeStyle = color
    ctx.lineWidth = 2
    for (const segment of segments) {
      if (segment.length < 2) {
        const point = segment[0]
        ctx.beginPath()
        ctx.arc(xFor(point.idx), yFor(point.v), 2, 0, Math.PI * 2)
        ctx.fillStyle = color
        ctx.fill()
        continue
      }

      ctx.beginPath()
      for (let i = 0; i < segment.length; i += 1) {
        const point = segment[i]
        const x = xFor(point.idx)
        const y = yFor(point.v)
        if (i === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.stroke()
    }

    // X labels
    ctx.fillStyle = "rgba(100, 116, 139, 0.95)"
    ctx.textAlign = "center"
    ctx.textBaseline = "top"
    for (const idx of xTicks) {
      const label = flowRateTimeLabel(points[idx]?.t, {
        timeZone: this.el.dataset.timezone || "Etc/UTC",
      })
      if (!label) continue
      ctx.fillText(label, xFor(idx), h - padBottom + 6)
    }
  },
}
