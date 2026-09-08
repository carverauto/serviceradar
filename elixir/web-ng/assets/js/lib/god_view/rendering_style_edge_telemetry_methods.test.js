import {describe, expect, it} from "vitest"

import {godViewRenderingStyleEdgeTelemetryMethods} from "./rendering_style_edge_telemetry_methods"

describe("rendering_style_edge_telemetry_methods", () => {
  it("formatPps applies expected units", () => {
    expect(godViewRenderingStyleEdgeTelemetryMethods.formatPps(0)).toEqual("0 pps")
    expect(godViewRenderingStyleEdgeTelemetryMethods.formatPps(1250)).toEqual("1.3 Kpps")
    expect(godViewRenderingStyleEdgeTelemetryMethods.formatPps(2_500_000)).toEqual("2.5 Mpps")
  })

  it("formatCapacity applies expected compact units", () => {
    expect(godViewRenderingStyleEdgeTelemetryMethods.formatCapacity(0)).toEqual("UNK")
    expect(godViewRenderingStyleEdgeTelemetryMethods.formatCapacity(100_000_000)).toEqual("100M")
    expect(godViewRenderingStyleEdgeTelemetryMethods.formatCapacity(1_000_000_000)).toEqual("1G")
    expect(godViewRenderingStyleEdgeTelemetryMethods.formatCapacity(100_000_000_000)).toEqual("100G")
  })

  it("edgeWidthPixels increases with utilization/pps signal", () => {
    const m = godViewRenderingStyleEdgeTelemetryMethods
    const low = m.edgeWidthPixels(1_000_000_000, 100, 10_000)
    const high = m.edgeWidthPixels(1_000_000_000, 200_000, 900_000_000)

    expect(high).toBeGreaterThan(low)
  })

  it("edgeTelemetryColor returns rgba tuple with bounded channels", () => {
    const color = godViewRenderingStyleEdgeTelemetryMethods.edgeTelemetryColor(500_000_000, 1_000_000_000, 50_000)

    expect(color).toHaveLength(4)
    for (const channel of color) {
      expect(Number.isInteger(channel)).toEqual(true)
      expect(channel).toBeGreaterThanOrEqual(0)
      expect(channel).toBeLessThanOrEqual(255)
    }
  })

  it("connectionKindFromLabel normalizes first token", () => {
    expect(godViewRenderingStyleEdgeTelemetryMethods.connectionKindFromLabel("")).toEqual("LINK")
    expect(godViewRenderingStyleEdgeTelemetryMethods.connectionKindFromLabel("node link")).toEqual("LINK")
    expect(godViewRenderingStyleEdgeTelemetryMethods.connectionKindFromLabel("mpls tunnel east-west")).toEqual("MPLS")
  })
})
