import {describe, expect, it} from "vitest"

import {lineSeriesTimePresentation} from "./NetflowLineSeriesChart"

describe("NetflowLineSeriesChart user timezone presentation", () => {
  it("uses the saved timezone for both the axis and tooltip", () => {
    const presentation = lineSeriesTimePresentation("America/Chicago")
    const instant = new Date("2026-08-30T18:00:00Z")

    expect(presentation.timeZone).toBe("America/Chicago")
    expect(presentation.axisFormatter(instant)).toContain("01:00 PM")
  })
})
