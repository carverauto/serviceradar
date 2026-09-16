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


it("uses different calendar dates for multi-day lineSeriesTimePresentation ticks", () => {
  const domain = [new Date("2031-04-03T01:00:00Z"), new Date("2031-04-10T01:00:00Z")]
  const presentation = lineSeriesTimePresentation("America/Chicago", domain)
  expect(presentation.axisFormatter(domain[0])).toContain("Apr")
  expect(presentation.axisFormatter(domain[0])).not.toBe(presentation.axisFormatter(domain[1]))
})
