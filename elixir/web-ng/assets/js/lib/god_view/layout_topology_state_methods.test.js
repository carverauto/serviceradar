import ELK from "elkjs/lib/elk.bundled.js"
import {describe, expect, it, vi} from "vitest"

import {
  FARM01_EXPECTED,
  collapsedFarm01Graph,
  expandedFarm01Graph,
} from "./fixtures/farm01_topology_regression"
import {godViewLayoutTopologyStateMethods} from "./layout_topology_state_methods"
import {godViewLifecycleBootstrapStateDefaultsMethods} from "./lifecycle_bootstrap_state_defaults_methods"

function realLayoutSpy() {
  const engine = new ELK()
  return vi.fn((graph) => engine.layout(graph))
}

function makeContext(overrides = {}) {
  const stateOverrides = overrides.state || {}
  return {
    state: {
      layoutMode: "auto",
      layoutRevision: null,
      layoutCache: new Map(),
      lastLayoutKey: null,
      layoutEngine: {layout: realLayoutSpy()},
      lastGraph: null,
      lastTopologyStamp: null,
      lastRevision: null,
      viewportWidth: 1920,
      viewportHeight: 1080,
      viewportSafeInsets: {top: 0, right: 0, bottom: 0, left: 0},
      ...stateOverrides,
    },
    ...godViewLayoutTopologyStateMethods,
    ...Object.fromEntries(Object.entries(overrides).filter(([key]) => key !== "state")),
  }
}

function sceneCenters(graph) {
  return Object.fromEntries(
    graph._topologyScene.nodes.map((node) => [node.id, node.center]),
  )
}

function detailGraph(graph) {
  return {...graph, _topologySemanticLevel: "detail"}
}

describe("layout_topology_state_methods", () => {
  it("selects radial overview by default and Layered detail only for an explicit bounded-detail graph", async () => {
    const overviewContext = makeContext()
    const overview = await overviewContext.prepareGraphLayout(collapsedFarm01Graph(), 1, "overview")
    const detailContext = makeContext()
    const detail = await detailContext.prepareGraphLayout({
      ...collapsedFarm01Graph(),
      _topologySemanticLevel: "detail",
    }, 2, "detail")

    expect(overview._layoutMode).toBe("elk-radial-overview")
    expect(overview._topologyScene.profileKey).toBe("radial-overview")
    expect(overview._topologyScene.routes).toHaveLength(11)
    expect(detail._layoutMode).toBe("elk-scene-detail")
    expect(detail._topologyScene.profileKey).toBe("landscape")
    expect(detail._topologyScene.routes).toHaveLength(32)
  })

  it("keys cached geometry by semantic level, adapter profile, and structural graph identity", () => {
    const context = makeContext()

    expect(context.graphLayoutCacheKey(
      {graphKey: "graph-a"},
      {key: "radial-overview"},
      "overview",
    )).toBe("overview:radial-overview:graph-a")
    expect(context.graphLayoutCacheKey(
      {graphKey: "graph-a"},
      {key: "landscape"},
      "detail",
    )).toBe("detail:landscape:graph-a")
  })

  it("hydrates overview geometry with current projection metadata and never cached cross-link metadata", async () => {
    const context = makeContext()
    const graph = collapsedFarm01Graph()
    const first = await context.prepareGraphLayout(graph, 3, "first")
    const cachedGeometry = context.state.layoutCache.get(first._layoutCacheKey)
    context.state.layoutCache.set(first._layoutCacheKey, {
      ...cachedGeometry,
      nodes: cachedGeometry.nodes.map((node) => ({...node, label: "stale cached label"})),
      routes: cachedGeometry.routes.map((route) => ({...route, evidence: [{id: "stale-route"}]})),
      crossLinks: [{id: "stale-cross-link", evidence: [{id: "stale-cross-link"}]}],
    })
    const currentGraph = {
      ...graph,
      nodes: graph.nodes.map((node, index) => index === 0
        ? {...node, label: "Current gateway label"}
        : node),
      edges: graph.edges.map((edge) => {
        if (edge.id === "farm01:backbone:01") {
          return {...edge, metadata: {...edge.metadata, live: "current-tree-route"}}
        }
        if (edge.id === "farm01:backbone:03") {
          return {...edge, metadata: {...edge.metadata, live: "current-cross-link"}}
        }
        return edge
      }),
    }

    const second = await context.prepareGraphLayout(currentGraph, 4, "second")

    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(1)
    expect(second._layoutCacheKey).toBe(first._layoutCacheKey)
    expect(sceneCenters(second)).toEqual(sceneCenters(first))
    expect(second._topologyScene.nodes.find((node) => node.id === graph.nodes[0].id)?.label).toBe(
      "Current gateway label",
    )
    expect(second._topologyScene.routes.flatMap((route) => route.evidence)).toContainEqual(
      expect.objectContaining({metadata: expect.objectContaining({live: "current-tree-route"})}),
    )
    expect(second._topologyScene.crossLinks.flatMap((relation) => relation.evidence)).toContainEqual(
      expect.objectContaining({metadata: expect.objectContaining({live: "current-cross-link"})}),
    )
    expect(second._topologyScene.crossLinks).not.toContainEqual(
      expect.objectContaining({id: "stale-cross-link"}),
    )
    expect(cachedGeometry).not.toHaveProperty("crossLinks")
  })

  it("keeps radial overview cache geometry reusable across viewport profiles", async () => {
    const context = makeContext()
    const graph = collapsedFarm01Graph()
    const first = await context.prepareGraphLayout(graph, 5, "landscape")
    context.state.viewportWidth = 600
    context.state.viewportHeight = 1200

    const portraitViewport = await context.prepareGraphLayout(graph, 6, "portrait")

    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(1)
    expect(portraitViewport._layoutCacheKey).toBe(first._layoutCacheKey)
    expect(sceneCenters(portraitViewport)).toEqual(sceneCenters(first))
  })

  it("initializes deterministic viewport dimensions and safe insets for scene profiling", () => {
    const state = {}

    godViewLifecycleBootstrapStateDefaultsMethods.initLifecycleState.call({state})

    expect(state.viewportWidth).toEqual(1280)
    expect(state.viewportHeight).toEqual(720)
    expect(state.viewportSafeInsets).toEqual({top: 0, right: 0, bottom: 0, left: 0})
  })

  it("geoGridData returns no grid outside geo mode", () => {
    const context = makeContext()

    expect(context.geoGridData()).toEqual([])
  })

  it("geoGridData returns projected grid lines in geo mode", () => {
    const context = makeContext({state: {layoutMode: "geo"}})

    const out = context.geoGridData()

    expect(out.length).toBeGreaterThan(0)
    expect(out[0]).toHaveProperty("sourcePosition")
    expect(out[0]).toHaveProperty("targetPosition")
  })

  it("graphTopologyStamp is stable when node and edge array order changes", () => {
    const graphA = {
      nodes: [{id: "a"}, {id: "b"}, {id: "c"}],
      edges: [{source: 0, target: 1}, {source: 1, target: 2}],
    }
    const graphB = {
      nodes: [{id: "c"}, {id: "a"}, {id: "b"}],
      edges: [{source: 1, target: 2}, {source: 2, target: 0}],
    }

    expect(godViewLayoutTopologyStateMethods.graphTopologyStamp(graphA)).toEqual(
      godViewLayoutTopologyStateMethods.graphTopologyStamp(graphB),
    )
  })

  it("dedupeGraphById removes duplicate nodes and preserves every remapped semantic edge", () => {
    const context = makeContext()
    const graph = {
      nodes: [
        {id: "router-1", label: "Router 1", details: {}},
        {id: "router-1", label: "Router 1 Duplicate", details: {cluster_expanded: true}},
        {id: "switch-1", label: "Switch 1", details: {}},
      ],
      edges: [
        {source: 0, target: 2, topologyClass: "backbone"},
        {source: 1, target: 2, topologyClass: "backbone"},
      ],
    }

    const out = context.dedupeGraphById(graph)

    expect(out.nodes).toHaveLength(2)
    expect(out.edges).toHaveLength(2)
    expect(out.nodes[0].details.cluster_expanded).toEqual(true)
    expect(out.edges).toEqual([
      expect.objectContaining({source: 0, target: 1}),
      expect.objectContaining({source: 0, target: 1}),
    ])
  })

  it("dedupeGraphById preserves duplicate-node aggregation semantics", () => {
    const context = makeContext()
    const graph = {
      nodes: [
        {
          id: "router-1",
          label: "Preferred label",
          state: 1,
          x: 10,
          y: Number.NaN,
          pps: 200,
          clusterCount: 4,
          operUp: 0,
          details: {shared: "existing", existingOnly: true, cluster_expanded: false},
        },
        {
          id: "router-1",
          label: "Incoming label",
          state: 3,
          x: 20,
          y: 30,
          pps: 900,
          clusterCount: 12,
          operUp: 1,
          details: {shared: "incoming", incomingOnly: true, cluster_expanded: true},
        },
      ],
      edges: [],
    }

    const out = context.dedupeGraphById(graph)

    expect(out.nodes).toEqual([
      expect.objectContaining({
        id: "router-1",
        label: "Preferred label",
        state: 3,
        x: 10,
        y: 30,
        pps: 900,
        clusterCount: 12,
        operUp: 1,
        details: {
          shared: "incoming",
          existingOnly: true,
          incomingOnly: true,
          cluster_expanded: true,
        },
      }),
    ])
  })

  it("preserves parallel, reverse, and exact duplicate semantic relations with canonical identities", () => {
    const context = makeContext()
    const graph = {
      nodes: [{id: "a", details: {}}, {id: "b", details: {}}],
      edges: [
        {
          source: 0,
          target: 1,
          topologyClass: "backbone",
          protocol: "snmp",
          evidenceClass: "direct",
          label: "uplink",
          flowPps: 100,
          details: {source_if_index: 10, source_interface: "xe-0/0/0", target_if_index: 20, target_interface: "xe-0/0/1"},
        },
        {
          source: 1,
          target: 0,
          topologyClass: "backbone",
          protocol: "snmp",
          evidenceClass: "direct",
          label: "uplink",
          flowPps: 50,
          details: {source_if_index: 20, source_interface: "xe-0/0/1", target_if_index: 10, target_interface: "xe-0/0/0"},
        },
        {
          source: 0,
          target: 1,
          topologyClass: "backbone",
          protocol: "snmp",
          evidenceClass: "direct",
          label: "uplink",
          flowPps: 7,
          details: {source_if_index: 11, source_interface: "xe-0/0/2", target_if_index: 21, target_interface: "xe-0/0/3"},
        },
        {
          source: 0,
          target: 1,
          topologyClass: "backbone",
          protocol: "snmp",
          evidenceClass: "direct",
          label: "uplink",
          flowPps: 30,
          details: {source_if_index: 10, source_interface: "xe-0/0/0", target_if_index: 20, target_interface: "xe-0/0/1"},
        },
      ],
    }

    const out = context.dedupeGraphById(graph)

    expect(out.edges).toHaveLength(4)
    expect(out.edges.every((edge) => typeof edge.id === "string" && edge.id.startsWith("semantic:"))).toEqual(true)
    expect(new Set(out.edges.map((edge) => edge.id)).size).toEqual(3)
    expect(out.edges.map((edge) => edge.flowPps)).toEqual([100, 50, 7, 30])
  })

  it.each([
    {state: "collapsed", build: collapsedFarm01Graph, mode: "elk-radial-overview", routes: 11},
    // 35 nodes (12 backbone + 24 members, less the expanded summary the members replaced),
    // and the overview lays out a tree, so exactly n-1 routes.
    {state: "expanded", build: expandedFarm01Graph, mode: "elk-radial-overview", routes: 34},
  ])("uses one accepted scene as the geometry authority for the $state farm01 fixture", async ({build, mode, routes}) => {
    const context = makeContext()

    const out = await context.prepareGraphLayout(build(), 5, "stamp")

    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(1)
    expect(out._layoutMode).toEqual(mode)
    expect(out._topologyScene.routes).toHaveLength(routes)
    expect(out._topologyScene.nodes.every((node) => (
      Number.isFinite(node.center.x) && Number.isFinite(node.center.y)
    ))).toEqual(true)
    expect(context.state.layoutMode).toEqual(mode)
  })

  it("can prepare a layout without mutating accepted layout metadata", async () => {
    const context = makeContext({state: {
      layoutMode: "elk-radial-overview",
      layoutRevision: 40,
      lastLayoutKey: "accepted-layout",
    }})

    const out = await context.prepareGraphLayout(
      collapsedFarm01Graph(),
      41,
      "new-stamp",
      {commit: false},
    )

    expect(out._layoutRevision).toBe(41)
    expect(out._layoutCacheKey).not.toBe("accepted-layout")
    expect(context.state.layoutMode).toBe("elk-radial-overview")
    expect(context.state.layoutRevision).toBe(40)
    expect(context.state.lastLayoutKey).toBe("accepted-layout")
  })

  it("contains all 24 expanded members in one accepted compound group", async () => {
    const context = makeContext()

    const out = await context.prepareGraphLayout(detailGraph(expandedFarm01Graph()), 6, "expanded")
    const [group] = out._topologyScene.groups
    const nodesById = new Map(out._topologyScene.nodes.map((node) => [node.id, node]))

    expect(group.memberIds).toHaveLength(24)
    expect(group.memberIds.every((id) => nodesById.get(id)?.groupId === group.id)).toEqual(true)
    expect(group.memberIds.every((id) => {
      const node = nodesById.get(id)
      return (
        node.center.x - node.width / 2 >= group.bounds.minX &&
        node.center.y - node.height / 2 >= group.bounds.minY &&
        node.center.x + node.width / 2 <= group.bounds.maxX &&
        node.center.y + node.height / 2 <= group.bounds.maxY
      )
    })).toEqual(true)
  })

  it("reapplies cached immutable scene geometry to current telemetry across revisions", async () => {
    const context = makeContext()
    const graph = detailGraph(collapsedFarm01Graph())
    const first = await context.prepareGraphLayout(graph, 9, "old-stamp")
    const callsBeforeHit = context.state.layoutEngine.layout.mock.calls.length
    const currentGraph = {
      ...graph,
      revision: 10,
      nodes: graph.nodes.map((node, index) => index === 0
        ? {...node, label: "Current gateway", state: 3, pps: 9876, details: {...node.details, live: "current"}}
        : node),
      edges: graph.edges.map((edge, index) => index === 0
        ? {...edge, flowPps: 4321, details: {live: "current"}}
        : edge),
    }

    const second = await context.prepareGraphLayout(currentGraph, 10, "new-stamp")

    expect(context.state.layoutEngine.layout.mock.calls.length - callsBeforeHit).toEqual(0)
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(1)
    expect(second).not.toBe(first)
    expect(second._topologyScene).not.toBe(first._topologyScene)
    expect(sceneCenters(second)).toEqual(sceneCenters(first))
    expect(second._topologyScene.routes.map((route) => route.points)).toEqual(
      first._topologyScene.routes.map((route) => route.points),
    )
    expect(second._topologyScene.physicalRoutes.map((route) => route.points)).toEqual(
      first._topologyScene.physicalRoutes.map((route) => route.points),
    )
    expect(second._layoutCacheKey).toEqual(first._layoutCacheKey)
    expect(second._layoutRevision).toEqual(10)
    expect(second.revision).toEqual(10)
    expect(second.nodes[0]).toMatchObject({
      label: "Current gateway",
      state: 3,
      pps: 9876,
      details: expect.objectContaining({live: "current"}),
    })
    expect(second.edges[0]).toMatchObject({flowPps: 4321, details: {live: "current"}})
    const cachedGeometry = context.state.layoutCache.get(first._layoutCacheKey)
    expect(cachedGeometry).not.toBe(first._topologyScene)
    expect(cachedGeometry).not.toHaveProperty("manifest")
    expect(cachedGeometry).not.toHaveProperty("key")
    expect(cachedGeometry.routes[0]).toMatchObject({
      id: first._topologyScene.routes[0].id,
      points: first._topologyScene.routes[0].points,
    })
    expect(cachedGeometry.manifolds).toHaveLength(8)
    expect(cachedGeometry.auxiliaryRoutes).toHaveLength(16)
    expect(cachedGeometry.routes[0]).not.toHaveProperty("relationIds")
    expect(cachedGeometry.routes[0]).not.toHaveProperty("metadata")
    expect(Object.isFrozen(first._topologyScene)).toEqual(true)
    expect(Object.isFrozen(first._topologyScene.nodes)).toEqual(true)
    expect(Object.isFrozen(first._topologyScene.nodes[0].center)).toEqual(true)
    expect(Object.isFrozen(first._topologyScene.routes[0].points)).toEqual(true)
    expect(Object.isFrozen(cachedGeometry)).toEqual(true)
    expect(Object.isFrozen(cachedGeometry.routes[0].points)).toEqual(true)
  })

  it("rebuilds the current manifest on a structural cache hit", async () => {
    const context = makeContext()
    const graph = detailGraph(collapsedFarm01Graph())
    const first = await context.prepareGraphLayout(graph, 20, "first")
    const currentGraph = {
      ...graph,
      revision: 21,
      edges: [
        ...graph.edges,
        {...graph.edges[0], flowPps: 91, details: {sample: "new duplicate"}},
      ],
    }

    const second = await context.prepareGraphLayout(currentGraph, 21, "telemetry-duplicate")

    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(1)
    expect(second._layoutCacheKey).toEqual(first._layoutCacheKey)
    expect(second._topologyScene).not.toBe(first._topologyScene)
    expect(second._topologyScene.manifest.semanticEdges).toEqual(first._topologyScene.manifest.semanticEdges + 1)
    expect(second._topologyScene.routes.map((route) => route.relationIds)).toEqual(
      first._topologyScene.routes.map((route) => route.relationIds),
    )
    expect(second.edges.at(-1)).toMatchObject({flowPps: 91, details: {sample: "new duplicate"}})
  })

  it("keeps the cache stable within a viewport profile and invalidates across the profile threshold", async () => {
    const context = makeContext()
    const graph = detailGraph(collapsedFarm01Graph())
    const first = await context.prepareGraphLayout(graph, 10, "stamp")
    context.state.viewportWidth = 1600
    context.state.viewportHeight = 1000

    const sameProfile = await context.prepareGraphLayout(graph, 10, "stamp")
    context.state.viewportWidth = 800
    context.state.viewportHeight = 1000
    const portrait = await context.prepareGraphLayout(graph, 10, "stamp")

    expect(sameProfile).not.toBe(first)
    expect(sameProfile._topologyScene).not.toBe(first._topologyScene)
    expect(sceneCenters(sameProfile)).toEqual(sceneCenters(first))
    expect(portrait._topologyScene).not.toBe(first._topologyScene)
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(2)
    expect(first._topologyScene.profileKey).toEqual("landscape")
    expect(portrait._topologyScene.profileKey).toEqual("portrait")
  })

  it("includes structural graph identity in the cache key", async () => {
    const context = makeContext()
    const collapsed = await context.prepareGraphLayout(detailGraph(collapsedFarm01Graph()), 11, "same-stamp")
    const expanded = await context.prepareGraphLayout(detailGraph(expandedFarm01Graph()), 11, "same-stamp")

    expect(collapsed._layoutCacheKey).not.toEqual(expanded._layoutCacheKey)
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(2)
  })

  it("invalidates cached geometry when semantic evidence changes", async () => {
    const context = makeContext()
    const graph = detailGraph(collapsedFarm01Graph())
    const withoutServerIdentity = {
      ...graph,
      edges: graph.edges.map((edge, index) => index === 0
        ? {...edge, id: undefined, evidenceClass: "direct"}
        : edge),
    }
    const changedEvidence = {
      ...withoutServerIdentity,
      edges: withoutServerIdentity.edges.map((edge, index) => index === 0
        ? {...edge, evidenceClass: "endpoint-attachment"}
        : edge),
    }

    const first = await context.prepareGraphLayout(withoutServerIdentity, 30, "same-topology")
    const second = await context.prepareGraphLayout(changedEvidence, 31, "same-topology")

    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(2)
    expect(second._layoutCacheKey).not.toEqual(first._layoutCacheKey)
    expect(second._topologyScene.manifest.attachmentEdges).toEqual(
      first._topologyScene.manifest.attachmentEdges + 1,
    )
    expect(second.edges[0].evidenceClass).toEqual("endpoint-attachment")
    expect(second._topologyScene.routes.flatMap((route) => route.relationIds)).toContain(second.edges[0].id)
    expect(second._topologyScene.routes.flatMap((route) => route.relationIds)).not.toContain(first.edges[0].id)
  })

  it("ignores legacy input coordinates when applying accepted ELK centers", async () => {
    const cleanGraph = collapsedFarm01Graph()
    const legacyGraph = {
      ...cleanGraph,
      nodes: cleanGraph.nodes.map((node, index) => ({
        ...node,
        x: 900_000 + index,
        y: -900_000 - index,
      })),
    }
    const clean = await makeContext().prepareGraphLayout(cleanGraph, 12, "clean")
    const legacy = await makeContext().prepareGraphLayout(legacyGraph, 12, "legacy")

    expect(sceneCenters(legacy)).toEqual(sceneCenters(clean))
    expect(legacy.nodes.some((node) => Math.abs(node.x) >= 900_000 || Math.abs(node.y) >= 900_000)).toEqual(false)
  })

  it("returns a recoverable error without fallback coordinates when the first ELK layout fails", async () => {
    const context = makeContext({
      state: {
        layoutEngine: {layout: vi.fn(async () => { throw new Error("ELK unavailable") })},
      },
    })

    const out = await context.prepareGraphLayout(collapsedFarm01Graph(), 13, "failure")

    expect(out._layoutError).toContain("ELK unavailable")
    expect(out._topologyScene).toBeUndefined()
    expect(out.nodes.every((node) => node.x === undefined && node.y === undefined)).toEqual(true)
    expect(context.state.layoutCache.size).toEqual(0)
  })

  it("removes stale scene and layout annotations after an incompatible ELK failure", async () => {
    const context = makeContext({
      state: {
        layoutEngine: {layout: vi.fn(async () => { throw new Error("new ELK failure") })},
      },
    })
    const graph = {
      ...detailGraph(collapsedFarm01Graph()),
      nodes: collapsedFarm01Graph().nodes.map((node) => ({...node, x: 10, y: 20})),
      _topologyScene: {key: "stale-scene"},
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "stale-key",
      _layoutRevision: 1,
      _layoutError: "stale error",
    }

    const out = await context.prepareGraphLayout(graph, 15, "new-stamp")

    expect(out._topologyScene).toBeUndefined()
    expect(out._layoutMode).toEqual("elk-scene-detail-error")
    expect(out._layoutCacheKey).not.toEqual("stale-key")
    expect(out._layoutRevision).toEqual(15)
    expect(out._layoutError).toEqual("new ELK failure")
    expect(out.nodes.every((node) => node.x === undefined && node.y === undefined)).toEqual(true)
  })

  it("reuses only a structurally and profile-compatible last-good scene after ELK failure", async () => {
    const context = makeContext()
    const graph = detailGraph(expandedFarm01Graph())
    const accepted = await context.prepareGraphLayout(graph, 14, "stamp")
    context.state.lastGraph = accepted
    context.state.layoutCache.clear()
    context.state.layoutEngine = {
      layout: vi.fn(async () => { throw new Error("transient ELK failure") }),
    }

    const reused = await context.prepareGraphLayout(graph, 15, "new-stamp")

    expect(reused._topologyScene).not.toBe(accepted._topologyScene)
    expect(sceneCenters(reused)).toEqual(sceneCenters(accepted))
    expect(reused._layoutMode).toEqual("elk-scene-detail")
    expect(reused._layoutRevision).toEqual(15)
    expect(reused._layoutError).toContain("transient ELK failure")

    context.state.layoutCache.clear()
    const structurallyDifferent = {
      ...graph,
      nodes: graph.nodes.map((node, index) => index === 0 ? {...node, id: `${node.id}:replacement`} : node),
    }
    const incompatibleGraph = await context.prepareGraphLayout(structurallyDifferent, 15, "new-stamp")
    expect(incompatibleGraph._topologyScene).toBeUndefined()
    expect(incompatibleGraph.nodes.every((node) => node.x === undefined && node.y === undefined)).toEqual(true)

    const incompatibleExpansion = await context.prepareGraphLayout(
      detailGraph(collapsedFarm01Graph()),
      15,
      "new-stamp",
    )
    expect(incompatibleExpansion._topologyScene).toBeUndefined()
    expect(incompatibleExpansion.nodes.every((node) => node.x === undefined && node.y === undefined)).toEqual(true)

    context.state.viewportWidth = 800
    context.state.viewportHeight = 1000
    const incompatibleProfile = await context.prepareGraphLayout(graph, 15, "new-stamp")
    expect(incompatibleProfile._topologyScene).toBeUndefined()
    expect(incompatibleProfile.nodes.every((node) => node.x === undefined && node.y === undefined)).toEqual(true)
  })

  it("rejects last-known-good geometry from a different semantic mode even when its key is spoofed", async () => {
    const context = makeContext()
    const graph = collapsedFarm01Graph()
    const acceptedOverview = await context.prepareGraphLayout(graph, 16, "overview")
    context.state.lastGraph = {
      ...acceptedOverview,
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
    }
    context.state.layoutCache.clear()
    context.state.layoutEngine = {
      layout: vi.fn(async () => { throw new Error("cross-mode fallback probe") }),
    }

    const rejected = await context.prepareGraphLayout(graph, 17, "overview-retry")

    expect(rejected._layoutMode).toBe("elk-radial-overview-error")
    expect(rejected._topologyScene).toBeUndefined()
    expect(rejected.nodes.every((node) => node.x === undefined && node.y === undefined)).toBe(true)
  })

  it("rejects malformed last-known-good scene geometry before recovery", async () => {
    const context = makeContext()
    const graph = collapsedFarm01Graph()
    const accepted = await context.prepareGraphLayout(graph, 18, "accepted")
    context.state.lastGraph = {
      ...accepted,
      _topologyScene: {
        ...accepted._topologyScene,
        bounds: {...accepted._topologyScene.bounds, maxX: Number.NaN},
      },
    }
    context.state.layoutCache.clear()
    context.state.layoutEngine = {
      layout: vi.fn(async () => { throw new Error("malformed fallback probe") }),
    }

    const rejected = await context.prepareGraphLayout(graph, 19, "retry")

    expect(rejected._layoutMode).toBe("elk-radial-overview-error")
    expect(rejected._topologyScene).toBeUndefined()
    expect(rejected.nodes.every((node) => node.x === undefined && node.y === undefined)).toBe(true)
  })

  it("reapplies a compatible last-good scene without replacing current graph data", async () => {
    const context = makeContext()
    const graph = detailGraph(collapsedFarm01Graph())
    const accepted = await context.prepareGraphLayout(graph, 16, "stamp")
    context.state.lastGraph = accepted
    context.state.layoutCache.clear()
    context.state.layoutEngine = {
      layout: vi.fn(async () => { throw new Error("transient ELK failure") }),
    }
    const currentGraph = {
      ...graph,
      revision: 17,
      nodes: graph.nodes.map((node, index) => index === 0
        ? {...node, label: "Current gateway label", state: 3, pps: 9876}
        : node),
      edges: graph.edges.map((edge, index) => index === 0
        ? {...edge, metadata: {sample: "current"}, pps: 4321}
        : edge),
    }
    currentGraph.edges.push({...graph.edges[0], flowPps: 99, details: {sample: "current duplicate"}})

    const reused = await context.prepareGraphLayout(currentGraph, 17, "telemetry-only-stamp")

    expect(reused.nodes[0]).toMatchObject({
      label: "Current gateway label",
      state: 3,
      pps: 9876,
    })
    expect(reused.edges[0]).toMatchObject({metadata: {sample: "current"}, pps: 4321})
    expect(reused.nodes[0].x).toEqual(accepted.nodes[0].x)
    expect(reused.nodes[0].y).toEqual(accepted.nodes[0].y)
    expect(reused._topologyScene).not.toBe(accepted._topologyScene)
    expect(sceneCenters(reused)).toEqual(sceneCenters(accepted))
    expect(reused._topologyScene.manifest.semanticEdges).toEqual(
      accepted._topologyScene.manifest.semanticEdges + 1,
    )
    expect(reused._layoutRevision).toEqual(17)
    expect(reused.revision).toEqual(17)
    expect(reused._layoutCacheKey).toEqual(accepted._layoutCacheKey)
    expect(reused._layoutError).toEqual("transient ELK failure")
  })

  it("sameTopology accepts stable backend revisions even if the client stamp changed", () => {
    const context = makeContext({state: {lastRevision: 42, lastTopologyStamp: "old-stamp"}})

    const same = context.sameTopology(
      {nodes: [{id: "a"}], edges: []},
      {nodes: [{id: "a"}], edges: []},
      "new-stamp",
      42,
    )

    expect(same).toEqual(true)
  })
})

describe("layout_topology_state_methods expanded cluster elaboration", () => {
  // Expanding elaborates the radial atlas rather than replacing it: the backbone keeps its
  // radial layout and the opened cluster gains its members on the ring beyond its summary.
  it("renders every expanded cluster member without leaving the radial atlas", async () => {
    const graph = expandedFarm01Graph()
    const memberIds = graph.nodes
      .filter((node) => node.details?.cluster_kind === "endpoint-member")
      .map((node) => node.id)
    expect(memberIds).toHaveLength(FARM01_EXPECTED.addedMemberCount)

    const laidOut = await makeContext().prepareGraphLayout(graph, 1, "expanded")
    const sceneIds = new Set((laidOut._topologyScene?.nodes || []).map((node) => String(node.id)))

    expect(laidOut._layoutMode).toBe("elk-radial-overview")
    expect(memberIds.filter((id) => sceneIds.has(id))).toHaveLength(memberIds.length)
  })

  it("keeps a collapsed graph on the radial overview adapter", async () => {
    const laidOut = await makeContext().prepareGraphLayout(collapsedFarm01Graph(), 1, "collapsed")

    expect(laidOut._layoutMode).toBe("elk-radial-overview")
  })
})
