import {describe, expect, it} from "vitest"

import {godViewRenderingStyleEdgeParticleMethods} from "./rendering_style_edge_particle_methods"

// Packet flow is one instance per edge; these tests read the per-edge inputs the shader
// turns into particles: flow = [particle base, A->B weight, B->A weight, base speed],
// shape = [lane separation, jitter, utilization, seed], style = [alpha scale, size scale].
function flowFor(edges, context = {}) {
  const block = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowEdges.call(
    {edgeWidthPixels: () => 4.0, ...context},
    edges,
  )
  const rows = []
  for (let i = 0; i < block.length; i += 1) {
    rows.push({
      endpoints: Array.from(block.attributes.instanceEndpoints.subarray(i * 4, i * 4 + 4)),
      flow: Array.from(block.attributes.instanceFlow.subarray(i * 4, i * 4 + 4)),
      shape: Array.from(block.attributes.instanceShape.subarray(i * 4, i * 4 + 4)),
      style: Array.from(block.attributes.instanceStyle.subarray(i * 2, i * 2 + 2)),
    })
  }
  return {block, rows}
}

const trafficEdge = {
  sourcePosition: [0, 0, 0],
  targetPosition: [100, 0, 0],
  flowPps: 1000,
  flowBps: 10_000_000,
  flowPpsAb: 700,
  flowPpsBa: 300,
  flowBpsAb: 7_000_000,
  flowBpsBa: 3_000_000,
  capacityBps: 20_000_000,
  telemetryEligible: true,
  topologyClass: "backbone",
}

describe("rendering_style_edge_particle_methods", () => {
  it("emits one packed row per edge with traffic, and nothing per particle", () => {
    const {block, rows} = flowFor([trafficEdge, {...trafficEdge, sourcePosition: [0, 10, 0], targetPosition: [50, 10, 0]}])

    expect(block.length).toBe(2)
    expect(Object.keys(block.attributes).sort()).toEqual(["instanceEndpoints", "instanceFlow", "instanceShape", "instanceStyle"])
    expect(rows[0].endpoints).toEqual([0, 0, 100, 0])
    expect(rows[1].endpoints).toEqual([0, 10, 50, 10])
  })

  it("omits bent routes, ineligible links and links with no traffic", () => {
    const {block} = flowFor([
      {...trafficEdge, path: [[0, 0, 0], [100, 0, 0], [100, 100, 0]]},
      {...trafficEdge, telemetryEligible: false},
      {...trafficEdge, stale: true},
      {...trafficEdge, flowPps: 0, flowBps: 0, flowPpsAb: 0, flowPpsBa: 0, flowBpsAb: 0, flowBpsBa: 0},
    ])

    expect(block.length).toBe(0)
  })

  it("draws a reverse lane only when there is real B->A telemetry, weighted by direction", () => {
    const oneWay = flowFor([{...trafficEdge, flowPpsBa: 0, flowBpsBa: 0}]).rows[0]
    const twoWay = flowFor([trafficEdge]).rows[0]

    expect(oneWay.flow[2]).toBe(0)
    expect(twoWay.flow[1]).toBeCloseTo(0.7, 5)
    expect(twoWay.flow[2]).toBeCloseTo(0.3, 5)
  })

  it("keeps a visible particle floor on low-but-real telemetry links", () => {
    const [row] = flowFor([{
      sourcePosition: [0, 0, 0],
      targetPosition: [100, 0, 0],
      flowPps: 10,
      flowBps: 1000,
      flowPpsAb: 10,
      flowBpsAb: 1000,
      capacityBps: 0,
      weight: 1,
    }]).rows

    // The shader clamps each lane to at least 18 particles; the base itself is well above it.
    expect(row.flow[0]).toBeGreaterThan(18)
    expect(row.flow[3]).toBeGreaterThan(0.02)
  })

  it("softens endpoint attachment links", () => {
    const backbone = flowFor([trafficEdge]).rows[0]
    const endpoint = flowFor([{...trafficEdge, topologyClass: "endpoints"}]).rows[0]

    expect(endpoint.flow[0]).toBeLessThan(backbone.flow[0])
    expect(endpoint.style[0]).toBeLessThan(backbone.style[0])
  })

  it("builds the block once per edge list", () => {
    const edges = [trafficEdge]
    const context = {edgeWidthPixels: () => 4.0}
    const first = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowEdges.call(context, edges)
    const second = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowEdges.call(context, edges)

    expect(second).toBe(first)
  })
})
