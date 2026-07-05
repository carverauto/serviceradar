import {timeseriesClientXToPointIndex, timeseriesNearestPointIndexByX, timeseriesPointToLocalX} from "./geometry"
import {hoverPosition, plotGeometryFromDataset} from "../../utils/chart_hover_geometry"

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
        tooltip.textContent = `${value} @ ${point.dt}`
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
