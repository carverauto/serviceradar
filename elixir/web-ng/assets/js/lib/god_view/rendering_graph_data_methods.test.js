import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import ELK from "elkjs/lib/elk.bundled.js"

import {applyTopologyOverviewToGraph, layoutTopologyOverview} from "./layout_elk_radial_overview"
import {LANDSCAPE_PROFILE, applyTopologySceneToGraph, layoutTopologyScene} from "./layout_elk_scene"
import {collapsedFarm01Graph, expandedFarm01Graph} from "./fixtures/farm01_topology_regression"
import {godViewLayoutClusterMethods} from "./layout_cluster_methods"
import {godViewRenderingGraphDataMethods, hasManagedTopologySceneRoutes} from "./rendering_graph_data_methods"
import {godViewRenderingStyleEdgeTopologyMethods} from "./rendering_style_edge_topology_methods"
import {prepareTopologyOverviewInput} from "./topology_overview_projection"
import {prepareTopologySceneInput} from "./topology_scene_graph"

function topologyScene(overrides = {}) {
  return {
    nodes: [],
    routes: [],
    bounds: {minX: 0, minY: 0, maxX: 0, maxY: 0},
    ...overrides,
  }
}

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

function managedRouteGraph({nodes, edges, route}) {
  return {
    shape: "local",
    _layoutMode: "elk-scene-detail",
    _topologyScene: {
      key: "managed-filter-scene",
      nodes: [],
      bounds: {minX: 0, minY: 0, maxX: 100, maxY: 0},
      routes: [{
        id: route.id,
        sourceId: route.sourceId,
        targetId: route.targetId,
        points: route.points || [{x: 0, y: 0}, {x: 100, y: 0}],
        relationIds: route.relationIds,
        metadata: route.metadata || {},
      }],
    },
    nodes,
    edges,
  }
}

function topologyAwareContext(topologyLayers) {
  return baseContext({
    state: {
      topologyLayers,
      layoutEngine: {layout: vi.fn()},
    },
    overrides: {
      edgeTopologyClass: godViewRenderingStyleEdgeTopologyMethods.edgeTopologyClass,
      edgeEnabledByTopologyLayer: godViewRenderingStyleEdgeTopologyMethods.edgeEnabledByTopologyLayer,
    },
  })
}

describe("rendering_graph_data_methods", () => {
  it("excludes finite raw overview nodes that are absent from the managed scene", () => {
    const ctx = baseContext()
    const graph = {
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologyScene: topologyScene({
        nodes: [{id: "placed", center: {x: 20, y: 30}, width: 40, height: 40}],
      }),
      nodes: [
        {id: "placed", x: 20, y: 30, state: 1, label: "Placed", operUp: 1, details: {}},
        {id: "raw-only", x: 80, y: 90, state: 1, label: "Raw only", operUp: 1, details: {}},
      ],
      edges: [],
    }

    const out = ctx.buildVisibleGraphData(graph)

    expect(out.nodeData.map((node) => node.id)).toEqual(["placed"])
    expect(out.nodeData.every((node) => node.position.every(Number.isFinite))).toBe(true)
    expect(ctx.state.lastVisibleNodeCount).toBe(1)
  })

  it("excludes managed overview scene members with non-finite graph coordinates", () => {
    const ctx = baseContext()
    const graph = {
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologyScene: topologyScene({
        nodes: [
          {id: "placed", center: {x: 20, y: 30}, width: 40, height: 40},
          {id: "unplaced", center: {x: 80, y: 90}, width: 40, height: 40},
        ],
      }),
      nodes: [
        {id: "placed", x: 20, y: 30, state: 1, label: "Placed", operUp: 1, details: {}},
        {id: "unplaced", x: null, y: 90, state: 1, label: "Unplaced", operUp: 1, details: {}},
      ],
      edges: [],
    }

    const out = ctx.buildVisibleGraphData(graph)

    expect(out.nodeData.map((node) => node.id)).toEqual(["placed"])
    expect(out.nodeData.every((node) => node.position.every(Number.isFinite))).toBe(true)
    expect(ctx.state.lastVisibleNodeCount).toBe(1)
  })

  it("excludes finite overview scene nodes explicitly marked render false", () => {
    const ctx = baseContext()
    const graph = {
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologyScene: topologyScene({
        nodes: [
          {id: "placed", center: {x: 20, y: 30}, width: 40, height: 40},
          {id: "hidden", center: {x: 80, y: 90}, width: 40, height: 40, render: false},
        ],
      }),
      nodes: [
        {id: "placed", x: 20, y: 30, state: 1, label: "Placed", operUp: 1, details: {}},
        {id: "hidden", x: 80, y: 90, state: 1, label: "Hidden", operUp: 1, details: {}},
      ],
      edges: [],
    }

    const out = ctx.buildVisibleGraphData(graph)

    expect(out.nodeData.map((node) => node.id)).toEqual(["placed"])
    expect(ctx.state.lastVisibleNodeCount).toBe(1)
  })

  it("renders an adapter-applied radial overview from semantic scene geometry only", async () => {
    const ctx = baseContext()
    const rawGraph = {
      shape: "local",
      nodes: [
        {
          id: "access",
          x: -800,
          y: -900,
          state: 2,
          label: "Access",
          operUp: 1,
          details: {type: "Switch", topology_plane: "backbone"},
        },
        {
          id: "core",
          x: -700,
          y: -600,
          state: 2,
          label: "Core",
          operUp: 1,
          details: {type: "Router", topology_plane: "backbone"},
        },
        {
          id: "stale-raw-endpoint",
          x: 777,
          y: 888,
          state: 3,
          label: "Stale raw endpoint",
          operUp: 0,
          details: {
            type: "unknown",
            identity_source: "endpoint_attachment_projection",
            topology_plane: "attachment",
          },
        },
      ],
      edges: [
        {
          id: "link:core-access",
          source: 1,
          target: 0,
          topologyClass: "backbone",
          evidenceClass: "direct",
          metadata: {relation_type: "CONNECTS_TO", topology_plane: "backbone"},
        },
        {
          id: "link:access-stale",
          source: 0,
          target: 2,
          topologyClass: "endpoints",
          evidenceClass: "endpoint-attachment",
          metadata: {relation_type: "ATTACHED_TO", topology_plane: "attachment"},
        },
      ],
    }
    const overviewInput = prepareTopologyOverviewInput(rawGraph)
    const scene = await layoutTopologyOverview(overviewInput, new ELK())
    const laidOut = applyTopologyOverviewToGraph(rawGraph, scene)

    const out = ctx.buildVisibleGraphData(laidOut)

    const renderableSceneNodes = scene.nodes.filter((node) => node.render !== false)
    const sceneNodeById = new Map(renderableSceneNodes.map((node) => [node.id, node]))
    const glyphIds = out.nodeData.map((node) => node.id)
    expect(glyphIds).toEqual(renderableSceneNodes.map((node) => node.id))
    expect(glyphIds).not.toContain("stale-raw-endpoint")
    expect(laidOut.nodes.find((node) => node.id === "stale-raw-endpoint")).toMatchObject({x: 777, y: 888})
    for (const glyph of out.nodeData) {
      const center = sceneNodeById.get(glyph.id).center
      expect(glyph.position).toEqual([center.x, center.y, 0])
    }

    const sceneRouteById = new Map(scene.routes.map((route) => [route.id, route]))
    expect(out.edgeData).toHaveLength(scene.routes.length)
    for (const edge of out.edgeData) {
      const route = sceneRouteById.get(edge.routeId)
      expect([edge.sourceId, edge.targetId]).toEqual([route.sourceId, route.targetId])
      expect(glyphIds).toContain(edge.sourceId)
      expect(glyphIds).toContain(edge.targetId)
      expect(edge.sourcePosition).toEqual([route.points[0].x, route.points[0].y, 0])
      expect(edge.targetPosition).toEqual([
        route.points.at(-1).x,
        route.points.at(-1).y,
        0,
      ])
    }
  })

  it("keeps endpoint census, selected details, and trunk parity across managed densities", () => {
    const topologyLayers = {backbone: true, inferred: false, endpoints: false}
    const ctx = topologyAwareContext(topologyLayers)
    Object.assign(ctx, bindApi(ctx, godViewLayoutClusterMethods))
    ctx.state.zoomMode = "local"
    ctx.state.zoomTier = "local"
    ctx.state.selectedNodeIndex = 1
    const graph = managedRouteGraph({
      nodes: [
        {
          id: "switch",
          x: 0,
          y: 0,
          state: 0,
          label: "Switch",
          operUp: 1,
          details: {cluster_id: "cluster-a", cluster_kind: "endpoint-anchor"},
        },
        {
          id: "census",
          x: 100,
          y: 0,
          state: 1,
          label: "24 endpoints",
          operUp: 1,
          details: {
            cluster_id: "cluster-a",
            cluster_kind: "endpoint-summary",
            cluster_anchor_id: "switch",
          },
        },
      ],
      edges: [{id: "census-endpoint", source: 0, target: 1, topologyClass: "endpoints"}],
      route: {
        id: "census-route",
        sourceId: "switch",
        targetId: "census",
        relationIds: ["census-endpoint"],
      },
    })

    const renderAtDensity = (managedTopologyVisualDensity) => {
      ctx.state.managedTopologyVisualDensity = managedTopologyVisualDensity
      const effective = ctx.reshapeGraph(graph)
      return {effective, visible: ctx.buildVisibleGraphData(effective)}
    }
    const overview = renderAtDensity("overview")
    const detail = renderAtDensity("detail")

    for (const frame of [overview, detail]) {
      expect(frame.effective.shape).toBe("local")
      expect(frame.visible.nodeData.map((node) => node.id)).toEqual(["switch", "census"])
      expect(frame.visible.edgeData.map((edge) => edge.relationIds)).toEqual([["census-endpoint"]])
      expect(frame.visible.selectedVisibleNode?.id).toBe("census")
    }
  })

  it("keeps accepted ELK scene routes authoritative at overview display shape", () => {
    const scene = topologyScene()
    expect(hasManagedTopologySceneRoutes({shape: "global", _layoutMode: "elk-radial-overview", _topologyScene: scene})).toBe(true)
    expect(hasManagedTopologySceneRoutes({shape: "local", _layoutMode: "elk-scene-detail", _topologyScene: scene})).toBe(true)
    expect(hasManagedTopologySceneRoutes({shape: "local", _layoutMode: "elk-scene", _topologyScene: scene})).toBe(false)
    expect(hasManagedTopologySceneRoutes({shape: "local", _layoutMode: "elk-scene-detail-error", _topologyScene: scene})).toBe(false)
  })

  it("uses pre-laid scene routes without post-layout aggregation", async () => {
    const collapseExpandedMemberTrunks = vi.fn()
    const aggregateVisibleEdges = vi.fn()
    const ctx = baseContext({overrides: {collapseExpandedMemberTrunks, aggregateVisibleEdges}})

    for (const graph of [collapsedFarm01Graph(), expandedFarm01Graph()]) {
      const input = prepareTopologySceneInput(graph)
      const scene = await layoutTopologyScene(input, {engine: new ELK(), profile: LANDSCAPE_PROFILE})
      const laidOut = applyTopologySceneToGraph(graph, scene)
      const out = ctx.buildVisibleGraphData({shape: "local", ...laidOut})

      expect(out.edgeData).toHaveLength(scene.physicalRoutes.length)
      expect(out.edgeData.filter((edge) => !edge.auxiliary).map((edge) => edge.interactionKey).sort()).toEqual(
        scene.routes.map((route) => `local:${route.id}`).sort(),
      )
      expect(out.edgeData.filter((edge) => edge.auxiliary)).toHaveLength(scene.manifolds.length * 2)
      expect(ctx.state.lastVisibleEdgeCount).toBe(32)
      for (const route of scene.routes) {
        const edge = out.edgeData.find((candidate) => candidate.interactionKey === `local:${route.id}`)
        expect(edge.path).toEqual(route.points.map((point) => [point.x, point.y, 0]))
        expect(edge.relationIds).toEqual([...route.relationIds].sort())
      }
      for (const route of scene.physicalRoutes.filter((candidate) => candidate.auxiliary)) {
        const edge = out.edgeData.find((candidate) => candidate.routeId === route.id)
        expect(edge?.path).toEqual(route.points.map((point) => [point.x, point.y, 0]))
        expect(edge?.interactionKey).toBeNull()
        expect(edge?.telemetryEligible).toBe(false)
      }
    }

    expect(collapseExpandedMemberTrunks).not.toHaveBeenCalled()
    expect(aggregateVisibleEdges).not.toHaveBeenCalled()
  })

  it("samples a scene route midpoint by cumulative polyline distance", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologyScene: {
        nodes: [],
        bounds: {minX: 0, minY: 0, maxX: 10, maxY: 30},
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

  it("rejects a route with a non-finite intermediate point instead of shortcutting it", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologyScene: {
        nodes: [],
        bounds: {minX: 0, minY: 0, maxX: 10, maxY: 0},
        routes: [
          {
            id: "valid",
            sourceId: "a",
            targetId: "b",
            points: [{x: 0, y: 0}, {x: 10, y: 0}],
            relationIds: ["a-b"],
            metadata: {},
          },
          {
            id: "invalid-middle",
            sourceId: "a",
            targetId: "b",
            points: [{x: 0, y: 0}, {x: Number.NaN, y: 5}, {x: 10, y: 0}],
            relationIds: ["a-b"],
            metadata: {},
          },
        ],
      },
      nodes: [
        {id: "a", x: 0, y: 0, state: 0, label: "A", operUp: 1, details: {}},
        {id: "b", x: 10, y: 0, state: 1, label: "B", operUp: 1, details: {}},
      ],
      edges: [{id: "a-b", source: 0, target: 1, topologyClass: "backbone"}],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.edgeData).toHaveLength(1)
    expect(out.edgeData[0].interactionKey).toEqual("local:valid")
  })

  it("fails closed with a deterministic diagnostic when a route has no relation bindings", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologyScene: {
        nodes: [],
        bounds: {minX: 0, minY: 0, maxX: 10, maxY: 0},
        routes: [{
          id: "orphan-route",
          sourceId: "a",
          targetId: "b",
          points: [{x: 0, y: 0}, {x: 10, y: 0}],
          relationIds: [],
          metadata: {flowPps: 999_999},
        }],
      },
      nodes: [
        {id: "a", x: 0, y: 0, state: 0, label: "A", operUp: 1, details: {}},
        {id: "b", x: 10, y: 0, state: 1, label: "B", operUp: 1, details: {}},
      ],
      edges: [],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.edgeData).toEqual([])
    expect(ctx.state.topologyRouteDiagnostics).toEqual([{
      routeId: "orphan-route",
      reason: "missing-relation-bindings",
      relationIds: [],
      missingRelationIds: [],
    }])
  })

  it("fails closed when even one contributing relation cannot be resolved", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologyScene: {
        nodes: [],
        bounds: {minX: 0, minY: 0, maxX: 10, maxY: 0},
        routes: [{
          id: "partial-route",
          sourceId: "a",
          targetId: "b",
          points: [{x: 0, y: 0}, {x: 10, y: 0}],
          relationIds: ["known", "missing"],
          metadata: {flowPps: 999_999},
        }],
      },
      nodes: [
        {id: "a", x: 0, y: 0, state: 0, label: "A", operUp: 1, details: {}},
        {id: "b", x: 10, y: 0, state: 1, label: "B", operUp: 1, details: {}},
      ],
      edges: [{id: "known", source: 0, target: 1, topologyClass: "backbone", flowPps: 7}],
    }

    const out = ctx.buildVisibleGraphData(effective)

    expect(out.edgeData).toEqual([])
    expect(ctx.state.topologyRouteDiagnostics).toEqual([{
      routeId: "partial-route",
      reason: "unresolved-relation-bindings",
      relationIds: ["known", "missing"],
      missingRelationIds: ["missing"],
    }])
  })

  it("ignores stale route metadata and derives semantic fields from current relations", () => {
    const ctx = baseContext()
    const effective = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologyScene: {
        nodes: [],
        bounds: {minX: 0, minY: 0, maxX: 20, maxY: 0},
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
      flowPps: 130,
      flowPpsAb: 75,
      flowPpsBa: 55,
      label: "a -> b",
    })
    expect(out.edgeData[0].relationIds).toEqual(["forward", "reverse"])
  })

  it.each([
    {
      name: "backbone off",
      topologyLayers: {backbone: false, inferred: false, endpoints: false},
      topologyClass: "backbone",
      expectedRoutes: 0,
    },
    {
      name: "inferred off",
      topologyLayers: {backbone: true, inferred: false, endpoints: false},
      topologyClass: "inferred",
      expectedRoutes: 0,
    },
    {
      name: "inferred on",
      topologyLayers: {backbone: false, inferred: true, endpoints: false},
      topologyClass: "inferred",
      expectedRoutes: 1,
    },
  ])("filters managed scene routes when $name", ({topologyLayers, topologyClass, expectedRoutes}) => {
    const ctx = topologyAwareContext(topologyLayers)
    const scene = managedRouteGraph({
      nodes: [
        {id: "a", x: 0, y: 0, state: 0, label: "A", operUp: 1, details: {}},
        {id: "b", x: 100, y: 0, state: 1, label: "B", operUp: 1, details: {}},
      ],
      edges: [{id: "relation", source: 0, target: 1, topologyClass}],
      route: {id: "route", sourceId: "a", targetId: "b", relationIds: ["relation"]},
    })

    const out = ctx.buildVisibleGraphData(scene)

    expect(out.edgeData).toHaveLength(expectedRoutes)
    expect(ctx.state.layoutEngine.layout).not.toHaveBeenCalled()
    expect(scene._topologyScene.routes[0].points).toEqual([{x: 0, y: 0}, {x: 100, y: 0}])
  })

  it("removes a managed route when a state filter hides either rendered endpoint", () => {
    const ctx = baseContext({
      overrides: {
        visibilityMask: vi.fn(() => Uint8Array.from([1, 0])),
      },
    })
    const graph = managedRouteGraph({
      nodes: [
        {id: "a", x: 0, y: 0, state: 0, label: "A", operUp: 1, details: {}},
        {id: "b", x: 100, y: 0, state: 1, label: "B", operUp: 1, details: {}},
      ],
      edges: [{id: "a-b", source: 0, target: 1, topologyClass: "backbone"}],
      route: {id: "route:a-b", sourceId: "a", targetId: "b", relationIds: ["a-b"]},
    })

    const out = ctx.buildVisibleGraphData(graph)

    expect(out.nodeData.map((node) => node.id)).toEqual(["a"])
    expect(out.edgeData).toEqual([])
  })

  it("hides a normal managed endpoint route and node while retaining the attachment census trunk", () => {
    const topologyLayers = {backbone: true, inferred: false, endpoints: false}
    const normalCtx = topologyAwareContext(topologyLayers)
    const normal = managedRouteGraph({
      nodes: [
        {
          id: "switch",
          x: 0,
          y: 0,
          state: 0,
          label: "Switch",
          operUp: 1,
          details: {cluster_id: "cluster-a", cluster_kind: "endpoint-anchor", cluster_anchor_id: "switch"},
        },
        {id: "client", x: 100, y: 0, state: 1, label: "Client", operUp: 1, details: {}},
      ],
      edges: [{id: "normal-endpoint", source: 0, target: 1, topologyClass: "endpoints"}],
      route: {id: "normal-route", sourceId: "switch", targetId: "client", relationIds: ["normal-endpoint"]},
    })

    const normalOut = normalCtx.buildVisibleGraphData(normal)

    expect(normalOut.nodeData.map((node) => node.id)).toEqual(["switch"])
    expect(normalOut.edgeData).toEqual([])

    const censusCtx = topologyAwareContext(topologyLayers)
    const census = managedRouteGraph({
      nodes: [
        {
          id: "switch",
          x: 0,
          y: 0,
          state: 0,
          label: "Switch",
          operUp: 1,
          details: {cluster_id: "cluster-a", cluster_kind: "endpoint-anchor", cluster_anchor_id: "switch"},
        },
        {
          id: "census",
          x: 100,
          y: 0,
          state: 1,
          label: "12 endpoints",
          operUp: 1,
          details: {cluster_id: "cluster-a", cluster_kind: "endpoint-summary", cluster_anchor_id: "switch"},
        },
      ],
      edges: [{id: "census-endpoint", source: 0, target: 1, topologyClass: "endpoints"}],
      route: {id: "census-route", sourceId: "switch", targetId: "census", relationIds: ["census-endpoint"]},
    })

    const censusOut = censusCtx.buildVisibleGraphData(census)

    expect(censusOut.nodeData.map((node) => node.id)).toEqual(["switch", "census"])
    expect(censusOut.edgeData).toHaveLength(1)
    expect(censusOut.edgeData[0].relationIds).toEqual(["census-endpoint"])
    expect(censusCtx.state.layoutEngine.layout).not.toHaveBeenCalled()

    censusCtx.state.topologyLayers = {backbone: false, inferred: false, endpoints: false}
    expect(censusCtx.buildVisibleGraphData(census).edgeData).toEqual([])
  })

  it.each([
    {
      name: "summary points at another anchor",
      anchor: {cluster_id: "cluster-a", cluster_kind: "endpoint-anchor", cluster_anchor_id: "switch"},
      summary: {cluster_id: "cluster-a", cluster_kind: "endpoint-summary", cluster_anchor_id: "other-switch"},
    },
    {
      name: "summary belongs to another cluster",
      anchor: {cluster_id: "cluster-a", cluster_kind: "endpoint-anchor", cluster_anchor_id: "switch"},
      summary: {cluster_id: "cluster-b", cluster_kind: "endpoint-summary", cluster_anchor_id: "switch"},
    },
    {
      name: "summary is joined to an arbitrary node",
      anchor: {},
      summary: {cluster_id: "cluster-a", cluster_kind: "endpoint-summary", cluster_anchor_id: "switch"},
    },
  ])("does not retain a noncanonical managed census relation when $name", ({anchor, summary}) => {
    const ctx = topologyAwareContext({backbone: true, inferred: false, endpoints: false})
    const graph = managedRouteGraph({
      nodes: [
        {id: "switch", x: 0, y: 0, state: 0, label: "Switch", operUp: 1, details: anchor},
        {id: "census", x: 100, y: 0, state: 1, label: "Summary", operUp: 1, details: summary},
      ],
      edges: [{id: "invalid-census", source: 0, target: 1, topologyClass: "endpoints"}],
      route: {id: "invalid-route", sourceId: "switch", targetId: "census", relationIds: ["invalid-census"]},
    })

    const out = ctx.buildVisibleGraphData(graph)

    expect(out.edgeData).toEqual([])
  })

  it("keeps prepared expanded members layout-only when managed endpoint routes are hidden", async () => {
    const graph = expandedFarm01Graph()
    const input = prepareTopologySceneInput(graph)
    const memberRelationIds = input.layoutRelations.flatMap((relation) => relation.relationIds)

    expect(memberRelationIds).toHaveLength(24)
    expect(input.renderedRelations.flatMap((relation) => relation.relationIds)).not.toEqual(
      expect.arrayContaining(memberRelationIds),
    )

    const scene = await layoutTopologyScene(input, {engine: new ELK(), profile: LANDSCAPE_PROFILE})
    const effective = {shape: "local", ...applyTopologySceneToGraph(graph, scene)}
    const ctx = topologyAwareContext({backbone: true, inferred: false, endpoints: false})
    const out = ctx.buildVisibleGraphData(effective)

    const renderedRelationIds = out.edgeData.flatMap((edge) => edge.relationIds)
    expect(renderedRelationIds.some((relationId) => relationId.startsWith("farm01:attachment:member-"))).toEqual(false)
    expect(renderedRelationIds.some((relationId) => relationId.startsWith("farm01:attachment:device-"))).toEqual(false)
    expect(renderedRelationIds.some((relationId) => relationId.startsWith("farm01:attachment:summary-"))).toEqual(true)
    expect(ctx.state.layoutEngine.layout).not.toHaveBeenCalled()
  })

  it("filters only disabled constituents from a mixed-class managed route", () => {
    const ctx = topologyAwareContext({backbone: false, inferred: true, endpoints: false})
    const graph = managedRouteGraph({
      nodes: [
        {id: "a", x: 0, y: 0, state: 0, label: "A", operUp: 1, details: {}},
        {id: "b", x: 100, y: 0, state: 1, label: "B", operUp: 1, details: {}},
      ],
      edges: [
        {id: "backbone", source: 0, target: 1, topologyClass: "backbone", flowPps: 100},
        {id: "inferred", source: 0, target: 1, topologyClass: "inferred", flowPps: 7},
      ],
      route: {
        id: "mixed-route",
        sourceId: "a",
        targetId: "b",
        relationIds: ["backbone", "inferred"],
        metadata: {flowPps: 107},
      },
    })

    const inferredOnly = ctx.buildVisibleGraphData(graph)

    expect(inferredOnly.edgeData).toHaveLength(1)
    expect(inferredOnly.edgeData[0]).toMatchObject({
      relationIds: ["inferred"],
      flowPps: 7,
      topologyClass: "inferred",
      topologyClassCounts: expect.objectContaining({backbone: 0, inferred: 1}),
    })

    ctx.state.topologyLayers = {backbone: true, inferred: false, endpoints: false}
    const backboneOnly = ctx.buildVisibleGraphData(graph)
    expect(backboneOnly.edgeData[0]).toMatchObject({
      relationIds: ["backbone"],
      flowPps: 100,
      topologyClass: "backbone",
      topologyClassCounts: expect.objectContaining({backbone: 1, inferred: 0}),
    })
    expect(ctx.state.layoutEngine.layout).not.toHaveBeenCalled()
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
        {id: "switch", x: 3, y: 4, state: 1, label: "Switch", pps: 20, operUp: 2, details: {cluster_id: "cluster-a", cluster_kind: "endpoint-anchor", cluster_anchor_id: "switch"}},
        {id: "census", x: 5, y: 6, state: 1, label: "12 endpoints", pps: 5, operUp: 1, details: {cluster_id: "cluster-a", cluster_kind: "endpoint-summary", cluster_anchor_id: "switch"}},
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
        {id: "switch", x: 3, y: 4, state: 1, label: "Switch", pps: 20, operUp: 2, details: {cluster_id: "cluster-a", cluster_kind: "endpoint-anchor", cluster_anchor_id: "switch"}},
        {id: "census", x: 5, y: 6, state: 1, label: "12 endpoints", pps: 5, operUp: 1, details: {cluster_id: "cluster-a", cluster_kind: "endpoint-summary", cluster_expanded: true, cluster_anchor_id: "switch"}},
        {
          id: "client",
          x: 7,
          y: 8,
          state: 1,
          label: "Client",
          pps: 5,
          operUp: 1,
          details: {cluster_id: "cluster-a", cluster_kind: "endpoint-member", cluster_expanded: true, cluster_anchor_id: "switch"},
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
