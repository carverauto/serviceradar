import * as d3 from "d3"
import {describe, expect, it} from "vitest"

import {
  clientXToScaleX,
  netflowAxisTimeFormatter,
  netflowRangeSelectionStatus,
  netflowTooltipTimeHtml,
  netflowTooltipTimeLabel,
  yTickValues,
} from "./util"

describe("netflow tooltip geometry", () => {
  const rect = {left: 100, width: 500}
  const xScale = {range: () => [0, 356]}

  it("subtracts translated plot offsets before x-scale inversion", () => {
    expect(clientXToScaleX(154, rect, xScale, {xOffset: 44})).toBe(10)
    expect(clientXToScaleX(322, rect, xScale, {xOffset: 44})).toBe(178)
  })

  it("clamps to the actual x-scale range", () => {
    expect(clientXToScaleX(120, rect, xScale, {xOffset: 44})).toBe(0)
    expect(clientXToScaleX(600, rect, xScale, {xOffset: 44})).toBe(356)
  })
})

describe("chart axis helpers", () => {
  it("derives finite y-axis tick values from a linear scale", () => {
    const scale = d3.scaleLinear().domain([0, 987]).nice()

    expect(yTickValues(scale, 4)).toEqual([0, 200, 400, 600, 800, 1000])
  })

  it("rejects missing or non-finite tick values", () => {
    expect(yTickValues(null, 4)).toEqual([])
    expect(yTickValues({ticks: () => [0, Number.NaN, Number.POSITIVE_INFINITY, 3]}, 4)).toEqual([0, 3])
  })
})

describe("explicit-zone NetFlow time presentation", () => {
  const start = "2026-08-27T10:00:00Z"
  const end = "2026-08-27T10:04:59.999999Z"

  it("changes axis and tooltip labels across explicit zones without mutating the instant", () => {
    const input = new Date(start)
    const chicagoAxis = netflowAxisTimeFormatter("America/Chicago")(input)
    const utcAxis = netflowAxisTimeFormatter("Etc/UTC")(input)
    const chicagoTooltip = netflowTooltipTimeLabel(start, "America/Chicago")
    const utcTooltip = netflowTooltipTimeLabel(start, "Etc/UTC")

    expect(chicagoAxis).not.toBe(utcAxis)
    expect(chicagoTooltip).not.toBe(utcTooltip)
    expect(chicagoTooltip).toContain("GMT-5")
    expect(utcTooltip).toContain("GMT+0")
    expect(input.toISOString()).toBe("2026-08-27T10:00:00.000Z")
  })

  it("keeps canonical UTC metadata on localized shared chart tooltips", () => {
    const html = netflowTooltipTimeHtml(new Date(start), "America/Chicago")

    expect(html).toContain('<time datetime="2026-08-27T10:00:00.000Z"')
    expect(html).toContain('data-canonical-utc="2026-08-27T10:00:00.000Z"')
    expect(html).toContain("canonical UTC 2026-08-27T10:00:00.000Z")
    expect(html).toContain("GMT-5")
  })

  it("uses Etc/UTC only for missing metadata and restores canonical text for unsupported zones", () => {
    expect(netflowAxisTimeFormatter("")(start)).toBe(netflowAxisTimeFormatter("Etc/UTC")(start))
    expect(netflowTooltipTimeLabel(start, "Mars/Olympus")).toBe(start)
    expect(netflowRangeSelectionStatus({start, end}, "Mars/Olympus")).toBe(
      `Selected ${start} to ${end}; display zone Mars/Olympus; canonical UTC ${start} to ${end}`,
    )
  })

  it("localizes accessible range status while retaining both canonical source strings", () => {
    const chicago = netflowRangeSelectionStatus({start, end}, "America/Chicago")
    const utc = netflowRangeSelectionStatus({start, end}, "Etc/UTC")

    expect(chicago).not.toBe(utc)
    expect(chicago).toContain("GMT-5")
    expect(chicago).toContain("display zone America/Chicago")
    expect(chicago).toContain(`canonical UTC ${start} to ${end}`)
    expect(utc).toContain("GMT+0")
    expect(start).toBe("2026-08-27T10:00:00Z")
    expect(end).toBe("2026-08-27T10:04:59.999999Z")
  })
})
