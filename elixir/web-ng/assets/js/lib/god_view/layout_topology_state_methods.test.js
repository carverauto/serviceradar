import {describe, expect, it} from "vitest"

import {godViewLayoutTopologyStateMethods} from "./layout_topology_state_methods"

describe("layout_topology_state_methods", () => {
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

  it("shouldUseGeoLayout requires enough geo coverage", () => {
    const mostlyGeo = {
      nodes: [
        {geoLat: 1, geoLon: 1},
        {geoLat: 2, geoLon: 2},
        {geoLat: 3, geoLon: 3},
        {geoLat: 4, geoLon: 4},
        {geoLat: 5, geoLon: 5},
        {geoLat: 6, geoLon: 6},
      ],
    }
    const sparseGeo = {
      nodes: [
        {geoLat: 1, geoLon: 1},
        {},
        {},
        {},
        {},
        {},
      ],
    }

    expect(godViewLayoutTopologyStateMethods.shouldUseGeoLayout(mostlyGeo)).toEqual(true)
    expect(godViewLayoutTopologyStateMethods.shouldUseGeoLayout(sparseGeo)).toEqual(false)
  })

  it("prepareGraphLayout chooses layout path and updates revision/mode", () => {
    const graph = {nodes: [{id: "a"}, {id: "b"}], edges: [{source: 0, target: 1}]}
    const context = {
      state: {
        layoutMode: "auto",
        layoutRevision: null,
        lastGraph: null,
        lastTopologyStamp: null,
      },
      ...godViewLayoutTopologyStateMethods,
    }

    const out = context.prepareGraphLayout(graph, 5, "stamp")

    expect(out._layoutMode).toEqual("server")
    expect(out._layoutRevision).toEqual(5)
    expect(context.state.layoutMode).toEqual("server")
    expect(context.state.layoutRevision).toEqual(5)
  })

  it("prepareGraphLayout preserves backend coordinates without client-side layout", () => {
    const graph = {
      nodes: [
        {id: "a", x: 100, y: 200},
        {id: "b", x: 400, y: 500},
      ],
      edges: [{source: 0, target: 1}],
    }
    const context = {
      state: {
        layoutMode: "auto",
        layoutRevision: null,
        lastGraph: null,
        lastTopologyStamp: null,
      },
      ...godViewLayoutTopologyStateMethods,
      projectGeoLayout: () => {
        throw new Error("geo layout should not be called")
      },
      forceDirectedLayout: () => {
        throw new Error("force layout should not be called")
      },
    }

    const out = context.prepareGraphLayout(graph, 9, "stamp")

    expect(out._layoutMode).toEqual("server")
    expect(out.nodes[0].x).toEqual(100)
    expect(out.nodes[1].y).toEqual(500)
  })

  it("shouldUseProvidedLayout rejects flat origin-only coordinates", () => {
    const graph = {
      nodes: [
        {id: "a", x: 0, y: 0},
        {id: "b", x: 0, y: 0},
        {id: "c", x: 0, y: 0},
      ],
    }

    expect(godViewLayoutTopologyStateMethods.shouldUseProvidedLayout(graph)).toEqual(false)
  })

  it("sameTopology accepts stable backend revisions even if the client stamp changed", () => {
    const context = {
      state: {
        lastRevision: 42,
        lastTopologyStamp: "old-stamp",
      },
      ...godViewLayoutTopologyStateMethods,
    }

    const same = context.sameTopology(
      {nodes: [{id: "a"}], edges: []},
      {nodes: [{id: "a"}], edges: []},
      "new-stamp",
      42,
    )

    expect(same).toEqual(true)
  })
})
