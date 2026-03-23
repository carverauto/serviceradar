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

  it("prepareGraphLayout computes ELK client layout and updates state", async () => {
    const context = makeContext()
    const graph = {nodes: [{id: "a"}, {id: "b"}], edges: [{source: 0, target: 1}]}

    const out = await context.prepareGraphLayout(graph, 5, "stamp")

    expect(out._layoutMode).toEqual("elk-client")
    expect(out._layoutRevision).toEqual(5)
    expect(out._layoutCacheKey).toEqual("5:stamp:collapsed")
    expect(context.state.layoutMode).toEqual("elk-client")
    expect(context.state.layoutRevision).toEqual(5)
    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(1)
    expect(out.nodes[0].x).toEqual(120)
    expect(out.nodes[1].x).toEqual(260)
  })

  it("prepareGraphLayout reuses cached results for the same revision and expansion state", async () => {
    const context = makeContext()
    const graph = {nodes: [{id: "a"}, {id: "b"}], edges: [{source: 0, target: 1}]}

    const first = await context.prepareGraphLayout(graph, 9, "stamp")
    const second = await context.prepareGraphLayout(graph, 9, "stamp")

    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(1)
    expect(second).toBe(first)
  })

  it("prepareGraphLayout fans expanded cluster members away from the anchor", async () => {
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
    const anchor = out.nodes.find((node) => node.id === "cluster-anchor")
    const summary = out.nodes.find((node) => node.id === "cluster-summary")
    const endpoint1 = out.nodes.find((node) => node.id === "endpoint-1")
    const endpoint2 = out.nodes.find((node) => node.id === "endpoint-2")

    expect(summary.x).toBeGreaterThan(anchor.x)
    expect(endpoint1.x).toBeGreaterThan(summary.x)
    expect(endpoint2.x).toBeGreaterThan(summary.x)
    expect(endpoint1.y).not.toEqual(endpoint2.y)
    expect(endpoint1.x).not.toEqual(endpoint2.x)
    expect(context.state.layoutEngine.layout).toHaveBeenCalledWith(expect.objectContaining({
      children: expect.arrayContaining([
        expect.objectContaining({id: "switch-1"}),
        expect.objectContaining({id: "cluster-anchor"}),
      ]),
      edges: [
        expect.objectContaining({
          sources: ["switch-1"],
          targets: ["cluster-anchor"],
        }),
      ],
    }))
  })

  it("prepareGraphLayout ignores endpoint attachment edges when choosing cluster direction", async () => {
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
      ],
      edges: [
        {source: 1, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 2, target: 3, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "lldp"},
      ],
    }

    const out = await context.prepareGraphLayout(graph, 14, "stamp")
    const anchor = out.nodes.find((node) => node.id === "cluster-anchor")
    const summary = out.nodes.find((node) => node.id === "cluster-summary")

    expect(summary.x).toBeGreaterThan(anchor.x)
    expect(Math.abs(summary.y - anchor.y)).toBeLessThan(40)
  })

  it("prepareGraphLayout projects collapsed cluster summaries after ELK backbone layout", async () => {
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
        {source: 0, target: 1, topologyClass: "backbone", evidenceClass: "lldp"},
        {source: 1, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
      ],
    }

    const out = await context.prepareGraphLayout(graph, 13, "stamp")
    const anchor = out.nodes.find((node) => node.id === "cluster-anchor")
    const summary = out.nodes.find((node) => node.id === "cluster-summary")

    expect(summary.x).toBeGreaterThan(anchor.x)
    expect(Math.abs(summary.y - anchor.y)).toBeLessThan(40)
  })

  it("prepareGraphLayout keeps expanded members in front of the summary hub for larger clusters", async () => {
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
            ],
          })),
        },
        lastGraph: null,
        lastTopologyStamp: null,
        lastRevision: null,
      },
    })

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
    }

    const out = await context.prepareGraphLayout(graph, 15, "stamp")
    const summary = out.nodes.find((node) => node.id === "cluster-summary")
    const members = out.nodes.filter((node) => node.id.startsWith("endpoint-"))

    expect(members.length).toEqual(12)
    expect(members.every((node) => node.x > summary.x)).toEqual(true)
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
