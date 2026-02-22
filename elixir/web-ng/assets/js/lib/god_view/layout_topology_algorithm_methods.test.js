import {describe, expect, it} from "vitest"

import {godViewLayoutTopologyAlgorithmMethods} from "./layout_topology_algorithm_methods"

describe("layout_topology_algorithm_methods", () => {
  it("projectGeoLayout maps geo nodes and provides deterministic fallback positions", () => {
    const graph = {
      nodes: [
        {id: "geo", geoLat: 37.7749, geoLon: -122.4194},
        {id: "fallback-1"},
        {id: "fallback-2", geoLat: NaN, geoLon: NaN},
      ],
      edges: [],
    }

    const out = godViewLayoutTopologyAlgorithmMethods.projectGeoLayout(graph)

    expect(out.nodes).toHaveLength(3)
    for (const node of out.nodes) {
      expect(Number.isFinite(node.x)).toEqual(true)
      expect(Number.isFinite(node.y)).toEqual(true)
      expect(node.x).toBeGreaterThanOrEqual(0)
      expect(node.x).toBeLessThanOrEqual(640)
      expect(node.y).toBeGreaterThanOrEqual(0)
      expect(node.y).toBeLessThanOrEqual(320)
    }

    expect(out.nodes[1].x).not.toEqual(out.nodes[2].x)
    expect(out.nodes[1].y).not.toEqual(out.nodes[2].y)
  })

  it("forceDirectedLayout keeps small graphs unchanged by simulation path", () => {
    const graph = {
      nodes: [
        {id: "a", x: 1, y: 2},
        {id: "b", x: 3, y: 4},
      ],
      edges: [{source: 0, target: 1}],
    }

    const out = godViewLayoutTopologyAlgorithmMethods.forceDirectedLayout(graph)

    expect(out.nodes).toHaveLength(2)
    expect(out.nodes[0].x).toEqual(1)
    expect(out.nodes[0].y).toEqual(2)
    expect(out.nodes[1].x).toEqual(3)
    expect(out.nodes[1].y).toEqual(4)
  })

  it("forceDirectedLayout projects simulated nodes into layout bounds", () => {
    const graph = {
      nodes: [
        {id: "a"},
        {id: "b"},
        {id: "c"},
        {id: "d"},
      ],
      edges: [
        {source: 0, target: 1, weight: 1},
        {source: 1, target: 2, weight: 2},
        {source: 2, target: 3, weight: 3},
      ],
    }

    const out = godViewLayoutTopologyAlgorithmMethods.forceDirectedLayout(graph)

    expect(out.nodes).toHaveLength(4)
    for (const node of out.nodes) {
      expect(Number.isFinite(node.x)).toEqual(true)
      expect(Number.isFinite(node.y)).toEqual(true)
      expect(node.x).toBeGreaterThanOrEqual(20)
      expect(node.x).toBeLessThanOrEqual(620)
      expect(node.y).toBeGreaterThanOrEqual(20)
      expect(node.y).toBeLessThanOrEqual(300)
    }
  })

  it("geoGridData returns lines only in geo mode", () => {
    const ctxGeo = {
      ...godViewLayoutTopologyAlgorithmMethods,
      layoutMode: "geo",
    }
    const ctxForce = {
      ...godViewLayoutTopologyAlgorithmMethods,
      layoutMode: "force",
    }

    const geoLines = ctxGeo.geoGridData()
    const noLines = ctxForce.geoGridData()

    expect(geoLines.length).toBeGreaterThan(0)
    expect(noLines).toEqual([])
    expect(geoLines[0].sourcePosition).toHaveLength(3)
    expect(geoLines[0].targetPosition).toHaveLength(3)
  })
})
