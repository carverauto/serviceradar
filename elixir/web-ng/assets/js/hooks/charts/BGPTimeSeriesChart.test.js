import {describe, expect, it} from "vitest"

import * as BGPChart from "./BGPTimeSeriesChart"

const {
  bgpSeriesValue,
  bgpTooltipRows,
  finiteSeriesValues,
  nearestBGPDatum,
  valuesForSeries,
} = BGPChart

describe("BGPTimeSeriesChart gap handling", () => {
  const data = [
    {time: "2026-01-01T00:00:00Z", values: {"64512": 100, "64513": 0}},
    {time: "2026-01-01T00:01:00Z", values: {"64512": null}},
    {time: "2026-01-01T00:02:00Z", values: {"64512": 300, "64513": undefined}},
  ]

  it("preserves nulls instead of converting missing samples to zero", () => {
    expect(valuesForSeries(data, "64512")).toEqual([100, null, 300])
    expect(valuesForSeries(data, "64513")).toEqual([0, null, null])
  })

  it("ignores nulls when deriving y-axis domain values", () => {
    expect(finiteSeriesValues(data, ["64512", "64513"])).toEqual([100, 0, 300])
  })

  it("selects nearest rows and finite values for hover tooltips", () => {
    expect(nearestBGPDatum(data, "2026-01-01T00:01:40Z")).toBe(data[2])
    expect(nearestBGPDatum(data, "not-a-date")).toBeNull()

    expect(bgpTooltipRows(data[2], ["64512", "64513"])).toEqual([{asNumber: "64512", value: 300}])
  })

  it("preserves missing AS values as null", () => {
    expect(bgpSeriesValue({values: {"64512": 4}}, "64512")).toBe(4)
    expect(bgpSeriesValue({values: {"64512": null}}, "64512")).toBeNull()
    expect(bgpSeriesValue({values: {}}, "64512")).toBeNull()
  })
})

describe("BGPTimeSeriesChart timezone presentation", () => {
  const canonical = "2026-01-15T18:30:00Z"

  it("formats axis labels in the explicit saved timezone without a browser-zone fallback", () => {
    expect(BGPChart.bgpAxisTimeFormatter).toEqual(expect.any(Function))

    const originalHostTimeZone = process.env.TZ
    process.env.TZ = "Asia/Tokyo"

    try {
      const chicago = BGPChart.bgpAxisTimeFormatter("America/Chicago")(new Date(canonical))
      const tokyo = BGPChart.bgpAxisTimeFormatter("Asia/Tokyo")(new Date(canonical))
      const utc = BGPChart.bgpAxisTimeFormatter("Etc/UTC")(new Date(canonical))
      const missingMetadata = BGPChart.bgpAxisTimeFormatter()(new Date(canonical))

      expect(chicago).not.toBe(utc)
      expect(missingMetadata).toBe(utc)
      expect(missingMetadata).not.toBe(tokyo)
    } finally {
      process.env.TZ = originalHostTimeZone
    }
  })

  it("keeps canonical UTC context on the localized tooltip label", () => {
    expect(BGPChart.bgpTooltipTimeHtml).toEqual(expect.any(Function))

    const html = BGPChart.bgpTooltipTimeHtml(canonical, "America/Chicago")

    expect(html).toContain('<time datetime="2026-01-15T18:30:00Z"')
    expect(html).toContain('data-canonical-utc="2026-01-15T18:30:00Z"')
    expect(html).toContain("canonical UTC 2026-01-15T18:30:00Z")
    expect(html).not.toContain(">2026-01-15T18:30:00Z</time>")
    expect(BGPChart.bgpTooltipTimeHtml(canonical)).toBe(
      BGPChart.bgpTooltipTimeHtml(canonical, "Etc/UTC"),
    )
  })

  it("retains canonical payload strings and Date scale inputs", () => {
    expect(BGPChart.bgpChartRows).toEqual(expect.any(Function))
    expect(BGPChart.bgpTimeScale).toEqual(expect.any(Function))

    const payload = [
      {time: "2026-01-15T18:30:00Z", values: {"64512": 10}},
      {time: "2026-01-15T18:35:00Z", values: {"64512": 20}},
    ]
    const rows = BGPChart.bgpChartRows(payload)
    const scale = BGPChart.bgpTimeScale(rows, 640)

    expect(rows.map((row) => row.time)).toEqual(payload.map((row) => row.time))
    expect(rows.map((row) => row.t)).toEqual([
      new Date("2026-01-15T18:30:00Z"),
      new Date("2026-01-15T18:35:00Z"),
    ])
    expect(scale.domain()).toEqual(rows.map((row) => row.t))
    expect(scale.range()).toEqual([0, 640])
    expect(payload).toEqual([
      {time: "2026-01-15T18:30:00Z", values: {"64512": 10}},
      {time: "2026-01-15T18:35:00Z", values: {"64512": 20}},
    ])
  })
})
