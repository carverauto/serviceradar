import {describe, expect, it} from "vitest"

import {
  absoluteTotalSeries,
  normalizeStacked100Rows,
  stacked100TimePresentation,
} from "./NetflowStacked100Chart"

describe("NetflowStacked100Chart absolute volume", () => {
  it("uses the saved timezone for both the axis and tooltip", () => {
    const presentation = stacked100TimePresentation("America/Chicago")
    const instant = new Date("2026-08-30T18:00:00Z")

    expect(presentation.timeZone).toBe("America/Chicago")
    expect(presentation.axisFormatter(instant)).toContain("01:00 PM")
  })

  it("normalizes composition while preserving each row total", () => {
    const rows = normalizeStacked100Rows(
      [
        {t: "2026-01-01T00:01:00Z", web: 25, db: 75},
        {t: "2026-01-01T00:00:00Z", web: 40, db: 10},
      ],
      ["web", "db"],
    )

    expect(rows.map((row) => row.__sum)).toEqual([50, 100])
    expect(rows.map((row) => row.web)).toEqual([0.8, 0.25])
    expect(rows.map((row) => row.db)).toEqual([0.2, 0.75])
  })

  it("builds an absolute total series alongside the percent stack", () => {
    const rows = normalizeStacked100Rows([{t: "2026-01-01T00:00:00Z", a: 3, b: 7}], ["a", "b"])

    expect(absoluteTotalSeries(rows)).toEqual([{t: rows[0].t, v: 10}])
  })
})
