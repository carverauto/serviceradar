import {describe, expect, it, vi} from "vitest"

import {godViewLayoutClusterMethods} from "./layout_cluster_methods"

function makeContext({state = {}, deps = {}, methods = {}} = {}) {
  const ctx = {
    state: {
      zoomMode: "auto",
      zoomTier: "local",
      selectedNodeIndex: null,
      lastGraph: null,
      ...state,
    },
    deps: {
      renderGraph: vi.fn(),
      stateDisplayName: (value) => ({0: "Root Cause", 1: "Affected", 2: "Healthy", 3: "Unknown"}[value] || "Unknown"),
      edgeTopologyClass: (edge) => edge.topologyClass || "backbone",
      ...deps,
    },
    ...godViewLayoutClusterMethods,
    ...methods,
  }
  return ctx
}

describe("layout_cluster_methods", () => {
  it("resolveZoomTier and setZoomTier update tier and selection behavior", () => {
    const ctx = makeContext({state: {lastGraph: {nodes: []}, selectedNodeIndex: 5}})

    expect(ctx.resolveZoomTier(-1)).toEqual("global")
    expect(ctx.resolveZoomTier(0.5)).toEqual("regional")
    expect(ctx.resolveZoomTier(2)).toEqual("local")

    ctx.setZoomTier("regional", false)

    expect(ctx.state.zoomTier).toEqual("regional")
    expect(ctx.state.selectedNodeIndex).toEqual(null)
    expect(ctx.deps.renderGraph).toHaveBeenCalledTimes(1)
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

  it("clusterEdges preserves directional telemetry with canonical cluster orientation", () => {
    const ctx = makeContext()
    const clusterByNode = {0: "a", 1: "b", 2: "a"}
    const edges = [
      {
        source: 0,
        target: 1,
        flowPps: 100,
        flowPpsAb: 80,
        flowPpsBa: 20,
        flowBps: 1000,
        flowBpsAb: 800,
        flowBpsBa: 200,
        capacityBps: 10_000,
      },
      {
        source: 1,
        target: 2,
        flowPps: 60,
        flowPpsAb: 45,
        flowPpsBa: 15,
        flowBps: 600,
        flowBpsAb: 450,
        flowBpsBa: 150,
        capacityBps: 5_000,
      },
    ]

    const out = ctx.clusterEdges(edges, clusterByNode)
    expect(out).toHaveLength(1)
    expect(out[0].sourceCluster).toEqual("a")
    expect(out[0].targetCluster).toEqual("b")
    expect(out[0].flowPps).toEqual(160)
    expect(out[0].flowBps).toEqual(1600)
    // First edge (a->b): AB=80 BA=20; second edge is (b->a): AB/BA swapped into canonical a->b.
    expect(out[0].flowPpsAb).toEqual(95)
    expect(out[0].flowPpsBa).toEqual(65)
    expect(out[0].flowBpsAb).toEqual(950)
    expect(out[0].flowBpsBa).toEqual(650)
  })

  it("reshapeGraph routes to tier-specific transformations", () => {
    const graph = {nodes: [], edges: []}

    const localCtx = makeContext({state: {zoomMode: "local", zoomTier: "global"}})
    expect(localCtx.reshapeGraph(graph).shape).toEqual("local")

    const globalCtx = makeContext({state: {zoomMode: "global"}})
    globalCtx.reclusterByState = vi.fn(() => ({shape: "global"}))
    expect(globalCtx.reshapeGraph(graph).shape).toEqual("global")
    expect(globalCtx.reclusterByState).toHaveBeenCalledWith(graph)

    const regionalCtx = makeContext({state: {zoomMode: "auto", zoomTier: "regional"}})
    regionalCtx.reclusterByGrid = vi.fn(() => ({shape: "regional"}))
    expect(regionalCtx.reshapeGraph(graph).shape).toEqual("regional")
    expect(regionalCtx.reclusterByGrid).toHaveBeenCalledWith(graph)
  })
})
