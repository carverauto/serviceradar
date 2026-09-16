import {timeseriesClientXToPointIndex, timeseriesNearestPointIndexByX, timeseriesPointToLocalX} from "./geometry"
import {hoverPosition, plotGeometryFromDataset} from "../../utils/chart_hover_geometry"
import {dashboardUserTimeHtml} from "../../utils/dashboard_user_time"
import {adaptiveUserTimeAxis, canonicalUtcInstant, formatUserTime} from "../../utils/user_time"

const timeTitleFallbacks = new WeakMap()

export default {
  mounted() {
    this.bindChart()
  },
  updated() {
    this.bindChart()
  },
  bindChart() {
    if (this.cleanup) {
      this.cleanup()
      this.cleanup = null
    }

    const el = this.el
    const svg = el.querySelector("[data-chart-svg]") || el.querySelector("svg")
    const tooltip = el.querySelector("[data-tooltip]")
    const hoverLine = el.querySelector("[data-hover-line]")
    const pointsData = JSON.parse(el.dataset.points || "[]")
    const unit = el.dataset.unit || "number"
    const timezone = el.dataset.timezone || "Etc/UTC"
    localizeTimeseriesAxis(el, timezone)

    localizeTimeseriesTimeTitles(el, timezone)

    if (!svg || !tooltip || !hoverLine || pointsData.length === 0) return

    const svgContainer = svg.parentElement

    const formatBytes = (value) => {
      const abs = Math.abs(value)
      if (abs >= 1e9) return `${(value / 1e9).toFixed(2)} GB`
      if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} MB`
      if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} KB`
      return `${value.toFixed(1)} B`
    }

    const formatHz = (value) => {
      const abs = Math.abs(value)
      if (abs >= 1e9) return `${(value / 1e9).toFixed(2)} GHz`
      if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} MHz`
      if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} KHz`
      return `${value.toFixed(1)} Hz`
    }

    const formatBitsPerSec = (value) => {
      const abs = Math.abs(value)
      if (abs >= 1e9) return `${(value / 1e9).toFixed(2)} Gbit/s`
      if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} Mbit/s`
      if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} Kbit/s`
      return `${value.toFixed(1)} bit/s`
    }

    const formatCountPerSec = (value) => {
      const abs = Math.abs(value)
      if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} M/s`
      if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} K/s`
      return `${value.toFixed(2)} /s`
    }

    const formatValue = (value) => {
      if (value === null || value === undefined) return "no data"
      if (typeof value !== "number") return value
      switch (unit) {
        case "percent":
          return `${value.toFixed(1)}%`
        case "bytes_per_sec":
          return `${formatBytes(value)}/s`
        case "bits_per_sec":
          return formatBitsPerSec(value)
        case "bytes":
          return formatBytes(value)
        case "hz":
          return formatHz(value)
        case "count_per_sec":
          return formatCountPerSec(value)
        default:
          return value.toFixed(2)
      }
    }

    const showTooltip = (e) => {
      const rect = svg.getBoundingClientRect()
      const geometry = plotGeometryFromDataset(el, svg, rect)
      const position = hoverPosition(e.clientX, rect, geometry)
      const viewX = geometry.plotLeft + position.pct * geometry.plotWidth
      const idx =
        timeseriesNearestPointIndexByX(pointsData, viewX) ??
        timeseriesClientXToPointIndex(e.clientX, rect, pointsData.length)
      const point = pointsData[idx]
      const x = timeseriesPointToLocalX(point, idx, rect, pointsData.length, {
        viewBoxWidth: geometry.viewBoxWidth,
        chartLeftPad: geometry.plotLeft,
        chartRightPad: geometry.plotRight,
      })

      if (point) {
        const value = formatValue(point.v)
        const timeHtml = dashboardUserTimeHtml(point.dt, {timeZone: timezone, style: "tooltip"})
        tooltip.innerHTML = `${escapeHtml(value)} @ ${timeHtml}`
        tooltip.classList.remove("hidden")
        hoverLine.classList.remove("hidden")

        // Position tooltip
        const tooltipX = Math.min(
          rect.width - tooltip.offsetWidth - 8,
          Math.max(8, x - tooltip.offsetWidth / 2),
        )
        tooltip.style.left = `${tooltipX}px`
        tooltip.style.top = "-24px"

        // Position hover line
        hoverLine.style.left = `${x}px`
      }
    }

    const hideTooltip = () => {
      tooltip.classList.add("hidden")
      hoverLine.classList.add("hidden")
    }

    svgContainer.addEventListener("mousemove", showTooltip)
    svgContainer.addEventListener("mouseleave", hideTooltip)

    // Store cleanup function
    this.cleanup = () => {
      svgContainer.removeEventListener("mousemove", showTooltip)
      svgContainer.removeEventListener("mouseleave", hideTooltip)
    }
  },
  destroyed() {
    if (this.cleanup) this.cleanup()
  },
}

export function localizeTimeseriesTimeTitles(root, timeZone) {
  root.querySelectorAll?.("[data-time-title-iso]").forEach((node) => {
    const instant = node.dataset.timeTitleIso || ""
    const canonical = canonicalUtcInstant(instant)
    const title = node.querySelector?.("title")
    if (!title) return

    const currentText = title.textContent || ""
    const previous = timeTitleFallbacks.get(title)
    const state =
      !previous || previous.instant !== instant || currentText !== previous.rendered
        ? {fallback: currentText, instant, rendered: currentText}
        : previous

    title.textContent = state.fallback
    const localized = canonical
      ? formatUserTime(canonical, {timeZone, style: "tooltip"})?.text
      : null

    if (localized) {
      const accessible = `${localized}; display zone ${timeZone}; canonical UTC ${canonical}`
      title.textContent = state.fallback.includes(instant)
        ? state.fallback.replace(instant, accessible)
        : `${state.fallback}; ${accessible}`
    }

    state.rendered = title.textContent
    timeTitleFallbacks.set(title, state)
  })
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

export function localizeTimeseriesAxis(el, timeZone) {
  const labels = Array.from(el.querySelectorAll?.("[data-time-axis-iso]") || [])
  const originalTimes = labels.map((node) => Date.parse(node.dataset.timeAxisIso)).filter(Number.isFinite)
  const requestedStart = Date.parse(el.dataset.timeStart)
  const requestedEnd = Date.parse(el.dataset.timeEnd)
  const start = Number.isFinite(requestedStart) ? requestedStart : Math.min(...originalTimes)
  const end = Number.isFinite(requestedEnd) ? requestedEnd : Math.max(...originalTimes)
  const axis = adaptiveUserTimeAxis([start, end], {timeZone, count: labels.length})
  const left = Number(el.dataset.chartLeftPad)
  const width = Number(el.dataset.chartWidth) - left - Number(el.dataset.chartRightPad)
  const ticks = axis.ticks || originalTimes
  const reposition = Number.isFinite(start) && Number.isFinite(end) && end > start && Number.isFinite(left) && width > 0
  const grid = Array.from(el.querySelectorAll?.("[data-time-axis-grid]") || [])
  const marks = Array.from(el.querySelectorAll?.("[data-time-axis-tick]") || [])

  labels.forEach((node, index) => {
    const instant = reposition ? ticks[index] : node.dataset.timeAxisIso
    if (reposition) {
      const hidden = instant === undefined
      for (const part of [node, grid[index], marks[index]]) {
        if (part) part.setAttribute("visibility", hidden ? "hidden" : "visible")
      }
      if (hidden) return
      const x = left + (instant - start) / (end - start) * width
      node.setAttribute("x", String(x))
      for (const line of [grid[index], marks[index]]) {
        if (line) {
          line.setAttribute("x1", String(x))
          line.setAttribute("x2", String(x))
        }
      }
    }
    node.textContent = axis.format(instant) || instant
  })
}
