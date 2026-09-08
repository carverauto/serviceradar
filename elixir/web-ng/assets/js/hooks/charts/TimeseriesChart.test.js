import {describe, expect, it} from "vitest"

import TimeseriesChart from "./TimeseriesChart"
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
