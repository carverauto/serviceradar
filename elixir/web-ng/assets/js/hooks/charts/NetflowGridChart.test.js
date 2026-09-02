import {describe, expect, it} from "vitest"
import * as d3 from "d3"

import {
  gridTooltipTimeLabel,
  gridTooltipTimeHtml,
  gridPanelAt,
  gridPanelAtPointer,
  gridPanelLayout,
  gridYTicks,
  nearestTimeRow,
} from "./NetflowGridChart"

describe("NetflowGridChart hover geometry", () => {
  it("formats tooltip instants in the root's explicit saved timezone", () => {
    const label = gridTooltipTimeLabel(new Date("2026-08-30T18:00:00Z"), {
      timeZone: "America/Chicago",
      locale: "en-US",
    })

    expect(label).toContain("01:00:00 PM")
    expect(label).toContain("GMT-5")
  })

  it("keeps canonical UTC accessible while displaying the saved-zone tooltip label", () => {
    const html = gridTooltipTimeHtml(new Date("2026-08-30T18:00:00Z"), {
      timeZone: "America/Chicago",
      locale: "en-US",
    })

    expect(html).toContain('<time datetime="2026-08-30T18:00:00.000Z"')
    expect(html).toContain('data-canonical-utc="2026-08-30T18:00:00.000Z"')
    expect(html).toContain("canonical UTC 2026-08-30T18:00:00.000Z")
    expect(html).toContain("01:00:00 PM")
    expect(html).toContain("GMT-5")
  })

  it("maps pointer coordinates to the active grid panel", () => {
    const panels = gridPanelLayout(["src", "dst", "app", "asn"], 400, 200, 10)

    expect(gridPanelAt(15, 15, panels)?.key).toBe("src")
    expect(gridPanelAt(215, 15, panels)?.key).toBe("dst")
    expect(gridPanelAt(15, 115, panels)?.key).toBe("app")
    expect(gridPanelAt(215, 115, panels)?.key).toBe("asn")
    expect(gridPanelAt(200, 100, panels)).toBeUndefined()
  })

  it("finds the nearest row for a hovered panel timestamp", () => {
    const data = [
      {t: new Date("2026-01-01T00:00:00Z"), src: 10},
      {t: new Date("2026-01-01T00:05:00Z"), src: 20},
      {t: new Date("2026-01-01T00:10:00Z"), src: 30},
    ]

    expect(nearestTimeRow(data, new Date("2026-01-01T00:04:00Z"))).toBe(data[1])
    expect(nearestTimeRow(data, "not-a-date")).toBeNull()
  })

  it("formats compact y ticks for mini-panel axes", () => {
    const scale = d3.scaleLinear().domain([0, 2400]).nice()

    expect(gridYTicks(scale, "bps", 3)).toEqual([
      {value: 0, label: "0 b/s"},
      {value: 1000, label: "1.00 Kb/s"},
      {value: 2000, label: "2.00 Kb/s"},
    ])
  })
})

describe("NetflowGridChart pointer panel resolution", () => {
  const geometry = {
    viewBoxWidth: 600,
    viewBoxHeight: 220,
    marginLeft: 10,
    marginTop: 10,
    cellWidth: 200,
    cellHeight: 80,
    pad: 10,
    cols: 2,
    rows: 2,
    count: 3,
  }

  it("maps pointer coordinates to the hovered grid panel", () => {
    const rect = {left: 100, top: 50, width: 600, height: 220}

    expect(gridPanelAtPointer(120, 70, rect, geometry)).toMatchObject({
      index: 0,
      row: 0,
      col: 0,
      localX: 10,
      localY: 10,
    })

    expect(gridPanelAtPointer(330, 70, rect, geometry)).toMatchObject({
      index: 1,
      row: 0,
      col: 1,
      localX: 10,
      localY: 10,
    })

    expect(gridPanelAtPointer(120, 160, rect, geometry)).toMatchObject({
      index: 2,
      row: 1,
      col: 0,
      localX: 10,
      localY: 10,
    })
  })

  it("rejects pointer positions in panel gaps or empty cells", () => {
    const rect = {left: 100, top: 50, width: 600, height: 220}

    expect(gridPanelAtPointer(315, 70, rect, geometry)).toBeNull()
    expect(gridPanelAtPointer(330, 160, rect, geometry)).toBeNull()
  })
})
