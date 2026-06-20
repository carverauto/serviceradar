import {describe, expect, it} from "vitest"

import {hoverPosition} from "./chart_hover_geometry"

describe("chart hover geometry", () => {
  it("maps server-rendered timeseries hover through the padded SVG plot area", () => {
    const rect = {left: 100, width: 400}
    const opts = {viewBoxWidth: 800, plotLeft: 8, plotWidth: 784}

    expect(hoverPosition(104, rect, opts)).toMatchObject({pct: 0, lineX: 4, plotX: 0})
    expect(hoverPosition(300, rect, opts)).toMatchObject({pct: 0.5, lineX: 200, plotX: 196})
    expect(hoverPosition(496, rect, opts)).toMatchObject({pct: 1, lineX: 396, plotX: 392})
  })

  it("subtracts D3 chart margins before inverting hover x to time", () => {
    const rect = {left: 20, width: 600}
    const opts = {viewBoxWidth: 600, plotLeft: 44, plotWidth: 446}

    expect(hoverPosition(64, rect, opts)).toMatchObject({pct: 0, lineX: 44, plotX: 0})
    expect(hoverPosition(287, rect, opts)).toMatchObject({pct: 0.5, lineX: 267, plotX: 223})
    expect(hoverPosition(510, rect, opts)).toMatchObject({pct: 1, lineX: 490, plotX: 446})
  })
})
