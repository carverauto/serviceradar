import {describe, expect, it} from "vitest"

import TimeseriesChart, {localizeTimeseriesAxis} from "./TimeseriesChart"
import TimeseriesCombinedChart from "./TimeseriesCombinedChart"

function classList() {
  const classes = new Set(["hidden"])

  return {
    add: (name) => classes.add(name),
    remove: (name) => classes.delete(name),
    contains: (name) => classes.has(name),
  }
}

function chartElement(dataset) {
  const titleInstant = "2026-08-30T18:00:00Z"
  const titleFallback = `sample at ${titleInstant}`
  const title = {textContent: titleFallback}
  const timeTitleMarker = {
    dataset: {timeTitleIso: titleInstant},
    querySelector(selector) {
      return selector === "title" ? title : null
    },
  }
  const tooltip = {
    classList: classList(),
    innerHTML: "",
    offsetWidth: 40,
    style: {},
    textContent: "",
  }
  const hoverLine = { classList: classList(), style: {} }
  const container = {
    listeners: {},
    addEventListener(name, listener) {
      this.listeners[name] = listener
    },
    removeEventListener(name, listener) {
      if (this.listeners[name] === listener) delete this.listeners[name]
    },
  }
  const markerContainer = {
    listeners: {},
    addEventListener(name, listener) {
      this.listeners[name] = listener
    },
    removeEventListener(name, listener) {
      if (this.listeners[name] === listener) delete this.listeners[name]
    },
  }
  const markerSvg = {
    parentElement: markerContainer,
    getBoundingClientRect: () => ({ left: 0, width: 12 }),
    getAttribute: (name) => (name === "viewBox" ? "0 0 12 12" : null),
  }
  const svg = {
    parentElement: container,
    getBoundingClientRect: () => ({ left: 0, width: 100 }),
    getAttribute: (name) => (name === "viewBox" ? "0 0 800 140" : null),
  }

  return {
    dataset,
    hoverLine,
    querySelector(selector) {
      if (selector === "[data-chart-svg]") return svg
      if (selector === "svg") return markerSvg
      if (selector === "[data-tooltip]") return tooltip
      if (selector === "[data-hover-line]") return hoverLine
      return null
    },
    querySelectorAll(selector) {
      if (selector === "[data-time-title-iso]") return [timeTitleMarker]
      return []
    },
    markerContainer,
    svgContainer: container,
    timeTitle: title,
    titleFallback,
    tooltip,
  }
}

describe("TimeseriesChart hook", () => {
  it("binds hover after LiveView updates an initially empty chart", () => {
    const el = chartElement({ points: "[]", unit: "percent", timezone: "America/Chicago" })
    const ctx = { el, ...TimeseriesChart }

    ctx.mounted()
    expect(el.svgContainer.listeners.mousemove).toBeUndefined()

    el.dataset.points = JSON.stringify([{ dt: "2026-08-30T18:00:00Z", v: 42.4 }])
    el.dataset.chartWidth = "800"
    el.dataset.chartLeftPad = "72"
    el.dataset.chartRightPad = "32"
    ctx.updated()

    expect(el.svgContainer.listeners.mousemove).toEqual(expect.any(Function))
    expect(el.markerContainer.listeners.mousemove).toBeUndefined()

    el.svgContainer.listeners.mousemove({ clientX: 10 })

    expect(el.tooltip.classList.contains("hidden")).toBe(false)
    expect(el.tooltip.innerHTML).toContain("42.4% @")
    expect(el.tooltip.innerHTML).toContain("01:00:00 PM GMT-5")
    expect(el.tooltip.innerHTML).toContain('<time datetime="2026-08-30T18:00:00Z"')
    expect(el.tooltip.innerHTML).toContain(
      'aria-label="Aug 30, 2026, 01:00:00 PM GMT-5; display zone America/Chicago; canonical UTC 2026-08-30T18:00:00Z"',
    )
    expect(el.hoverLine.classList.contains("hidden")).toBe(false)
    expect(el.hoverLine.style.left).toBe("9px")

    ctx.destroyed()
    expect(el.svgContainer.listeners.mousemove).toBeUndefined()
  })

  it("re-localizes SVG titles from their canonical fallback on every LiveView update", () => {
    const el = chartElement({
      chartLeftPad: "72",
      chartRightPad: "32",
      chartWidth: "800",
      points: JSON.stringify([{dt: "2026-08-30T18:00:00Z", v: 42.4}]),
      timezone: "America/Chicago",
      unit: "percent",
    })
    const ctx = {el, ...TimeseriesChart}

    ctx.mounted()
    expect(el.timeTitle.textContent).toContain("GMT-5")
    expect(el.timeTitle.textContent).toContain("display zone America/Chicago")
    expect(el.timeTitle.textContent).toContain("canonical UTC 2026-08-30T18:00:00Z")

    el.dataset.timezone = "Europe/London"
    ctx.updated()

    expect(el.timeTitle.textContent).toContain("GMT+1")
    expect(el.timeTitle.textContent).toContain("display zone Europe/London")
    expect(el.timeTitle.textContent).toContain("canonical UTC 2026-08-30T18:00:00Z")
    expect(el.timeTitle.textContent).not.toContain("America/Chicago")
    expect(el.timeTitle.textContent).not.toContain("GMT-5")

    el.dataset.timezone = "Mars/Olympus"
    ctx.updated()

    expect(el.timeTitle.textContent).toBe(el.titleFallback)
    ctx.destroyed()
  })
})

describe("TimeseriesCombinedChart hook", () => {
  it("binds hover after LiveView updates an initially empty combined chart", () => {
    const el = chartElement({ series: "[]", timezone: "America/Chicago" })
    const ctx = { el, ...TimeseriesCombinedChart }

    ctx.mounted()
    expect(el.svgContainer.listeners.mousemove).toBeUndefined()

    el.dataset.series = JSON.stringify([
      {
        color: "#0EA5E9",
        label: "core 0",
        points: [{ dt: "2026-08-30T18:00:00Z", v: 77.1 }],
        unit: "percent",
      },
    ])
    el.dataset.chartWidth = "800"
    el.dataset.chartLeftPad = "72"
    el.dataset.chartRightPad = "32"
    ctx.updated()

    expect(el.svgContainer.listeners.mousemove).toEqual(expect.any(Function))
    expect(el.markerContainer.listeners.mousemove).toBeUndefined()

    el.svgContainer.listeners.mousemove({ clientX: 10 })

    expect(el.tooltip.classList.contains("hidden")).toBe(false)
    expect(el.tooltip.innerHTML).toContain("core 0")
    expect(el.tooltip.innerHTML).toContain("77.1%")
    expect(el.tooltip.innerHTML).toContain("01:00:00 PM GMT-5")
    expect(el.tooltip.innerHTML).toContain('<time datetime="2026-08-30T18:00:00Z"')
    expect(el.tooltip.innerHTML).toContain(
      'aria-label="Aug 30, 2026, 01:00:00 PM GMT-5; display zone America/Chicago; canonical UTC 2026-08-30T18:00:00Z"',
    )
    expect(el.hoverLine.classList.contains("hidden")).toBe(false)
    expect(el.hoverLine.style.left).toBe("9px")

    ctx.destroyed()
    expect(el.svgContainer.listeners.mousemove).toBeUndefined()
  })

  it("re-localizes SVG titles from their canonical fallback on every LiveView update", () => {
    const el = chartElement({
      chartLeftPad: "72",
      chartRightPad: "32",
      chartWidth: "800",
      series: JSON.stringify([
        {
          color: "#0EA5E9",
          label: "core 0",
          points: [{dt: "2026-08-30T18:00:00Z", v: 77.1}],
          unit: "percent",
        },
      ]),
      timezone: "America/Chicago",
    })
    const ctx = {el, ...TimeseriesCombinedChart}

    ctx.mounted()
    expect(el.timeTitle.textContent).toContain("GMT-5")
    expect(el.timeTitle.textContent).toContain("display zone America/Chicago")
    expect(el.timeTitle.textContent).toContain("canonical UTC 2026-08-30T18:00:00Z")

    el.dataset.timezone = "Europe/London"
    ctx.updated()

    expect(el.timeTitle.textContent).toContain("GMT+1")
    expect(el.timeTitle.textContent).toContain("display zone Europe/London")
    expect(el.timeTitle.textContent).toContain("canonical UTC 2026-08-30T18:00:00Z")
    expect(el.timeTitle.textContent).not.toContain("America/Chicago")
    expect(el.timeTitle.textContent).not.toContain("GMT-5")

    el.dataset.timezone = "Mars/Olympus"
    ctx.updated()

    expect(el.timeTitle.textContent).toBe(el.titleFallback)
    ctx.destroyed()
  })
})


describe("requested timeseries window", () => {
  it("positions distinct month labels and grid lines over the requested domain", () => {
    const node = (iso) => ({dataset: {timeAxisIso: iso}, attributes: {}, setAttribute(name, value) { this.attributes[name] = value }})
    const labels = Array.from({length: 5}, (_, i) => node(new Date(Date.parse("2025-01-01T00:00:00Z") + i * 90 * 86_400_000 / 4).toISOString()))
    const grids = labels.map(() => node())
    const marks = labels.map(() => node())
    const el = {
      dataset: {timeStart: "2025-01-01T00:00:00Z", timeEnd: "2025-04-01T00:00:00Z", chartLeftPad: "72", chartRightPad: "32", chartWidth: "800"},
      querySelectorAll(selector) {
        return {"[data-time-axis-iso]": labels, "[data-time-axis-grid]": grids, "[data-time-axis-tick]": marks}[selector] || []
      },
    }
    localizeTimeseriesAxis(el, "America/Chicago")
    const visible = labels.filter((label) => label.attributes.visibility === "visible")
    expect(visible.length).toBe(3)
    expect(new Set(visible.map((label) => label.textContent)).size).toBe(3)
    expect(visible[0].textContent).toContain("Jan")
    expect(visible[2].textContent).toContain("Mar")
    expect(Number(visible[0].attributes.x)).toBeLessThan(80)
    expect(Number(visible[2].attributes.x)).toBeGreaterThan(500)
    expect(grids[0].attributes.x1).toBe(visible[0].attributes.x)
    expect(marks[0].attributes.x1).toBe(visible[0].attributes.x)
    expect(labels[4].attributes.visibility).toBe("hidden")

    // LiveView need not resend uniform x attributes when only the range changes.
    el.dataset.timeStart = "2025-04-01T00:00:00Z"
    el.dataset.timeEnd = "2025-04-02T00:00:00Z"
    labels.forEach((label, index) => {
      label.dataset.timeAxisIso = new Date(Date.parse(el.dataset.timeStart) + index * 86_400_000 / 4).toISOString()
    })
    localizeTimeseriesAxis(el, "America/Chicago")
    expect(labels.every((label) => label.attributes.visibility === "visible")).toBe(true)
    expect(labels.map((label) => Number(label.attributes.x))).toEqual([72, 246, 420, 594, 768])
    expect(grids.map((line) => Number(line.attributes.x1))).toEqual([72, 246, 420, 594, 768])
  })
})
