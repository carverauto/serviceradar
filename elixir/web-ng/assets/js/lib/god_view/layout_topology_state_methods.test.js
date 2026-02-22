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
      ...godViewLayoutTopologyStateMethods,
      layoutMode: "auto",
      layoutRevision: null,
      lastGraph: null,
      lastTopologyStamp: null,
      shouldUseGeoLayout: () => true,
      projectGeoLayout: (g) => ({...g, nodes: g.nodes.map((n) => ({...n, x: 1, y: 2}))}),
      forceDirectedLayout: () => {
        throw new Error("force layout should not be called")
      },
    }

    const out = context.prepareGraphLayout(graph, 5, "stamp")

    expect(out._layoutMode).toEqual("geo")
    expect(out._layoutRevision).toEqual(5)
    expect(context.layoutMode).toEqual("geo")
    expect(context.layoutRevision).toEqual(5)
  })
})
