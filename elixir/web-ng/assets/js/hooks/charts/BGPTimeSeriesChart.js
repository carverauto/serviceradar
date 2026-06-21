import * as d3 from "d3"

export function numberOrNull(value) {
  if (value === null || value === undefined || value === "") return null

  const number = Number(value)
  return Number.isFinite(number) ? number : null
}

export function valuesForSeries(data, asNumber) {
  return (Array.isArray(data) ? data : []).map((d) => numberOrNull(d?.values?.[asNumber]))
}

export function finiteSeriesValues(data, series) {
  return (Array.isArray(data) ? data : [])
    .flatMap((d) => (Array.isArray(series) ? series : []).map((asNumber) => numberOrNull(d?.values?.[asNumber])))
    .filter((value) => Number.isFinite(value))
}

export default {
  mounted() {
    this.renderChart()
  },
  updated() {
    this.renderChart()
  },
  renderChart() {
    const series = JSON.parse(this.el.dataset.series || "[]")
    const data = JSON.parse(this.el.dataset.data || "[]")

    if (!series.length || !data.length) return

    this.el.innerHTML = ""

    const margin = { top: 20, right: 120, bottom: 30, left: 60 }
    const width = this.el.clientWidth - margin.left - margin.right
    const height = this.el.clientHeight - margin.top - margin.bottom

    const svg = d3
      .select(this.el)
      .append("svg")
      .attr("width", width + margin.left + margin.right)
      .attr("height", height + margin.top + margin.bottom)
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`)

    const times = data.map((d) => new Date(d.time))
    const x = d3.scaleTime().domain(d3.extent(times)).range([0, width])

    const allValues = finiteSeriesValues(data, series)
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
  },
}
