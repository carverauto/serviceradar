import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphDataMethods} from "./rendering_graph_data_methods"

function baseContext({state = {}, deps = {}, overrides = {}} = {}) {
  const initialState = {
    selectedNodeIndex: null,
    hoveredEdgeKey: "stale-edge",
    selectedEdgeKey: "stale-edge",
    lastVisibleNodeCount: 0,
    lastVisibleEdgeCount: 0,
    ...state,
  }

  const runtime = createStateBackedContext(initialState, deps)
  const api = bindApi(runtime, godViewRenderingGraphDataMethods)
  Object.assign(runtime, api)

  Object.assign(runtime, {
    visibilityMask: vi.fn((states) => new Uint8Array(states.length).fill(1)),
    computeTraversalMask: vi.fn(() => null),
    edgeEnabledByTopologyLayer: vi.fn(() => true),
    selectEdgeLabels: vi.fn((edges) => edges.map((e) => ({midpoint: e.midpoint, connectionLabel: e.connectionLabel}))),
    formatPps: vi.fn(() => "10 pps"),
    formatCapacity: vi.fn(() => "1G"),
    connectionKindFromLabel: vi.fn((l) => (String(l).split(" ")[0] || "LINK").toUpperCase()),
    normalizeDisplayLabel: vi.fn((label, fallback) => (String(label || "").trim() || fallback)),
    nodeMetricText: vi.fn(() => "metric"),
    nodeStatusIcon: vi.fn(() => "●"),
    stateReasonForNode: vi.fn(() => "reason"),
    ...overrides,
  })

  return runtime
}

describe("rendering_graph_data_methods", () => {
  it("buildVisibleGraphData creates visible node/edge data and clears stale edge keys", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      nodes: [
        {id: "n1", x: 1, y: 2, state: 0, label: "Node 1", pps: 10, operUp: 1, details: {}},
        {id: "n2", x: 3, y: 4, state: 1, label: "Node 2", pps: 20, operUp: 2, details: {}},
      ],
      edges: [{source: 0, target: 1, flowPps: 10, flowBps: 100, capacityBps: 1000, label: "mpls link"}],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.nodeData).toHaveLength(2)
    expect(out.edgeData).toHaveLength(1)
    expect(out.edgeLabelData).toHaveLength(1)
    expect(out.edgeData[0].sourceId).toEqual("n1")
    expect(out.edgeData[0].targetId).toEqual("n2")
    expect(out.edgeData[0].connectionLabel).toEqual("MPLS")
    expect(out.edgeData[0].telemetryEligible).toEqual(true)
    expect(ctx.state.hoveredEdgeKey).toEqual(null)
    expect(ctx.state.selectedEdgeKey).toEqual(null)
    expect(ctx.state.lastVisibleNodeCount).toEqual(2)
    expect(ctx.state.lastVisibleEdgeCount).toEqual(1)
  })

  it("buildVisibleGraphData applies local traversal mask and resolves selectedVisibleNode", () => {
    const ctx = baseContext({
      state: {selectedNodeIndex: 1},
      overrides: {computeTraversalMask: vi.fn(() => Uint8Array.from([0, 1]))},
    })

    const effective = {
      shape: "local",
      nodes: [
        {id: "n1", x: 1, y: 2, state: 0, label: "Node 1", pps: 10, operUp: 1, details: {}},
        {id: "n2", x: 3, y: 4, state: 1, label: "Node 2", pps: 20, operUp: 2, details: {}},
      ],
      edges: [{source: 0, target: 1, flowPps: 10, flowBps: 100, capacityBps: 1000, label: "mpls link"}],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.nodeData).toHaveLength(1)
    expect(out.nodeData[0].id).toEqual("n2")
    expect(out.selectedVisibleNode?.id).toEqual("n2")
    expect(out.edgeData).toHaveLength(0)
  })

  it("buildVisibleGraphData handles clustered shape via sourceCluster/targetCluster ids", () => {
    const ctx = baseContext()
    const effective = {
      shape: "global",
      nodes: [
        {id: "c1", x: 10, y: 20, state: 0, label: "Cluster 1", clusterCount: 3, operUp: 1, details: {}},
        {id: "c2", x: 30, y: 40, state: 2, label: "Cluster 2", clusterCount: 2, operUp: 1, details: {}},
      ],
      edges: [{sourceCluster: "c1", targetCluster: "c2", flowPps: 55, flowBps: 1000, capacityBps: 10_000}],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.edgeData).toHaveLength(1)
    expect(out.edgeData[0].sourceId).toEqual("c1")
    expect(out.edgeData[0].targetId).toEqual("c2")
    expect(out.selectedVisibleNode).toEqual(null)
  })

  it("buildVisibleGraphData preserves telemetry eligibility from either key style", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      nodes: [
        {id: "n1", x: 1, y: 2, state: 0, label: "Node 1", pps: 10, operUp: 1, details: {}},
        {id: "n2", x: 3, y: 4, state: 1, label: "Node 2", pps: 20, operUp: 2, details: {}},
      ],
      edges: [
        {source: 0, target: 1, flowPps: 10, flowBps: 100, capacityBps: 1000, telemetry_eligible: false},
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)
    expect(out.edgeData).toHaveLength(1)
    expect(out.edgeData[0].telemetryEligible).toEqual(false)
  })
})
