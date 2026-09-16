import * as d3 from "d3"
import {describe, expect, it} from "vitest"

import {
  clientXToScaleX,
  netflowAxisTimeFormatter,
  netflowTimeAxis,
  netflowTimeDomain,
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


describe("NetFlow multi-day axis labels", () => {
  const domain = ["2031-04-03T01:00:00Z", "2031-04-10T01:00:00Z"]

  it("distinguishes daily ticks using the saved timezone's calendar date", () => {
    const format = netflowAxisTimeFormatter("America/Chicago", domain, {locale: "en-US"})
    expect(format(domain[0])).toBe("Apr 2")
    expect(format(domain[1])).toBe("Apr 9")
    expect(netflowAxisTimeFormatter("Etc/UTC", domain, {locale: "en-US"})(domain[0])).toBe("Apr 3")
  })

  it("keeps time labels for hourly and 24-hour plots", () => {
    for (const hours of [1, 24]) {
      const start = new Date(domain[0])
      const end = new Date(start.getTime() + hours * 60 * 60 * 1000)
      const format = netflowAxisTimeFormatter("America/Chicago", [start, end], {locale: "en-US"})
      expect(format(start)).toBe("08:00 PM")
    }
  })

  it("identifies years across long windows and preserves unsupported-zone fallback", () => {
    const bounds = ["2030-12-30T12:00:00Z", "2032-01-02T12:00:00Z"]
    const format = netflowAxisTimeFormatter("Etc/UTC", bounds, {locale: "en-US"})
    expect(format(bounds[0])).toBe("Dec 2030")
    expect(format(bounds[1])).toBe("Jan 2032")
    expect(netflowAxisTimeFormatter("Mars/Olympus", bounds)(bounds[0])).toBe(bounds[0])
  })

  it("keeps the existing label when plot bounds are invalid", () => {
    const format = netflowAxisTimeFormatter("Etc/UTC", ["invalid", domain[1]], {locale: "en-US"})
    expect(format(domain[0])).toBe("01:00 AM")
  })
})


describe("requested NetFlow calendar axes", () => {
  it("keeps sparse observations inside the requested multi-year domain", () => {
    const dataset = {timeStart: "2030-01-01T00:00:00Z", timeEnd: "2033-01-01T00:00:00Z"}
    const observed = [new Date("2032-12-30T12:00:00Z"), new Date("2032-12-31T12:00:00Z")]
    const domain = netflowTimeDomain(dataset, observed)
    const axis = netflowTimeAxis("America/Chicago", domain, {locale: "en-US"})
    expect(domain.map(Number)).toEqual([Date.parse(dataset.timeStart), Date.parse(dataset.timeEnd)])
    expect(axis.unit).toBe("year")
    expect(axis.ticks.map(axis.format)).toEqual(["2030", "2031", "2032"])
    expect(observed).toHaveLength(2)
  })

  it("uses distinct day ticks at 30 days and month ticks at 90 days across a year", () => {
    for (const [days, unit] of [[30, "day"], [90, "month"]]) {
      const start = Date.parse("2030-11-15T00:00:00Z")
      const axis = netflowTimeAxis("America/Chicago", [start, start + days * 86400000], {locale: "en-US"})
      const labels = axis.ticks.map(axis.format)
      expect(axis.unit).toBe(unit)
      expect(new Set(labels).size).toBe(labels.length)
      expect(labels.length).toBeGreaterThan(1)
      if (unit === "month") expect(labels).toEqual(["Dec 2030", "Jan 2031", "Feb 2031"])
    }
  })

  it("rejects incomplete and reversed requested bounds", () => {
    const observed = [new Date("2031-01-01T00:00:00Z"), new Date("2031-01-02T00:00:00Z")]
    expect(netflowTimeDomain({timeStart: "invalid"}, observed)).toBe(observed)
    expect(netflowTimeDomain({timeStart: "2031-01-03T00:00:00Z", timeEnd: "2031-01-01T00:00:00Z"}, observed)).toBe(observed)
  })
})
