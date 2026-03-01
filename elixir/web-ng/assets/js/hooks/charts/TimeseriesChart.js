export default {
  mounted() {
    const el = this.el
    const svg = el.querySelector("svg")
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

    const formatCountPerSec = (value) => {
      const abs = Math.abs(value)
      if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} M/s`
      if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} K/s`
      return `${value.toFixed(2)} /s`
    }

    const formatValue = (value) => {
      if (typeof value !== "number") return value
      switch (unit) {
        case "percent":
          return `${value.toFixed(1)}%`
        case "bytes_per_sec":
          return `${formatBytes(value)}/s`
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
      const x = e.clientX - rect.left
      const pct = Math.max(0, Math.min(1, x / rect.width))
      const idx = Math.round(pct * (pointsData.length - 1))
      const point = pointsData[idx]

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
