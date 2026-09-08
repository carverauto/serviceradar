import {timeseriesClientXToPointIndex, timeseriesNearestPointIndexByX, timeseriesPointToLocalX} from "./geometry"
import {hoverPosition, plotGeometryFromDataset} from "../../utils/chart_hover_geometry"
import {dashboardUserTimeHtml} from "../../utils/dashboard_user_time"
import {axisUserTimeFormatter} from "../../utils/user_time"
import {localizeTimeseriesTimeTitles} from "./TimeseriesChart"

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
    const seriesData = JSON.parse(el.dataset.series || "[]")
    const timezone = el.dataset.timezone || "Etc/UTC"
    const axisFormatter = axisUserTimeFormatter({timeZone: timezone})

    el.querySelectorAll?.("[data-time-axis-iso]").forEach((node) => {
      const instant = node.dataset.timeAxisIso
      node.textContent = axisFormatter(instant) || instant
    })

    localizeTimeseriesTimeTitles(el, timezone)

    const escapeHtml = (s) =>
      String(s || "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;")

    if (!svg || !tooltip || !hoverLine || seriesData.length === 0) return

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

    const formatValue = (value, unit) => {
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
      let hoverX = e.clientX - rect.left

      const rows = seriesData
        .map((series) => {
          const points = Array.isArray(series.points) ? series.points : []
          if (points.length === 0) return null
          const idx =
            timeseriesNearestPointIndexByX(points, viewX) ??
            timeseriesClientXToPointIndex(e.clientX, rect, points.length)
          const point = points[idx]
          if (!point) return null
          hoverX = timeseriesPointToLocalX(point, idx, rect, points.length, {
            viewBoxWidth: geometry.viewBoxWidth,
            chartLeftPad: geometry.plotLeft,
            chartRightPad: geometry.plotRight,
          })
          return {
            label: series.label || "series",
            color: series.color || "#A1A1AA",
            unit: series.unit || "number",
            dt: point.dt,
            value: formatValue(point.v, series.unit || "number"),
          }
        })
        .filter(Boolean)

      if (rows.length === 0) return

      const instant = rows.find((row) => row.dt)?.dt || ""
      const timeHtml = dashboardUserTimeHtml(instant, {timeZone: timezone, style: "tooltip"})
      const lines = rows
        .map((row) => {
          const bullet = `<span style="color:${escapeHtml(row.color)}">&bull;</span>`
          return `<div>${bullet} ${escapeHtml(row.label)}: ${escapeHtml(row.value)}</div>`
        })
        .join("")

      tooltip.innerHTML = `${lines}<div class="text-[10px] text-base-content/60 mt-1">${timeHtml}</div>`
      tooltip.classList.remove("hidden")
      hoverLine.classList.remove("hidden")

      const tooltipX = Math.min(
        rect.width - tooltip.offsetWidth - 8,
        Math.max(8, hoverX - tooltip.offsetWidth / 2),
      )
      tooltip.style.left = `${tooltipX}px`
      tooltip.style.top = "-24px"
      hoverLine.style.left = `${hoverX}px`
    }

    const hideTooltip = () => {
      tooltip.classList.add("hidden")
      hoverLine.classList.add("hidden")
    }

    svgContainer.addEventListener("mousemove", showTooltip)
    svgContainer.addEventListener("mouseleave", hideTooltip)

    this.cleanup = () => {
      svgContainer.removeEventListener("mousemove", showTooltip)
      svgContainer.removeEventListener("mouseleave", hideTooltip)
    }
  },
  destroyed() {
    if (this.cleanup) this.cleanup()
  },
}
