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
  const svg = {
    parentElement: container,
    getBoundingClientRect: () => ({ left: 0, width: 100 }),
  }

  return {
    dataset,
    hoverLine,
    querySelector(selector) {
      if (selector === "svg") return svg
      if (selector === "[data-tooltip]") return tooltip
      if (selector === "[data-hover-line]") return hoverLine
      return null
    },
    svgContainer: container,
    tooltip,
  }
}

describe("TimeseriesChart hook", () => {
  it("binds hover after LiveView updates an initially empty chart", () => {
    const el = chartElement({ points: "[]", unit: "percent" })
    const ctx = { el, ...TimeseriesChart }

    ctx.mounted()
    expect(el.svgContainer.listeners.mousemove).toBeUndefined()

    el.dataset.points = JSON.stringify([{ dt: "Jun 22 12:00", v: 42.4 }])
    ctx.updated()

    expect(el.svgContainer.listeners.mousemove).toEqual(expect.any(Function))

    el.svgContainer.listeners.mousemove({ clientX: 10 })

    expect(el.tooltip.classList.contains("hidden")).toBe(false)
    expect(el.tooltip.textContent).toBe("42.4% @ Jun 22 12:00")
    expect(el.hoverLine.classList.contains("hidden")).toBe(false)

    ctx.destroyed()
    expect(el.svgContainer.listeners.mousemove).toBeUndefined()
  })
})

describe("TimeseriesCombinedChart hook", () => {
  it("binds hover after LiveView updates an initially empty combined chart", () => {
    const el = chartElement({ series: "[]" })
    const ctx = { el, ...TimeseriesCombinedChart }

    ctx.mounted()
    expect(el.svgContainer.listeners.mousemove).toBeUndefined()

    el.dataset.series = JSON.stringify([
      {
        color: "#0EA5E9",
        label: "core 0",
        points: [{ dt: "Jun 22 12:00", v: 77.1 }],
        unit: "percent",
      },
    ])
    ctx.updated()

    expect(el.svgContainer.listeners.mousemove).toEqual(expect.any(Function))

    el.svgContainer.listeners.mousemove({ clientX: 10 })

    expect(el.tooltip.classList.contains("hidden")).toBe(false)
    expect(el.tooltip.innerHTML).toContain("core 0")
    expect(el.tooltip.innerHTML).toContain("77.1%")
    expect(el.hoverLine.classList.contains("hidden")).toBe(false)

    ctx.destroyed()
    expect(el.svgContainer.listeners.mousemove).toBeUndefined()
  })
})
