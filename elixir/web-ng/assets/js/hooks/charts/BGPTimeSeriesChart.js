import * as d3 from "d3"

import {
  ensureTooltip,
  escapeHtml,
  netflowAxisTimeFormatter,
  netflowDisplayTimeZone,
  netflowTooltipTimeHtml,
  renderYGrid,
  styleChartAxis,
} from "../../netflow_charts/util"

export function numberOrNull(value) {
  if (value === null || value === undefined || value === "") return null

  const number = Number(value)
  return Number.isFinite(number) ? number : null
}

export function bgpSeriesValue(row, asNumber) {
  return numberOrNull(row?.values?.[asNumber])
}

export function valuesForSeries(data, asNumber) {
  return (Array.isArray(data) ? data : []).map((d) => bgpSeriesValue(d, asNumber))
}

export function finiteSeriesValues(data, series) {
  return (Array.isArray(data) ? data : [])
    .flatMap((d) => (Array.isArray(series) ? series : []).map((asNumber) => bgpSeriesValue(d, asNumber)))
    .filter((value) => Number.isFinite(value))
}

export function nearestBGPDatum(data, targetTime) {
  if (!Array.isArray(data) || data.length === 0) return null
  const target = targetTime instanceof Date ? targetTime : new Date(targetTime)
  if (Number.isNaN(target.getTime())) return null

  const bisect = d3.bisector((d) => new Date(d.time)).center
  return data[bisect(data, target)] || null
}

export function bgpTooltipRows(row, series) {
  return (Array.isArray(series) ? series : [])
    .map((asNumber) => ({asNumber, value: bgpSeriesValue(row, asNumber)}))
    .filter((item) => Number.isFinite(item.value))
}

export function bgpChartRows(data) {
  return (Array.isArray(data) ? data : []).map((row) => ({...row, t: new Date(row.time)}))
}

export function bgpTimeScale(rows, width) {
  return d3
    .scaleUtc()
    .domain(d3.extent(rows, (row) => row.t))
    .range([0, width])
}

export function bgpAxisTimeFormatter(timeZone) {
  return netflowAxisTimeFormatter(timeZone)
}

export function bgpTooltipTimeHtml(value, timeZone) {
  return netflowTooltipTimeHtml(value, timeZone)
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
    const timeZone = netflowDisplayTimeZone(this.el.dataset.timezone)

    if (!series.length || !data.length) return

    try {
      this._tooltipCleanup?.()
    } catch (_e) {}

    this.el.innerHTML = ""

    const margin = { top: 20, right: 120, bottom: 30, left: 60 }
    const width = Math.max(1, this.el.clientWidth - margin.left - margin.right)
    const height = Math.max(1, this.el.clientHeight - margin.top - margin.bottom)

    const rootSvg = d3
      .select(this.el)
      .append("svg")
      .attr("width", width + margin.left + margin.right)
      .attr("height", height + margin.top + margin.bottom)

    const svg = rootSvg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`)

    const rows = bgpChartRows(data)
    const times = rows.map((row) => row.t)
    const x = bgpTimeScale(rows, width)

    const allValues = finiteSeriesValues(data, series)
    const y = d3
      .scaleLinear()
      .domain([0, d3.max(allValues) || 1])
      .nice()
      .range([height, 0])

    const color = d3.scaleOrdinal(d3.schemeCategory10)

    renderYGrid(svg, y, width, {tickCount: 4})

    svg
      .append("g")
      .attr("transform", `translate(0,${height})`)
      .call(d3.axisBottom(x).ticks(5).tickFormat(bgpAxisTimeFormatter(timeZone)).tickSizeOuter(0))
      .call(styleChartAxis)

    svg.append("g").call(d3.axisLeft(y).ticks(4).tickSizeOuter(0)).call(styleChartAxis)

    const line = d3
      .line()
      .defined((d) => d !== null)
      .x((d, i) => x(times[i]))
      .y((d) => y(d))

    series.forEach((as_number) => {
      const values = valuesForSeries(data, as_number)

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

    const tooltip = ensureTooltip(this.el)
    const hover = svg.append("g").attr("pointer-events", "none").attr("display", "none")
    const hoverLine = hover
      .append("line")
      .attr("y1", 0)
      .attr("y2", height)
      .attr("stroke", "currentColor")
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "3 3")
      .attr("opacity", 0.5)
    const hoverMarkers = hover.append("g")

    const hideHover = () => {
      tooltip.classList.add("hidden")
      hover.attr("display", "none")
    }

    const showHover = (event) => {
      const rect = this.el.getBoundingClientRect()
      const localX = Math.max(0, Math.min(width, event.clientX - rect.left - margin.left))
      const row = nearestBGPDatum(rows, x.invert(localX))

      if (!row) {
        hideHover()
        return
      }

      const tooltipRows = bgpTooltipRows(row, series)
      if (tooltipRows.length === 0) {
        hideHover()
        return
      }

      hover.attr("display", null)
      hoverLine.attr("x1", x(new Date(row.time))).attr("x2", x(new Date(row.time)))

      hoverMarkers
        .selectAll("circle")
        .data(tooltipRows, (d) => d.asNumber)
        .join("circle")
        .attr("cx", x(new Date(row.time)))
        .attr("cy", (d) => y(d.value))
        .attr("r", 3)
        .attr("fill", (d) => color(d.asNumber))
        .attr("stroke", "white")

      const lines = tooltipRows
        .slice(0, 8)
        .map(
          (item) =>
            `<div class="flex items-center justify-between gap-2"><span class="truncate">AS ${escapeHtml(
              item.asNumber,
            )}</span><span class="font-mono">${escapeHtml(item.value)}</span></div>`,
        )
        .join("")

      tooltip.innerHTML = `${lines}<div class="mt-1 text-[10px] text-base-content/60 font-mono">${bgpTooltipTimeHtml(
        row.time,
        timeZone,
      )}</div>`
      tooltip.classList.remove("hidden")

      const ttRect = tooltip.getBoundingClientRect()
      const pad = 8
      const markerX = x(new Date(row.time)) + margin.left
      const left = Math.max(pad, Math.min(rect.width - (ttRect.width || 180) - pad, markerX + 12))
      const top = Math.max(pad, Math.min(rect.height - 48, event.clientY - rect.top - 12))
      tooltip.style.left = `${left}px`
      tooltip.style.top = `${top}px`
    }

    this.el.addEventListener("mousemove", showHover)
    this.el.addEventListener("mouseleave", hideHover)
    this._tooltipCleanup = () => {
      this.el.removeEventListener("mousemove", showHover)
      this.el.removeEventListener("mouseleave", hideHover)
    }
  },
}
