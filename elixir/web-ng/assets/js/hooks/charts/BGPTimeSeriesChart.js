import * as d3 from "d3"

import {ensureTooltip, escapeHtml} from "../../netflow_charts/util"

export function bgpSeriesValue(row, asNumber) {
  const raw = row?.values?.[asNumber]
  if (raw === null || raw === undefined) return null

  const value = Number(raw)
  return Number.isFinite(value) ? value : null
}

export default {
  mounted() {
    this.renderChart()
  },
  updated() {
    this.renderChart()
  },
  destroyed() {
    try {
      this._tooltipCleanup?.()
    } catch (_e) {}
  },
  renderChart() {
    const series = JSON.parse(this.el.dataset.series || "[]")
    const data = JSON.parse(this.el.dataset.data || "[]")

    if (!series.length || !data.length) return

    try {
      this._tooltipCleanup?.()
    } catch (_e) {}

    this.el.innerHTML = ""

    const margin = { top: 20, right: 120, bottom: 30, left: 60 }
    const width = Math.max(1, this.el.clientWidth - margin.left - margin.right)
    const height = Math.max(1, this.el.clientHeight - margin.top - margin.bottom)

    const svg = d3
      .select(this.el)
      .append("svg")
      .attr("width", width + margin.left + margin.right)
      .attr("height", height + margin.top + margin.bottom)
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`)

    const times = data.map((d) => new Date(d.time))
    const rows = data.map((d, i) => ({...d, t: times[i]}))
    const x = d3.scaleTime().domain(d3.extent(times)).range([0, width])

    const allValues = data
      .flatMap((d) => Object.values(d.values || {}))
      .map((value) => Number(value))
      .filter((value) => Number.isFinite(value))
    const y = d3
      .scaleLinear()
      .domain([0, d3.max(allValues) || 1])
      .range([height, 0])

    const color = d3.scaleOrdinal(d3.schemeCategory10)

    svg
      .append("g")
      .attr("transform", `translate(0,${height})`)
      .call(d3.axisBottom(x))

    svg.append("g").call(d3.axisLeft(y))

    const line = d3
      .line()
      .defined((d) => d !== null)
      .x((d, i) => x(times[i]))
      .y((d) => y(d))

    series.forEach((as_number) => {
      const values = data.map((d) => bgpSeriesValue(d, as_number))

      svg
        .append("path")
        .datum(values)
        .attr("fill", "none")
        .attr("stroke", color(as_number))
        .attr("stroke-width", 2)
        .attr("d", line)

      const legend = svg
        .append("g")
        .attr(
          "transform",
          `translate(${width + 10}, ${series.indexOf(as_number) * 20})`,
        )

      legend
        .append("line")
        .attr("x1", 0)
        .attr("x2", 20)
        .attr("y1", 0)
        .attr("y2", 0)
        .attr("stroke", color(as_number))
        .attr("stroke-width", 2)

      legend
        .append("text")
        .attr("x", 25)
        .attr("y", 5)
        .text(`AS ${as_number}`)
        .style("font-size", "12px")
        .attr("fill", "currentColor")
    })

    const hover = svg.append("g").attr("pointer-events", "none").style("display", "none")
    hover
      .append("line")
      .attr("y1", 0)
      .attr("y2", height)
      .attr("stroke", "currentColor")
      .attr("stroke-opacity", 0.35)
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "3,3")

    const tooltip = ensureTooltip(this.el)
    const bisect = d3.bisector((d) => d.t).center

    const hideTooltip = () => {
      tooltip.classList.add("hidden")
      hover.style("display", "none")
    }

    const onMove = (event) => {
      const rect = this.el.getBoundingClientRect()
      const plotX = Math.max(0, Math.min(width, event.clientX - rect.left - margin.left))
      const row = rows[bisect(rows, x.invert(plotX))]
      if (!row) {
        hideTooltip()
        return
      }

      const lineX = x(row.t)
      hover.style("display", null)
      hover.select("line").attr("x1", lineX).attr("x2", lineX)

      const lines = series
        .slice(0, 8)
        .map((asNumber) => {
          const value = bgpSeriesValue(row, asNumber)
          return `<div class="flex items-center justify-between gap-3"><span>${escapeHtml(
            `AS ${asNumber}`
          )}</span><span class="font-mono">${escapeHtml(value === null ? "no data" : value.toFixed(0))}</span></div>`
        })
        .join("")

      tooltip.innerHTML = `${lines}<div class="mt-1 text-[10px] text-base-content/60 font-mono">${escapeHtml(
        row.t instanceof Date ? row.t.toISOString() : String(row.t || "")
      )}</div>`
      tooltip.classList.remove("hidden")

      const pad = 8
      const ttRect = tooltip.getBoundingClientRect()
      const left = margin.left + lineX + 12
      const maxLeft = rect.width - (ttRect.width || 180) - pad
      tooltip.style.left = `${Math.max(pad, Math.min(maxLeft, left))}px`
      tooltip.style.top = `${Math.max(pad, Math.min(rect.height - 48, event.clientY - rect.top - 12))}px`
    }

    this.el.addEventListener("mousemove", onMove)
    this.el.addEventListener("mouseleave", hideTooltip)
    this._tooltipCleanup = () => {
      this.el.removeEventListener("mousemove", onMove)
      this.el.removeEventListener("mouseleave", hideTooltip)
    }
  },
}
