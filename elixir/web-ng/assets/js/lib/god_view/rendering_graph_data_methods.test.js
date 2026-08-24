import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import ELK from "elkjs/lib/elk.bundled.js"

import {LANDSCAPE_PROFILE, applyTopologySceneToGraph, layoutTopologyScene} from "./layout_elk_scene"
import {expandedFarm01Graph} from "./fixtures/farm01_topology_regression"
import {godViewRenderingGraphDataMethods} from "./rendering_graph_data_methods"
import {prepareTopologySceneInput} from "./topology_scene_graph"

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
    edgeTopologyClass: vi.fn((edge) => {
      const normalized = String(edge?.topologyClass || "").trim().toLowerCase()
      if (normalized === "endpoint") return "endpoints"
      return normalized || "backbone"
    }),
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
  it("uses pre-laid scene routes without post-layout aggregation", async () => {
    const graph = expandedFarm01Graph()
    const input = prepareTopologySceneInput(graph)
    const scene = await layoutTopologyScene(input, {engine: new ELK(), profile: LANDSCAPE_PROFILE})
    const laidOut = applyTopologySceneToGraph(graph, scene)
    const collapseExpandedMemberTrunks = vi.fn()
    const aggregateVisibleEdges = vi.fn()
    const ctx = baseContext({overrides: {collapseExpandedMemberTrunks, aggregateVisibleEdges}})

    const out = ctx.buildVisibleGraphData({shape: "local", ...laidOut})
    const expectedRelationIds = scene.routes.flatMap((route) => route.relationIds).sort()

    expect(out.edgeData).toHaveLength(32)
    expect(out.edgeData.every((edge) => edge.path.length >= 2)).toBe(true)
    expect(out.edgeData.flatMap((edge) => edge.relationIds).sort()).toEqual(expectedRelationIds)
    expect(collapseExpandedMemberTrunks).not.toHaveBeenCalled()
    expect(aggregateVisibleEdges).not.toHaveBeenCalled()

    const bentRoute = scene.routes.find((route) => route.points.length > 2)
    const bentEdge = out.edgeData.find((edge) => edge.interactionKey === `local:${bentRoute.id}`)
    expect(bentEdge.path).toEqual(bentRoute.points.map((point) => [point.x, point.y, 0]))
  })

  it("samples a scene route midpoint by cumulative polyline distance", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      _layoutMode: "elk-scene",
      _topologyScene: {
        routes: [{
          id: "route:a-b",
          sourceId: "a",
          targetId: "b",
          points: [{x: 0, y: 0}, {x: 10, y: 0}, {x: 10, y: 30}],
          relationIds: ["a-b"],
          metadata: {},
        }],
      },
      nodes: [
        {id: "a", x: 0, y: 0, state: 0, label: "A", operUp: 1, details: {}},
        {id: "b", x: 10, y: 30, state: 1, label: "B", operUp: 1, details: {}},
      ],
      edges: [{id: "a-b", source: 0, target: 1, topologyClass: "backbone"}],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.edgeData[0].midpoint).toEqual([10, 10, 0])
  })

  it("keeps route metadata authoritative while enriching empty fields from semantic relations", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      _layoutMode: "elk-scene",
      _topologyScene: {
        routes: [{
          id: "route:a-b",
          sourceId: "a",
          targetId: "b",
          points: [{x: 0, y: 0}, {x: 20, y: 0}],
          relationIds: ["reverse", "forward"],
          metadata: {flowPps: 11, flowPpsAb: 7, label: "pre-aggregated route"},
        }],
      },
      nodes: [
        {id: "a", x: 0, y: 0, state: 0, label: "A", operUp: 1, details: {}},
        {id: "b", x: 20, y: 0, state: 1, label: "B", operUp: 1, details: {}},
      ],
      edges: [
        {id: "forward", source: 0, target: 1, flowPps: 80, flowPpsAb: 60, flowPpsBa: 20, topologyClass: "backbone"},
        {id: "reverse", source: 1, target: 0, flowPps: 50, flowPpsAb: 35, flowPpsBa: 15, topologyClass: "inferred"},
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.edgeData[0]).toMatchObject({
      flowPps: 11,
      flowPpsAb: 7,
      flowPpsBa: 55,
      label: "pre-aggregated route",
    })
  })

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
    expect(out.edgeData[0].topologyClass).toEqual("backbone")
    expect(out.edgeData[0].flowPpsAb).toEqual(0)
    expect(out.edgeData[0].flowPpsBa).toEqual(0)
    expect(out.edgeData[0].flowBpsAb).toEqual(0)
    expect(out.edgeData[0].flowBpsBa).toEqual(0)
    expect(ctx.state.hoveredEdgeKey).toEqual(null)
    expect(ctx.state.selectedEdgeKey).toEqual(null)
    expect(ctx.state.lastVisibleNodeCount).toEqual(2)
    expect(ctx.state.lastVisibleEdgeCount).toEqual(1)
  })

  it("buildVisibleGraphData keeps the full graph visible when a node is selected", () => {
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

    expect(out.nodeData).toHaveLength(2)
    expect(out.nodeData.map((node) => node.id)).toEqual(["n1", "n2"])
    expect(out.selectedVisibleNode?.id).toEqual("n2")
    expect(out.edgeData).toHaveLength(1)
    expect(ctx.computeTraversalMask).not.toHaveBeenCalled()
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
        {
          source: 0,
          target: 1,
          flowPps: 10,
          flowPpsAb: 7,
          flowPpsBa: 3,
          flowBps: 100,
          flowBpsAb: 70,
          flowBpsBa: 30,
          capacityBps: 1000,
          telemetry_eligible: false,
        },
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)
    expect(out.edgeData).toHaveLength(1)
    expect(out.edgeData[0].telemetryEligible).toEqual(false)
    expect(out.edgeData[0].flowPpsAb).toEqual(7)
    expect(out.edgeData[0].flowPpsBa).toEqual(3)
    expect(out.edgeData[0].flowBpsAb).toEqual(70)
    expect(out.edgeData[0].flowBpsBa).toEqual(30)
  })

  it("buildVisibleGraphData collapses duplicate visual edges for identical endpoints", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      nodes: [
        {id: "n1", x: 1, y: 2, state: 0, label: "Node 1", pps: 10, operUp: 1, details: {}},
        {id: "n2", x: 3, y: 4, state: 1, label: "Node 2", pps: 20, operUp: 2, details: {}},
      ],
      edges: [
        {
          id: "edge-canonical-a",
          source: 0,
          target: 1,
          flowPps: 100,
          flowPpsAb: 70,
          flowPpsBa: 30,
          flowBps: 1000,
          flowBpsAb: 700,
          flowBpsBa: 300,
          capacityBps: 10_000,
          telemetryEligible: true,
        },
        {
          id: "edge-canonical-b",
          source: 0,
          target: 1,
          flowPps: 55,
          flowPpsAb: 50,
          flowPpsBa: 5,
          flowBps: 550,
          flowBpsAb: 500,
          flowBpsBa: 50,
          capacityBps: 10_000,
          telemetryEligible: true,
        },
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)
    expect(out.edgeData).toHaveLength(1)
    expect(out.edgeData[0].interactionKey).toEqual("local:pair:n1:n2")
    expect(out.edgeData[0].flowPpsAb).toEqual(120)
    expect(out.edgeData[0].flowPpsBa).toEqual(35)
    expect(out.edgeData[0].flowBpsAb).toEqual(1200)
    expect(out.edgeData[0].flowBpsBa).toEqual(350)
    expect(out.edgeData[0].edgeCount).toEqual(2)
    expect(out.edgeData[0].topologyClassCounts.backbone).toEqual(2)
  })

  it("buildVisibleGraphData collapses reverse-direction duplicates into one canonical pair", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      nodes: [
        {id: "a", x: 1, y: 2, state: 0, label: "A", pps: 10, operUp: 1, details: {}},
        {id: "b", x: 3, y: 4, state: 1, label: "B", pps: 20, operUp: 2, details: {}},
      ],
      edges: [
        {
          id: "forward",
          source: 0,
          target: 1,
          flowPps: 80,
          flowPpsAb: 60,
          flowPpsBa: 20,
          flowBps: 800,
          flowBpsAb: 600,
          flowBpsBa: 200,
          capacityBps: 10_000,
          telemetryEligible: true,
          topologyClass: "backbone",
        },
        {
          id: "reverse",
          source: 1,
          target: 0,
          flowPps: 50,
          flowPpsAb: 35,
          flowPpsBa: 15,
          flowBps: 500,
          flowBpsAb: 350,
          flowBpsBa: 150,
          capacityBps: 10_000,
          telemetryEligible: true,
          topologyClass: "inferred",
        },
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.edgeData).toHaveLength(1)
    expect(out.edgeData[0].sourceId).toEqual("a")
    expect(out.edgeData[0].targetId).toEqual("b")
    expect(out.edgeData[0].flowPpsAb).toEqual(75)
    expect(out.edgeData[0].flowPpsBa).toEqual(55)
    expect(out.edgeData[0].flowBpsAb).toEqual(750)
    expect(out.edgeData[0].flowBpsBa).toEqual(550)
    expect(out.edgeData[0].topologyClassCounts.backbone).toEqual(1)
    expect(out.edgeData[0].topologyClassCounts.inferred).toEqual(1)
    expect(out.edgeData[0].topologyClass).toEqual("")
  })

  it("buildVisibleGraphData hides endpoint-only nodes when the endpoint layer is disabled", () => {
    const ctx = baseContext({
      state: {
        topologyLayers: {backbone: true, inferred: false, endpoints: false},
      },
      overrides: {
        edgeEnabledByTopologyLayer: vi.fn((edge) => String(edge.topologyClass) !== "endpoints"),
      },
    })

    const effective = {
      shape: "local",
      nodes: [
        {id: "router", x: 1, y: 2, state: 0, label: "Router", pps: 10, operUp: 1, details: {}},
        {id: "switch", x: 3, y: 4, state: 1, label: "Switch", pps: 20, operUp: 2, details: {}},
        {id: "client", x: 5, y: 6, state: 1, label: "Client", pps: 5, operUp: 1, details: {}},
      ],
      edges: [
        {source: 0, target: 1, flowPps: 10, flowBps: 100, capacityBps: 1000, label: "router-switch", topologyClass: "backbone"},
        {source: 1, target: 2, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "switch-client", topologyClass: "endpoints"},
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.nodeData.map((node) => node.id)).toEqual(["router", "switch"])
    expect(out.edgeData).toHaveLength(1)
    expect(out.edgeData[0].sourceId).toEqual("router")
    expect(out.edgeData[0].targetId).toEqual("switch")
  })

  it("buildVisibleGraphData keeps attachment census summaries visible while raw endpoints stay hidden", () => {
    const ctx = baseContext({
      state: {
        topologyLayers: {backbone: true, inferred: false, endpoints: false},
      },
      overrides: {
        edgeEnabledByTopologyLayer: vi.fn((edge) => String(edge.topologyClass) !== "endpoints"),
      },
    })

    const effective = {
      shape: "local",
      nodes: [
        {id: "router", x: 1, y: 2, state: 0, label: "Router", pps: 10, operUp: 1, details: {}},
        {id: "switch", x: 3, y: 4, state: 1, label: "Switch", pps: 20, operUp: 2, details: {cluster_kind: "endpoint-anchor"}},
        {id: "census", x: 5, y: 6, state: 1, label: "12 endpoints", pps: 5, operUp: 1, details: {cluster_kind: "endpoint-summary"}},
        {id: "client", x: 7, y: 8, state: 1, label: "Client", pps: 5, operUp: 1, details: {cluster_kind: "endpoint-member"}},
      ],
      edges: [
        {source: 0, target: 1, flowPps: 10, flowBps: 100, capacityBps: 1000, label: "router-switch", topologyClass: "backbone"},
        {source: 1, target: 2, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "endpoint census", topologyClass: "endpoints"},
        {source: 2, target: 3, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "endpoint member", topologyClass: "endpoints"},
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.nodeData.map((node) => node.id)).toEqual(["router", "switch", "census"])
    expect(out.edgeData.map((edge) => [edge.sourceId, edge.targetId])).toEqual([
      ["census", "switch"],
      ["router", "switch"],
    ])
  })

  it("buildVisibleGraphData keeps expanded cluster members visible while the endpoint layer is off", () => {
    const ctx = baseContext({
      state: {
        topologyLayers: {backbone: true, inferred: false, endpoints: false},
      },
      overrides: {
        edgeEnabledByTopologyLayer: vi.fn((edge) => String(edge.topologyClass) !== "endpoints"),
      },
    })

    const effective = {
      shape: "local",
      nodes: [
        {id: "switch", x: 3, y: 4, state: 1, label: "Switch", pps: 20, operUp: 2, details: {cluster_kind: "endpoint-anchor"}},
        {id: "census", x: 5, y: 6, state: 1, label: "12 endpoints", pps: 5, operUp: 1, details: {cluster_kind: "endpoint-summary", cluster_expanded: true, cluster_anchor_id: "switch"}},
        {
          id: "client",
          x: 7,
          y: 8,
          state: 1,
          label: "Client",
          pps: 5,
          operUp: 1,
          details: {cluster_kind: "endpoint-member", cluster_expanded: true},
        },
      ],
      edges: [
        {source: 0, target: 1, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "endpoint census", topologyClass: "endpoints"},
        {source: 1, target: 2, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "endpoint member", topologyClass: "endpoints"},
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.nodeData.map((node) => node.id)).toEqual(["switch", "client"])
    expect(out.edgeData.map((edge) => [edge.sourceId, edge.targetId])).toEqual([["client", "switch"]])
  })

  it("buildVisibleGraphData keeps a single trunk from the anchor to an expanded cluster", () => {
    const ctx = baseContext({
      state: {
        topologyLayers: {backbone: true, inferred: false, endpoints: true},
      },
    })

    const effective = {
      shape: "local",
      nodes: [
        {
          id: "switch",
          x: 0,
          y: 0,
          state: 1,
          label: "Switch",
          pps: 20,
          operUp: 2,
          details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-anchor"},
        },
        {
          id: "census",
          x: 10,
          y: 0,
          state: 1,
          label: "4 endpoints",
          pps: 5,
          operUp: 1,
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-summary",
            cluster_expanded: true,
            cluster_anchor_id: "switch",
          },
        },
        {
          id: "client-near",
          x: 40,
          y: 0,
          state: 1,
          label: "192.168.1.10",
          pps: 5,
          operUp: 1,
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-member",
            cluster_expanded: true,
            cluster_anchor_id: "switch",
          },
        },
        {
          id: "client-far",
          x: 80,
          y: 40,
          state: 1,
          label: "192.168.1.11",
          pps: 5,
          operUp: 1,
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-member",
            cluster_expanded: true,
            cluster_anchor_id: "switch",
          },
        },
        {
          id: "client-farther",
          x: 80,
          y: 80,
          state: 1,
          label: "192.168.1.12",
          pps: 5,
          operUp: 1,
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-member",
            cluster_expanded: true,
            cluster_anchor_id: "switch",
          },
        },
      ],
      edges: [
        {source: 0, target: 1, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "census", topologyClass: "endpoints"},
        {source: 1, target: 2, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "near", topologyClass: "endpoints"},
        {source: 1, target: 3, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "far", topologyClass: "endpoints"},
        {source: 1, target: 4, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "farther", topologyClass: "endpoints"},
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.nodeData.map((node) => node.id).sort()).toEqual([
      "client-far",
      "client-farther",
      "client-near",
      "switch",
    ])
    expect(out.edgeData).toHaveLength(1)
    expect(out.edgeData[0].sourceId === "switch" || out.edgeData[0].targetId === "switch").toEqual(true)
    expect([out.edgeData[0].sourceId, out.edgeData[0].targetId]).toContain("client-near")
  })

  it("buildVisibleGraphData keeps endpoint nodes visible when the endpoint layer is enabled", () => {
    const ctx = baseContext({
      state: {
        topologyLayers: {backbone: true, inferred: false, endpoints: true},
      },
    })

    const effective = {
      shape: "local",
      nodes: [
        {id: "router", x: 1, y: 2, state: 0, label: "Router", pps: 10, operUp: 1, details: {}},
        {id: "switch", x: 3, y: 4, state: 1, label: "Switch", pps: 20, operUp: 2, details: {}},
        {id: "client", x: 5, y: 6, state: 1, label: "Client", pps: 5, operUp: 1, details: {}},
      ],
      edges: [
        {source: 0, target: 1, flowPps: 10, flowBps: 100, capacityBps: 1000, label: "router-switch", topologyClass: "backbone"},
        {source: 1, target: 2, flowPps: 5, flowBps: 50, capacityBps: 1000, label: "switch-client", topologyClass: "endpoint"},
      ],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.nodeData.map((node) => node.id)).toEqual(["router", "switch", "client"])
    expect(out.edgeData).toHaveLength(2)
    const endpointEdge = out.edgeData.find((edge) => edge.sourceId === "client" || edge.targetId === "client")
    expect(endpointEdge?.topologyClass).toEqual("endpoints")
  })
})
