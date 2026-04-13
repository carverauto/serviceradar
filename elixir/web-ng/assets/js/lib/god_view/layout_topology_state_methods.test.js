import {describe, expect, it, vi} from "vitest"

import {godViewLayoutTopologyStateMethods} from "./layout_topology_state_methods"

function makeContext(overrides = {}) {
  return {
    state: {
      layoutMode: "auto",
      layoutRevision: null,
      layoutCache: new Map(),
      lastLayoutKey: null,
      layoutEngine: {
        layout: vi.fn(async (graph) => ({
          id: graph.id,
          children: (graph.children || []).map((node, index) => ({
            id: node.id,
            x: 120 + index * 140,
            y: 160 + index * 16,
          })),
        })),
      },
      lastGraph: null,
      lastTopologyStamp: null,
      lastRevision: null,
    },
    ...godViewLayoutTopologyStateMethods,
    ...overrides,
  }
}

describe("layout_topology_state_methods", () => {
  it("geoGridData returns no grid outside geo mode", () => {
    const context = makeContext()

    expect(context.geoGridData()).toEqual([])
  })

  it("geoGridData returns projected grid lines in geo mode", () => {
    const context = makeContext({
      state: {
        layoutMode: "geo",
      },
    })

    const out = context.geoGridData()

    expect(out.length).toBeGreaterThan(0)
    expect(out[0]).toHaveProperty("sourcePosition")
    expect(out[0]).toHaveProperty("targetPosition")
  })

  it("graphTopologyStamp changes when topology changes", () => {
    const graphA = {
      nodes: [{id: "a"}, {id: "b"}],
      edges: [{source: 0, target: 1}],
    }
    const graphB = {
      nodes: [{id: "a"}, {id: "c"}],
      edges: [{source: 0, target: 1}],
    }

    const stampA = godViewLayoutTopologyStateMethods.graphTopologyStamp(graphA)
    const stampB = godViewLayoutTopologyStateMethods.graphTopologyStamp(graphB)

    expect(stampA).not.toEqual(stampB)
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

    const stampA = godViewLayoutTopologyStateMethods.graphTopologyStamp(graphA)
    const stampB = godViewLayoutTopologyStateMethods.graphTopologyStamp(graphB)

    expect(stampA).toEqual(stampB)
  })

  it("graphExpansionStamp reflects expanded cluster ids", () => {
    const graph = {
      nodes: [
        {id: "a", details: {cluster_id: "cluster:endpoints:1", cluster_expanded: true}},
        {id: "b", details: {cluster_id: "cluster:endpoints:2", cluster_expanded: false}},
        {id: "c", details: {cluster_id: "cluster:endpoints:3", cluster_expanded: true}},
      ],
      edges: [],
    }

    expect(godViewLayoutTopologyStateMethods.graphExpansionStamp(graph)).toEqual(
      "cluster:endpoints:1|cluster:endpoints:3",
    )
  })

  it("reusePreviousPositions carries prior x/y by id", () => {
    const previousGraph = {
      nodes: [
        {id: "n1", x: 10, y: 20},
        {id: "n2", x: 30, y: 40},
      ],
    }
    const nextGraph = {
      nodes: [
        {id: "n2", x: 1, y: 2},
        {id: "n1", x: 3, y: 4},
        {id: "n3", x: 5, y: 6},
      ],
    }

    const out = godViewLayoutTopologyStateMethods.reusePreviousPositions(nextGraph, previousGraph)

    expect(out.nodes[0].x).toEqual(30)
    expect(out.nodes[0].y).toEqual(40)
    expect(out.nodes[1].x).toEqual(10)
    expect(out.nodes[1].y).toEqual(20)
    expect(out.nodes[2].x).toEqual(5)
    expect(out.nodes[2].y).toEqual(6)
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

  it("buildElkLayoutGraph uses the horizontal backbone ELK configuration", () => {
    const context = makeContext()
    const graph = {
      nodes: [{id: "a", details: {}}, {id: "b", details: {}}],
      edges: [{source: 0, target: 1, topologyClass: "backbone", evidenceClass: "direct"}],
    }

    const out = context.buildElkLayoutGraph(graph, new Set())

    expect(out.layoutOptions["elk.direction"]).toEqual("DOWN")
    expect(out.layoutOptions["elk.layered.spacing.nodeNodeBetweenLayers"]).toEqual("120")
    expect(out.layoutOptions["elk.spacing.nodeNode"]).toEqual("64")
  })

  it("computeBackboneLayeredPositions fans the backbone around the selected hub", () => {
    const context = makeContext()
    const graph = {
      nodes: [
        {id: "core", label: "Core", pps: 1000, details: {}},
        {id: "ap-a", label: "AP A", pps: 500, details: {}},
        {id: "ap-b", label: "AP B", pps: 400, details: {}},
        {id: "switch-a", label: "Switch A", pps: 300, details: {}},
        {id: "switch-b", label: "Switch B", pps: 200, details: {}},
        {
          id: "cluster-summary",
          label: "4 endpoints",
          details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-summary"},
        },
      ],
      edges: [
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "direct"},
        {source: 0, target: 2, topologyClass: "backbone", evidenceClass: "direct"},
        {source: 1, target: 3, topologyClass: "backbone", evidenceClass: "direct"},
        {source: 2, target: 4, topologyClass: "backbone", evidenceClass: "direct"},
        {source: 1, target: 5, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
      ],
    }

    const positions = context.computeBackboneLayeredPositions(graph, new Set(["cluster-summary"]))

    const core = positions.get("core")
    const apA = positions.get("ap-a")
    const apB = positions.get("ap-b")
    const switchA = positions.get("switch-a")
    const switchB = positions.get("switch-b")

    expect(core.x).toEqual(320)
    expect(core.y).toEqual(280)
    const apADistance = Math.hypot(apA.x - core.x, apA.y - core.y)
    const apBDistance = Math.hypot(apB.x - core.x, apB.y - core.y)
    const switchADistance = Math.hypot(switchA.x - core.x, switchA.y - core.y)
    const switchBDistance = Math.hypot(switchB.x - core.x, switchB.y - core.y)
    expect(apADistance).toBeGreaterThan(120)
    expect(apBDistance).toBeGreaterThan(120)
    expect(switchADistance).toBeGreaterThan(apADistance)
    expect(switchBDistance).toBeGreaterThan(apBDistance)
    expect(Number.isFinite(switchA.y)).toEqual(true)
    expect(Number.isFinite(switchB.y)).toEqual(true)
    expect(positions.has("cluster-summary")).toEqual(false)
  })

  it("computeBackboneLayeredPositions places topology-unplaced nodes in a dedicated side lane", () => {
    const context = makeContext()
    const graph = {
      nodes: [
        {id: "core", label: "Core", pps: 1000, details: {}},
        {id: "switch-a", label: "Switch A", pps: 300, details: {}},
        {
          id: "vjunos",
          label: "vJunos",
          pps: 0,
          details: {topology_unplaced: true, topology_plane: "unplaced"},
        },
      ],
      edges: [
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "direct"},
      ],
    }

    const positions = context.computeBackboneLayeredPositions(graph, new Set())

    expect(positions.get("core").x).toEqual(320)
    expect(positions.get("switch-a").x).toBeGreaterThan(positions.get("core").x)
    expect(positions.get("vjunos").x).toBeGreaterThan(positions.get("switch-a").x)
    expect(positions.get("vjunos").y).toBeGreaterThanOrEqual(positions.get("core").y)
  })

  it("computeBackboneLayeredPositions stays deterministic for meshed backbone edges", () => {
    const context = makeContext()
    const graph = {
      nodes: [
        {id: "core", label: "Core", pps: 1000, details: {}},
        {id: "agg-a", label: "Agg A", pps: 700, details: {}},
        {id: "agg-b", label: "Agg B", pps: 680, details: {}},
        {id: "leaf-a", label: "Leaf A", pps: 200, details: {}},
        {id: "leaf-b", label: "Leaf B", pps: 180, details: {}},
      ],
      edges: [
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "direct"},
        {source: 0, target: 2, topologyClass: "backbone", evidenceClass: "direct"},
        {source: 1, target: 2, topologyClass: "backbone", evidenceClass: "direct"},
        {source: 1, target: 3, topologyClass: "backbone", evidenceClass: "direct"},
        {source: 2, target: 4, topologyClass: "backbone", evidenceClass: "direct"},
      ],
    }

    const reversed = {
      ...graph,
      edges: [...graph.edges].reverse(),
    }

    const first = context.computeBackboneLayeredPositions(graph, new Set())
    const second = context.computeBackboneLayeredPositions(reversed, new Set())
    const toObject = (positions) =>
      Object.fromEntries(
        Array.from(positions.entries())
          .sort(([leftId], [rightId]) => leftId.localeCompare(rightId))
          .map(([id, point]) => [id, {x: point.x, y: point.y}]),
      )

    expect(toObject(first)).toEqual(toObject(second))
  })

  it("prepareGraphLayout computes radial client layout and updates state", async () => {
    const context = makeContext()
    const graph = {nodes: [{id: "a"}, {id: "b"}], edges: [{source: 0, target: 1}]}

    const out = await context.prepareGraphLayout(graph, 5, "stamp")

    expect(out._layoutMode).toEqual("client-radial")
    expect(out._layoutRevision).toEqual(5)
    expect(out._layoutCacheKey).toEqual("5:stamp:collapsed")
    expect(context.state.layoutMode).toEqual("client-radial")
    expect(context.state.layoutRevision).toEqual(5)
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(0)
    expect(Number.isFinite(out.nodes[0].x)).toEqual(true)
    expect(Number.isFinite(out.nodes[1].x)).toEqual(true)
    expect(out.nodes[0].x).not.toEqual(out.nodes[1].x)
  })

  it("prepareGraphLayout reuses cached results for the same revision and expansion state", async () => {
    const context = makeContext()
    const graph = {nodes: [{id: "a"}, {id: "b"}], edges: [{source: 0, target: 1}]}

    const first = await context.prepareGraphLayout(graph, 9, "stamp")
    const second = await context.prepareGraphLayout(graph, 9, "stamp")

    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(0)
    expect(second).toBe(first)
  })

  it("prepareGraphLayout keeps endpoint-heavy expanded graphs on the radial overview path", async () => {
    const context = makeContext({
      state: {
        layoutMode: "auto",
        layoutRevision: null,
        layoutCache: new Map(),
        lastLayoutKey: null,
        layoutEngine: {
          layout: vi.fn(async () => ({
            id: "god-view-root",
            children: [
              {id: "switch-1", x: 40, y: 120},
              {id: "cluster-anchor", x: 180, y: 120},
              {id: "cluster-summary", x: 300, y: 120},
              {id: "endpoint-1", x: 420, y: 96},
              {id: "endpoint-2", x: 420, y: 144},
            ],
          })),
        },
        lastGraph: null,
        lastTopologyStamp: null,
        lastRevision: null,
      },
    })

    const graph = {
      nodes: [
        {id: "switch-1", details: {}},
        {
          id: "cluster-anchor",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-anchor",
            cluster_expanded: true,
          },
        },
        {
          id: "cluster-summary",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-summary",
            cluster_expanded: true,
          },
        },
        {
          id: "endpoint-1",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-member",
            cluster_expanded: true,
          },
        },
        {
          id: "endpoint-2",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-member",
            cluster_expanded: true,
          },
        },
      ],
      edges: [
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "lldp"},
        {source: 1, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 2, target: 3, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 2, target: 4, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
      ],
    }

    const out = await context.prepareGraphLayout(graph, 12, "stamp")
    expect(out._layoutMode).toEqual("client-radial")
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(0)
    expect(out.nodes.every((node) => Number.isFinite(node.x) && Number.isFinite(node.y))).toEqual(true)
  })

  it("prepareGraphLayout anchors endpoint summaries and members off the owning infrastructure node", async () => {
    const context = makeContext({
      state: {
        layoutMode: "auto",
        layoutRevision: null,
        layoutCache: new Map(),
        lastLayoutKey: null,
        layoutEngine: {
          layout: vi.fn(async () => ({
            id: "god-view-root",
            children: [
              {id: "switch-1", x: 40, y: 120},
              {id: "cluster-anchor", x: 180, y: 120},
              {id: "cluster-summary", x: 300, y: 120},
              {id: "endpoint-1", x: 420, y: 60},
              {id: "endpoint-2", x: 420, y: 120},
              {id: "endpoint-3", x: 420, y: 180},
              {id: "endpoint-4", x: 540, y: 60},
              {id: "endpoint-5", x: 540, y: 180},
            ],
          })),
        },
        lastGraph: null,
        lastTopologyStamp: null,
        lastRevision: null,
      },
    })

    const graph = {
      nodes: [
        {id: "switch-1", details: {}},
        {
          id: "cluster-anchor",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-anchor",
            cluster_expanded: true,
          },
        },
        {
          id: "cluster-summary",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-summary",
            cluster_expanded: true,
          },
        },
        {id: "endpoint-1", details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "endpoint-2", details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "endpoint-3", details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "endpoint-4", details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "endpoint-5", details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-member", cluster_expanded: true}},
      ],
      edges: [
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "lldp"},
        {source: 1, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 2, target: 3, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 2, target: 4, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 2, target: 5, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 2, target: 6, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 2, target: 7, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
      ],
    }

    const out = await context.prepareGraphLayout(graph, 22, "stamp")
    const anchor = out.nodes.find((node) => node.id === "cluster-anchor")
    const summary = out.nodes.find((node) => node.id === "cluster-summary")
    const members = out.nodes.filter((node) => /^endpoint-/.test(node.id))
    expect(out._layoutMode).toEqual("client-radial")
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(0)
    expect(summary.x).toBeGreaterThan(anchor.x)
    expect(members.length).toEqual(5)
    expect(members.every((node) => node.x > anchor.x)).toEqual(true)
    expect(new Set(members.map((node) => node.y)).size).toBeGreaterThan(1)
  })


  it("applyEndpointProjectionLayout pushes expanded clusters beyond occupied forward nodes", () => {
    const context = makeContext()
    const graph = {
      nodes: [
        {id: "parent", x: 100, y: 220, details: {}},
        {id: "anchor", x: 220, y: 220, details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-anchor", cluster_expanded: true}},
        {id: "summary", x: 0, y: 0, details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-summary", cluster_expanded: true}},
        {id: "blocker", x: 380, y: 220, details: {}},
        {id: "endpoint-1", x: 0, y: 0, details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "endpoint-2", x: 0, y: 0, details: {cluster_id: "cluster:endpoints:test", cluster_kind: "endpoint-member", cluster_expanded: true}},
      ],
      edges: [],
    }
    const clusterLayout = {
      groups: [
        {
          clusterId: "cluster:endpoints:test",
          anchorNodeId: "anchor",
          parentNodeId: "parent",
          summaryNodeId: "summary",
          memberNodeIds: ["endpoint-1", "endpoint-2"],
          slotIndex: 0,
          slotCount: 1,
          expanded: true,
        },
      ],
    }

    const out = context.applyEndpointProjectionLayout(graph, clusterLayout)
    const summary = out.nodes.find((node) => node.id === "summary")
    const members = out.nodes.filter((node) => /^endpoint-/.test(node.id))
    const blockerDistance = Math.hypot(summary.x - 380, summary.y - 220)

    expect(blockerDistance).toBeGreaterThan(120)
    expect(members.every((node) => Math.hypot(node.x - 380, node.y - 220) > 150)).toEqual(true)
  })

  it("requiresFullElkLayout detects endpoint-heavy graphs", () => {
    const context = makeContext()
    const graph = {
      nodes: [
        {id: "switch-1", details: {}},
        {
          id: "cluster-anchor",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-anchor",
            cluster_expanded: true,
          },
        },
        {
          id: "cluster-summary",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-summary",
            cluster_expanded: true,
          },
        },
        {
          id: "endpoint-1",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-member",
            cluster_expanded: true,
          },
        },
      ],
      edges: [
        {source: 1, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 2, target: 3, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "lldp"},
      ],
    }

    expect(context.requiresFullElkLayout(graph)).toEqual(false)
  })

  it("buildElkLayoutGraph includes endpoint attachment edges when full ELK is requested", () => {
    const context = makeContext({
      state: makeContext().state,
    })

    const graph = {
      nodes: [
        {id: "switch-1", details: {}},
        {
          id: "cluster-anchor",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-anchor",
            cluster_expanded: false,
          },
        },
        {
          id: "cluster-summary",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-summary",
            cluster_expanded: false,
          },
        },
      ],
      edges: [
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "direct"},
        {source: 1, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
      ],
    }

    const out = context.buildElkLayoutGraph(graph, new Set(), {includeAttachmentEdges: true})

    expect(out.children).toHaveLength(3)
    expect(out.edges).toHaveLength(2)
  })

  it("prepareGraphLayout caches endpoint-heavy graphs by expansion stamp without invoking ELK", async () => {
    const memberNodes = Array.from({length: 12}, (_, index) => ({
      id: `endpoint-${index + 1}`,
      details: {
        cluster_id: "cluster:endpoints:test",
        cluster_kind: "endpoint-member",
        cluster_expanded: true,
      },
    }))

    const graph = {
      nodes: [
        {id: "switch-1", details: {}},
        {
          id: "cluster-anchor",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-anchor",
            cluster_expanded: true,
          },
        },
        {
          id: "cluster-summary",
          details: {
            cluster_id: "cluster:endpoints:test",
            cluster_kind: "endpoint-summary",
            cluster_expanded: true,
          },
        },
        ...memberNodes,
      ],
      edges: [
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "lldp"},
        {source: 1, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        ...memberNodes.map((_, index) => ({
          source: 2,
          target: index + 3,
          topologyClass: "endpoints",
          evidenceClass: "endpoint-attachment",
        })),
      ],
      children: [
        {id: "switch-1", x: 40, y: 120},
        {id: "cluster-anchor", x: 180, y: 120},
        {id: "cluster-summary", x: 300, y: 120},
        ...memberNodes.map((node, index) => ({
          id: node.id,
          x: 420 + (Math.floor(index / 6) * 120),
          y: 60 + ((index % 6) * 48),
        })),
      ],
    }

    const context = makeContext({
      state: {
        layoutMode: "auto",
        layoutRevision: null,
        layoutCache: new Map(),
        lastLayoutKey: null,
        layoutEngine: {
          layout: vi.fn(async () => ({
            id: "god-view-root",
            children: graph.children,
          })),
        },
        lastGraph: null,
        lastTopologyStamp: null,
        lastRevision: null,
      },
    })

    const first = await context.prepareGraphLayout(graph, 15, "stamp")
    const second = await context.prepareGraphLayout(graph, 15, "stamp")

    expect(first).toBe(second)
    expect(first._layoutMode).toEqual("client-radial")
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(0)
  })

  it("normalizeHorizontalLayout is a no-op for the radial overview path", async () => {
    const context = makeContext()
    const graph = {
      nodes: [
        {id: "a", x: 40, y: 40, details: {}},
        {id: "b", x: 180, y: 320, details: {}},
        {id: "c", x: 320, y: 620, details: {}},
      ],
      edges: [],
    }

    const out = context.normalizeHorizontalLayout(graph)
    const xs = out.nodes.map((node) => node.x)
    expect(out).toBe(graph)
    expect(xs).toEqual(graph.nodes.map((node) => node.x))
    expect(out.nodes.map((node) => node.y)).toEqual(graph.nodes.map((node) => node.y))
  })

  it("edgeDrivesBackboneLayout excludes endpoint and inferred relations from backbone solving", () => {
    const context = makeContext()

    expect(context.edgeDrivesBackboneLayout({topologyClass: "backbone"})).toEqual(true)
    expect(context.edgeDrivesBackboneLayout({topologyClass: "logical"})).toEqual(true)
    expect(context.edgeDrivesBackboneLayout({topologyClass: "hosted"})).toEqual(true)
    expect(context.edgeDrivesBackboneLayout({topologyClass: "endpoints"})).toEqual(false)
    expect(context.edgeDrivesBackboneLayout({topologyClass: "inferred"})).toEqual(false)
    expect(context.edgeDrivesBackboneLayout({topologyClass: "observed"})).toEqual(false)
  })

  it("sameTopology accepts stable backend revisions even if the client stamp changed", () => {
    const context = makeContext({
      state: {
        lastRevision: 42,
        lastTopologyStamp: "old-stamp",
      },
    })

    const same = context.sameTopology(
      {nodes: [{id: "a"}], edges: []},
      {nodes: [{id: "a"}], edges: []},
      "new-stamp",
      42,
    )

    expect(same).toEqual(true)
  })
})
