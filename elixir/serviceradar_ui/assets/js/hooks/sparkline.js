import {sparklinePaths} from "../lib/sparkline.js"

// Redraws the server-rendered sparkline SVG when the LiveView pushes
// `sr:update:<id>` with %{values: [...]}. Time is not involved; the points
// are a sequence. No style attributes are written.
export const SrSparkline = {
  mounted() {
    this.handleEvent(updateEvent(this.el.id), (payload) => {
      if (payload && Array.isArray(payload.values)) this.draw(payload.values, payload)
    })
  },

  updated() {
    this.draw(parseValues(this.el.dataset.values), {})
  },

  draw(values, payload) {
    const svg = this.el.querySelector("svg")
    if (!svg) return
    const paths = sparklinePaths(values, {
      smooth: payload.smooth ?? this.el.dataset.smooth,
      min: payload.min ?? this.el.dataset.min,
      max: payload.max ?? this.el.dataset.max,
    })
    const line = svg.querySelector("[data-sr-line]")
    const area = svg.querySelector("[data-sr-area]")
    const baseline = svg.querySelector("[data-sr-baseline]")
    if (line) line.setAttribute("d", paths.line)
    if (area) area.setAttribute("d", paths.area)
    if (baseline) baseline.setAttribute("visibility", paths.empty ? "visible" : "hidden")
  },
}

function updateEvent(id) {
  return `sr:update:${id}`
}

function parseValues(raw) {
  try {
    const parsed = JSON.parse(raw || "[]")
    return Array.isArray(parsed) ? parsed : []
  } catch (_error) {
    return []
  }
}
