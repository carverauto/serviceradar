import ELK from "elkjs/lib/elk.bundled.js"
import {describe, expect, it, vi} from "vitest"

import {
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

describe("layout_topology_state_methods", () => {
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

  it("dedupeGraphById removes duplicate nodes and remaps edges", () => {
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
    expect(out.edges).toHaveLength(1)
    expect(out.nodes[0].details.cluster_expanded).toEqual(true)
    expect(out.edges[0]).toMatchObject({source: 0, target: 1})
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

  it("uses one ELK scene as the geometry authority for both farm01 fixture states", async () => {
    for (const graph of [collapsedFarm01Graph(), expandedFarm01Graph()]) {
      const context = makeContext()

      const out = await context.prepareGraphLayout(graph, 5, "stamp")

      expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(1)
      expect(out._layoutMode).toEqual("elk-scene")
      expect(out._topologyScene.routes).toHaveLength(32)
      expect(out.nodes.every((node) => Number.isFinite(node.x) && Number.isFinite(node.y))).toEqual(true)
      expect(context.state.layoutMode).toEqual("elk-scene")
    }
  })

  it("can prepare a layout without mutating accepted layout metadata", async () => {
    const context = makeContext({state: {
      layoutMode: "elk-scene",
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
    expect(context.state.layoutMode).toBe("elk-scene")
    expect(context.state.layoutRevision).toBe(40)
    expect(context.state.lastLayoutKey).toBe("accepted-layout")
  })

  it("contains all 24 expanded members in one accepted compound group", async () => {
    const context = makeContext()

    const out = await context.prepareGraphLayout(expandedFarm01Graph(), 6, "expanded")
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
    const graph = collapsedFarm01Graph()
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
    expect(second._topologyScene).toBe(first._topologyScene)
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
    expect(context.state.layoutCache.get(first._layoutCacheKey)).toBe(first._topologyScene)
    expect(Object.isFrozen(first._topologyScene)).toEqual(true)
    expect(Object.isFrozen(first._topologyScene.nodes)).toEqual(true)
    expect(Object.isFrozen(first._topologyScene.nodes[0].center)).toEqual(true)
    expect(Object.isFrozen(first._topologyScene.routes[0].points)).toEqual(true)
  })

  it("keeps the cache stable within a viewport profile and invalidates across the profile threshold", async () => {
    const context = makeContext()
    const graph = collapsedFarm01Graph()
    const first = await context.prepareGraphLayout(graph, 10, "stamp")
    context.state.viewportWidth = 1600
    context.state.viewportHeight = 1000

    const sameProfile = await context.prepareGraphLayout(graph, 10, "stamp")
    context.state.viewportWidth = 800
    context.state.viewportHeight = 1000
    const portrait = await context.prepareGraphLayout(graph, 10, "stamp")

    expect(sameProfile).not.toBe(first)
    expect(sameProfile._topologyScene).toBe(first._topologyScene)
    expect(portrait._topologyScene).not.toBe(first._topologyScene)
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(2)
    expect(first._topologyScene.profileKey).toEqual("landscape")
    expect(portrait._topologyScene.profileKey).toEqual("portrait")
  })

  it("includes structural graph identity in the cache key", async () => {
    const context = makeContext()
    const collapsed = await context.prepareGraphLayout(collapsedFarm01Graph(), 11, "same-stamp")
    const expanded = await context.prepareGraphLayout(expandedFarm01Graph(), 11, "same-stamp")

    expect(collapsed._layoutCacheKey).not.toEqual(expanded._layoutCacheKey)
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(2)
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
      ...collapsedFarm01Graph(),
      nodes: collapsedFarm01Graph().nodes.map((node) => ({...node, x: 10, y: 20})),
      _topologyScene: {key: "stale-scene"},
      _layoutMode: "elk-scene",
      _layoutCacheKey: "stale-key",
      _layoutRevision: 1,
      _layoutError: "stale error",
    }

    const out = await context.prepareGraphLayout(graph, 15, "new-stamp")

    expect(out._topologyScene).toBeUndefined()
    expect(out._layoutMode).toEqual("elk-scene-error")
    expect(out._layoutCacheKey).not.toEqual("stale-key")
    expect(out._layoutRevision).toEqual(15)
    expect(out._layoutError).toEqual("new ELK failure")
    expect(out.nodes.every((node) => node.x === undefined && node.y === undefined)).toEqual(true)
  })

  it("reuses only a structurally and profile-compatible last-good scene after ELK failure", async () => {
    const context = makeContext()
    const graph = expandedFarm01Graph()
    const accepted = await context.prepareGraphLayout(graph, 14, "stamp")
    context.state.lastGraph = accepted
    context.state.layoutCache.clear()
    context.state.layoutEngine = {
      layout: vi.fn(async () => { throw new Error("transient ELK failure") }),
    }

    const reused = await context.prepareGraphLayout(graph, 15, "new-stamp")

    expect(reused._topologyScene).toBe(accepted._topologyScene)
    expect(reused._layoutMode).toEqual("elk-scene")
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

    const incompatibleExpansion = await context.prepareGraphLayout(collapsedFarm01Graph(), 15, "new-stamp")
    expect(incompatibleExpansion._topologyScene).toBeUndefined()
    expect(incompatibleExpansion.nodes.every((node) => node.x === undefined && node.y === undefined)).toEqual(true)

    context.state.viewportWidth = 800
    context.state.viewportHeight = 1000
    const incompatibleProfile = await context.prepareGraphLayout(graph, 15, "new-stamp")
    expect(incompatibleProfile._topologyScene).toBeUndefined()
    expect(incompatibleProfile.nodes.every((node) => node.x === undefined && node.y === undefined)).toEqual(true)
  })

  it("reapplies a compatible last-good scene without replacing current graph data", async () => {
    const context = makeContext()
    const graph = collapsedFarm01Graph()
    const accepted = await context.prepareGraphLayout(graph, 16, "stamp")
    context.state.lastGraph = accepted
    context.state.layoutCache.clear()
    context.state.layoutEngine = {
      layout: vi.fn(async () => { throw new Error("transient ELK failure") }),
    }
    const currentGraph = {
      ...graph,
      nodes: graph.nodes.map((node, index) => index === 0
        ? {...node, label: "Current gateway label", state: 3, pps: 9876}
        : node),
      edges: graph.edges.map((edge, index) => index === 0
        ? {...edge, metadata: {sample: "current"}, pps: 4321}
        : edge),
    }

    const reused = await context.prepareGraphLayout(currentGraph, 17, "telemetry-only-stamp")

    expect(reused.nodes[0]).toMatchObject({
      label: "Current gateway label",
      state: 3,
      pps: 9876,
    })
    expect(reused.edges[0]).toMatchObject({metadata: {sample: "current"}, pps: 4321})
    expect(reused.nodes[0].x).toEqual(accepted.nodes[0].x)
    expect(reused.nodes[0].y).toEqual(accepted.nodes[0].y)
    expect(reused._topologyScene).toBe(accepted._topologyScene)
    expect(reused._layoutRevision).toEqual(17)
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
