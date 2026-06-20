import {describe, expect, it} from "vitest"

import {gridPanelAtPointer} from "./NetflowGridChart"

describe("NetflowGridChart hover geometry", () => {
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
