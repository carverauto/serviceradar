import {describe, expect, it} from "vitest"

import {
  applyTopologyOverviewToGraph,
  buildElkRadialOverviewGraph,
  decodeElkRadialOverview,
  layoutTopologyOverview,
  validateTopologyOverview,
} from "./layout_elk_radial_overview"

function overviewInput() {
  return {
    nodes: [
      {id: "gamma", label: "Gamma", role: "summary", type: "endpoint-summary"},
      {id: "alpha", label: "Alpha", role: "infrastructure", type: "gateway"},
      {id: "beta", label: "Beta", role: "infrastructure", type: "switch"},
    ],
    roots: ["alpha"],
    treeRelations: [
      {id: "beta-gamma", sourceId: "beta", targetId: "gamma", semanticRelationIds: ["wire:2"]},
      {id: "alpha-beta", sourceId: "alpha", targetId: "beta", semanticRelationIds: ["wire:1"]},
    ],
    crossLinks: [{id: "alpha-gamma", sourceId: "alpha", targetId: "gamma", semanticRelationIds: ["wire:3"]}],
    synthetic: {nodeIds: [], relationIds: []},
    graphKey: "literal-overview",
    manifest: {glyphs: 3, treeRelations: 2, crossLinks: 1},
  }
}

function disconnectedOverviewInput() {
  const input = overviewInput()
  return {
    ...input,
    nodes: [
      ...input.nodes,
      {id: "overview:super-root", label: "", role: "synthetic", type: "super-root", synthetic: true, width: 0, height: 0},
    ],
    roots: ["alpha", "gamma"],
    treeRelations: [
      {id: "overview:super-root|alpha", sourceId: "overview:super-root", targetId: "alpha", synthetic: true},
      {id: "overview:super-root|gamma", sourceId: "overview:super-root", targetId: "gamma", synthetic: true},
      {id: "alpha-beta", sourceId: "alpha", targetId: "beta", semanticRelationIds: ["wire:1"]},
    ],
    synthetic: {
      nodeIds: ["overview:super-root"],
      relationIds: ["overview:super-root|alpha", "overview:super-root|gamma"],
    },
  }
}

function elkLayout({includeGamma = true, duplicateAlpha = false, alpha = {x: 0, y: 0}} = {}) {
  return {
    id: "root",
    width: 400,
    height: 400,
    children: [
      {id: "alpha", ...alpha, width: 112, height: 112},
      {id: "beta", x: 200, y: 0, width: 112, height: 112},
      ...(includeGamma ? [{id: "gamma", x: 200, y: 200, width: 112, height: 112}] : []),
      ...(duplicateAlpha ? [{id: "alpha", x: 300, y: 0, width: 112, height: 112}] : []),
    ],
    edges: [
      {id: "alpha-beta", sources: ["alpha"], targets: ["beta"]},
      {id: "beta-gamma", sources: ["beta"], targets: ["gamma"]},
    ],
  }
}

describe("layout_elk_radial_overview", () => {
  it("builds a deterministic Radial forest without cross-link geometry", () => {
    const graph = buildElkRadialOverviewGraph(disconnectedOverviewInput())

    expect(graph.layoutOptions).toMatchObject({
      "elk.algorithm": "radial",
      "org.eclipse.elk.radial.centerOnRoot": "true",
      "org.eclipse.elk.radial.sorter": "ID",
    })
    expect(graph.children.map((node) => node.id)).toEqual(["alpha", "beta", "gamma", "overview:super-root"])
    expect(graph.edges.map((edge) => edge.id)).toEqual([
      "alpha-beta",
      "overview:super-root|alpha",
      "overview:super-root|gamma",
    ])
    expect(graph.edges.map((edge) => edge.id)).not.toContain("alpha-gamma")
    expect(graph.children.filter((node) => node.id !== "overview:super-root")
      .map((node) => node.layoutOptions["org.eclipse.elk.radial.orderId"])).toEqual([0, 1, 2])
    expect(graph.children.filter((node) => node.id === "alpha")).toHaveLength(1)
    expect(graph.children.filter((node) => node.id === "gamma")).toHaveLength(1)
  })

  it("decodes only semantic Radial geometry, clips tree chords, and retains disclosure metadata", () => {
    const scene = decodeElkRadialOverview(elkLayout(), overviewInput())

    expect(scene).toMatchObject({
      groups: [],
      manifolds: [],
      graphKey: "literal-overview",
      profileKey: "radial-overview",
      crossLinks: overviewInput().crossLinks,
      manifest: overviewInput().manifest,
    })
    expect(scene.nodes.map((node) => node.id)).toEqual(["alpha", "beta", "gamma"])
    expect(scene.nodes.every((node) => Number.isFinite(node.center.x) && Number.isFinite(node.center.y))).toEqual(true)
    expect(scene.routes).toEqual([
      expect.objectContaining({
        id: "alpha-beta",
        sourceId: "alpha",
        targetId: "beta",
        relationIds: ["wire:1"],
        points: [{x: 112, y: 56}, {x: 200, y: 56}],
      }),
      expect.objectContaining({
        id: "beta-gamma",
        sourceId: "beta",
        targetId: "gamma",
        relationIds: ["wire:2"],
        points: [{x: 256, y: 112}, {x: 256, y: 200}],
      }),
    ])
    expect(scene.physicalRoutes).toEqual(scene.routes)
    expect(scene.bounds).toEqual({minX: 0, minY: 0, maxX: 312, maxY: 312})
    expect(Object.isFrozen(scene)).toEqual(true)
    expect(Object.isFrozen(scene.nodes)).toEqual(true)
  })

  it("strips ELK-only component joins while retaining their semantic component roots", () => {
    const input = disconnectedOverviewInput()
    const layout = {
      id: "root",
      children: [
        {id: "overview:super-root", x: 0, y: 0, width: 1, height: 1},
        {id: "alpha", x: 100, y: 0, width: 112, height: 112},
        {id: "beta", x: 300, y: 0, width: 112, height: 112},
        {id: "gamma", x: 0, y: 300, width: 112, height: 112},
      ],
      edges: [
        {id: "overview:super-root|alpha", sources: ["overview:super-root"], targets: ["alpha"]},
        {id: "overview:super-root|gamma", sources: ["overview:super-root"], targets: ["gamma"]},
        {id: "alpha-beta", sources: ["alpha"], targets: ["beta"]},
      ],
    }

    const scene = decodeElkRadialOverview(layout, input)

    expect(scene.nodes.map((node) => node.id)).toEqual(["alpha", "beta", "gamma"])
    expect(scene.routes.map((route) => route.id)).toEqual(["alpha-beta"])
    expect(scene.routes.map((route) => route.id)).not.toContain("alpha-gamma")
    expect(validateTopologyOverview(scene, input)).toEqual({ok: true, errors: []})
  })

  it("rejects malformed ELK geometry before the scene is accepted", () => {
    const input = overviewInput()
    expect(() => decodeElkRadialOverview(elkLayout({alpha: {x: undefined, y: 0}}), input)).toThrow("missing finite coordinates for node alpha")
    expect(() => decodeElkRadialOverview({...elkLayout(), edges: [{id: "unknown", sources: ["alpha"], targets: ["beta"]}]}, input)).toThrow("unknown ELK edge unknown")
    expect(() => decodeElkRadialOverview(elkLayout({duplicateAlpha: true}), input)).toThrow("duplicate ELK geometry for semantic node alpha")
    expect(() => decodeElkRadialOverview({...elkLayout(), children: elkLayout().children.map((node) => node.id === "beta" ? {...node, x: Infinity} : node)}, input)).toThrow("missing finite coordinates for node beta")
    expect(() => decodeElkRadialOverview(elkLayout({includeGamma: false}), input)).toThrow("missing geometry for semantic node gamma")
  })

  it("rejects a semantic chord that crosses an unrelated glyph envelope", () => {
    const layout = elkLayout()
    layout.children = layout.children.map((node) => node.id === "gamma" ? {...node, x: 130, y: 0} : node)

    const validation = validateTopologyOverview(decodeElkRadialOverview(layout, overviewInput()), overviewInput())

    expect(validation).toMatchObject({ok: false})
    expect(validation.errors).toContain("route alpha-beta intersects nonincident node gamma")
  })

  it("uses ELK as the only coordinate authority and applies semantic coordinates immutably", async () => {
    const input = overviewInput()
    const graph = {
      nodes: [{id: "gamma", x: 999, y: 999}, {id: "alpha", x: 999, y: 999}, {id: "beta", x: 999, y: 999}],
      edges: [{id: "wire:1", source: 1, target: 2}],
    }
    const elk = {layout: async () => elkLayout()}

    const scene = await layoutTopologyOverview(input, elk)
    const laidOut = applyTopologyOverviewToGraph(graph, scene)

    expect(laidOut).toMatchObject({_layoutMode: "elk-radial-overview", _topologyScene: scene})
    expect(laidOut.nodes).toEqual([
      expect.objectContaining({id: "gamma", x: 256, y: 256}),
      expect.objectContaining({id: "alpha", x: 56, y: 56}),
      expect.objectContaining({id: "beta", x: 256, y: 56}),
    ])
    expect(graph.nodes[0]).toEqual({id: "gamma", x: 999, y: 999})
    expect(Object.isFrozen(graph.edges)).toEqual(false)
  })
})
