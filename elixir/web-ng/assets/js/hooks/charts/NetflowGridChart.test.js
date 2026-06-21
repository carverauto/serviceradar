import {describe, expect, it} from "vitest"

import {gridPanelAt, gridPanelLayout, nearestTimeRow} from "./NetflowGridChart"

describe("NetflowGridChart hover geometry", () => {
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
})
