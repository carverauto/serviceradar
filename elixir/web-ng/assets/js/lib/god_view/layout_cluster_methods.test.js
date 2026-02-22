import {describe, expect, it, vi} from "vitest"

import {godViewLayoutClusterMethods} from "./layout_cluster_methods"

function makeContext(overrides = {}) {
  return {
    ...godViewLayoutClusterMethods,
    zoomMode: "auto",
    zoomTier: "local",
    selectedNodeIndex: null,
    lastGraph: null,
    renderGraph: vi.fn(),
    stateDisplayName: (state) => ({0: "Root Cause", 1: "Affected", 2: "Healthy", 3: "Unknown"}[state] || "Unknown"),
    edgeTopologyClass: (edge) => edge.topologyClass || "backbone",
    ...overrides,
  }
}

describe("layout_cluster_methods", () => {
  it("resolveZoomTier and setZoomTier update tier and selection behavior", () => {
    const ctx = makeContext({lastGraph: {nodes: []}, selectedNodeIndex: 5})

    expect(ctx.resolveZoomTier(-1)).toEqual("global")
    expect(ctx.resolveZoomTier(0.5)).toEqual("regional")
    expect(ctx.resolveZoomTier(2)).toEqual("local")

    ctx.setZoomTier("regional", false)

    expect(ctx.zoomTier).toEqual("regional")
    expect(ctx.selectedNodeIndex).toEqual(null)
    expect(ctx.renderGraph).toHaveBeenCalledTimes(1)
  })

  it("reclusterByState aggregates nodes and cross-cluster edges", () => {
    const ctx = makeContext()
    const graph = {
      nodes: [
        {x: 10, y: 20, state: 0, pps: 5, operUp: 1, label: "A", details: {ip: "10.0.0.1", type: "router"}},
        {x: 30, y: 40, state: 0, pps: 15, operUp: 2, label: "B", details: {ip: "10.0.0.2", type: "router"}},
        {x: 50, y: 60, state: 2, pps: 8, operUp: 1, label: "C", details: {ip: "10.0.0.3", type: "switch"}},
      ],
      edges: [
        {source: 0, target: 2, flowPps: 10, flowBps: 100, capacityBps: 1000, topologyClass: "backbone"},
        {source: 1, target: 2, flowPps: 20, flowBps: 200, capacityBps: 2000, topologyClass: "inferred"},
      ],
    }

    const out = ctx.reclusterByState(graph)

    expect(out.shape).toEqual("global")
    expect(out.nodes).toHaveLength(2)
    const state0 = out.nodes.find((n) => n.id === "state:0")
    const state2 = out.nodes.find((n) => n.id === "state:2")
    expect(state0.clusterCount).toEqual(2)
    expect(state0.pps).toEqual(20)
    expect(state0.label).toEqual("Root Cause Cluster")
    expect(state2.clusterCount).toEqual(1)

    expect(out.edges).toHaveLength(1)
    expect(out.edges[0].weight).toEqual(2)
    expect(out.edges[0].flowPps).toEqual(30)
    expect(out.edges[0].flowBps).toEqual(300)
    expect(out.edges[0].capacityBps).toEqual(3000)
    expect(out.edges[0].topologyClassCounts.backbone).toEqual(1)
    expect(out.edges[0].topologyClassCounts.inferred).toEqual(1)
  })

  it("reclusterByGrid groups by cell and derives dominant state", () => {
    const ctx = makeContext()
    const graph = {
      nodes: [
        {x: 10, y: 10, state: 1, pps: 2, operUp: 1, label: "A", details: {ip: "1.1.1.1"}},
        {x: 40, y: 40, state: 1, pps: 3, operUp: 1, label: "B", details: {ip: "1.1.1.2"}},
        {x: 240, y: 20, state: 2, pps: 7, operUp: 2, label: "C", details: {ip: "1.1.1.3"}},
      ],
      edges: [
        {source: 0, target: 2, flowPps: 5, flowBps: 50, capacityBps: 500, topologyClass: "endpoints"},
      ],
    }

    const out = ctx.reclusterByGrid(graph)

    expect(out.shape).toEqual("regional")
    expect(out.nodes).toHaveLength(2)
    const cell00 = out.nodes.find((n) => n.id === "grid:0:0")
    expect(cell00.clusterCount).toEqual(2)
    expect(cell00.state).toEqual(1)
    expect(cell00.label).toEqual("Regional Cluster 0,0")
    expect(out.edges).toHaveLength(1)
    expect(out.edges[0].topologyClassCounts.endpoints).toEqual(1)
  })

  it("reshapeGraph routes to tier-specific transformations", () => {
    const graph = {nodes: [], edges: []}

    const localCtx = makeContext({zoomMode: "local", zoomTier: "global"})
    expect(localCtx.reshapeGraph(graph).shape).toEqual("local")

    const globalCtx = makeContext({zoomMode: "global"})
    globalCtx.reclusterByState = vi.fn(() => ({shape: "global"}))
    expect(globalCtx.reshapeGraph(graph).shape).toEqual("global")
    expect(globalCtx.reclusterByState).toHaveBeenCalledWith(graph)

    const regionalCtx = makeContext({zoomMode: "auto", zoomTier: "regional"})
    regionalCtx.reclusterByGrid = vi.fn(() => ({shape: "regional"}))
    expect(regionalCtx.reshapeGraph(graph).shape).toEqual("regional")
    expect(regionalCtx.reclusterByGrid).toHaveBeenCalledWith(graph)
  })
})
