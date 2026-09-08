import ELK from "elkjs/lib/elk.bundled.js"
import {describe, expect, it} from "vitest"

import {
  applyTopologyOverviewToGraph,
  buildElkRadialOverviewGraph,
  decodeElkRadialOverview,
  layoutTopologyOverview,
  validateTopologyOverview,
} from "./layout_elk_radial_overview"
import {prepareTopologyOverviewInput} from "./topology_overview_projection"

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

function routeCollisionInput() {
  return {
    nodes: ["a", "b", "c", "d"].map((id) => ({id, label: id, role: "infrastructure", type: "switch"})),
    roots: ["a", "c"],
    treeRelations: [
      {id: "a-b", sourceId: "a", targetId: "b", semanticRelationIds: ["wire:a-b"]},
      {id: "c-d", sourceId: "c", targetId: "d", semanticRelationIds: ["wire:c-d"]},
    ],
    crossLinks: [],
    synthetic: {nodeIds: [], relationIds: []},
    graphKey: "route-collision",
    manifest: {glyphs: 4, treeRelations: 2, crossLinks: 0},
  }
}

function routeCollisionLayout(positions, input = routeCollisionInput()) {
  return {
    id: "root",
    children: input.nodes.map((node) => ({id: node.id, ...positions[node.id], width: 112, height: 112})),
    edges: input.treeRelations.map((relation) => ({
      id: relation.id,
      sources: [relation.sourceId],
      targets: [relation.targetId],
    })),
  }
}

function numericIdOverviewInput() {
  return {
    nodes: [
      {id: "101", label: "Numeric", role: "infrastructure", type: "gateway"},
      {id: "beta", label: "Beta", role: "infrastructure", type: "switch"},
    ],
    roots: ["101"],
    treeRelations: [{id: "101-beta", sourceId: "101", targetId: "beta", semanticRelationIds: ["wire:101-beta"]}],
    crossLinks: [],
    synthetic: {nodeIds: [], relationIds: []},
    graphKey: "numeric-id",
    manifest: {glyphs: 2, treeRelations: 1, crossLinks: 0},
  }
}

function densePollutedRadialGraph(endpointCount = 160) {
  const nodes = [
    {id: "core", details: {type: "Router", device_role: "router", topology_plane: "backbone"}},
    {id: "access", details: {type: "Switch", device_role: "switch_l2", topology_plane: "backbone"}},
    ...Array.from({length: endpointCount}, (_, index) => ({
      id: `attachment-${String(index).padStart(3, "0")}`,
      details: {
        type: "unknown",
        identity_source: "endpoint_attachment_projection",
        topology_plane: "backbone",
      },
    })),
  ]
  return {
    nodes,
    edges: [
      {
        id: "core-access",
        source: 0,
        target: 1,
        topologyClass: "backbone",
        evidenceClass: "direct",
        metadata: {evidence_class: "direct-physical", relation_type: "CONNECTS_TO", topology_plane: "backbone"},
      },
      ...nodes.slice(2).map((node, index) => ({
        id: `access-${node.id}`,
        source: 1,
        target: index + 2,
        topologyClass: "inferred",
        evidenceClass: "inferred",
        metadata: {
          connectivity_forest_bridge: true,
          evidence_class: "inferred",
          relation_type: "INFERRED_TO",
          topology_plane: "backbone",
        },
      })),
    ],
  }
}

function crowdedComponentForestInput() {
  const nodes = Array.from({length: 20}, (_, index) => ({
    id: `node-${String(index).padStart(2, "0")}`,
    label: `Node ${index}`,
    role: index < 2 ? "summary" : "infrastructure",
    type: index < 2 ? "endpoint-summary" : "switch",
  }))
  const semanticPairs = [
    [3, 6], [3, 19], [6, 17], [17, 13],
    [4, 10], [4, 15], [15, 5], [5, 2], [2, 9], [2, 11], [2, 16], [2, 18],
    [12, 7], [12, 8], [12, 14],
    [3, 0], [4, 1],
  ]
  const treeRelations = semanticPairs.map(([source, target], index) => ({
    id: `relation-${String(index).padStart(2, "0")}`,
    sourceId: nodes[source].id,
    targetId: nodes[target].id,
    semanticRelationIds: [`wire-${String(index).padStart(2, "0")}`],
  }))
  const rootIds = [3, 4, 12].map((index) => nodes[index].id)
  const syntheticRelations = rootIds.map((rootId) => ({
    id: `overview:super-root|${rootId}`,
    sourceId: "overview:super-root",
    targetId: rootId,
    synthetic: true,
  }))

  return {
    nodes: [
      ...nodes,
      {id: "overview:super-root", label: "", role: "synthetic", type: "super-root", synthetic: true, width: 0, height: 0},
    ],
    roots: rootIds,
    treeRelations: [...treeRelations, ...syntheticRelations],
    crossLinks: [],
    synthetic: {
      nodeIds: ["overview:super-root"],
      relationIds: syntheticRelations.map((relation) => relation.id),
    },
    graphKey: "crowded-component-forest",
    manifest: {glyphs: nodes.length, treeRelations: treeRelations.length, crossLinks: 0},
  }
}

describe("layout_elk_radial_overview", () => {
  it("builds a deterministic Radial forest without cross-link geometry", () => {
    const graph = buildElkRadialOverviewGraph(disconnectedOverviewInput())

    expect(graph.layoutOptions).toMatchObject({
      "elk.algorithm": "radial",
      "org.eclipse.elk.radial.centerOnRoot": "true",
      "org.eclipse.elk.radial.sorter": "ID",
      "org.eclipse.elk.radial.radius": "224",
      "org.eclipse.elk.radial.compactor": "NONE",
      "org.eclipse.elk.radial.wedgeCriteria": "LEAF_NUMBER",
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
    expect(graph.children.find((node) => node.id === "overview:super-root")).toMatchObject({width: 0, height: 0})
  })

  it("passes the zero-size ELK-only component root to the real Radial algorithm", async () => {
    const layout = await new ELK().layout(buildElkRadialOverviewGraph(disconnectedOverviewInput()))

    expect(layout.children.map((node) => node.id)).toContain("overview:super-root")
  })

  it("lays out a crowded multi-component transport forest without semantic geometry conflicts", async () => {
    const input = crowdedComponentForestInput()
    const scene = await layoutTopologyOverview(input, new ELK())

    expect(scene.nodes).toHaveLength(20)
    expect(scene.routes).toHaveLength(17)
    expect(validateTopologyOverview(scene, input)).toEqual({ok: true, errors: []})
  })

  it("retries invalid Radial geometry with deterministic bounded ring radii", async () => {
    const attemptedRadii = []
    const firstLayout = elkLayout()
    firstLayout.children = firstLayout.children.map((node) => node.id === "gamma" ? {...node, x: 130, y: 0} : node)
    const elk = {
      async layout(graph) {
        attemptedRadii.push(graph.layoutOptions["org.eclipse.elk.radial.radius"])
        return attemptedRadii.length === 1 ? firstLayout : elkLayout()
      },
    }

    const scene = await layoutTopologyOverview(overviewInput(), elk)

    expect(attemptedRadii).toEqual(["224", "448"])
    expect(validateTopologyOverview(scene, overviewInput())).toEqual({ok: true, errors: []})
  })

  it("retries coincident semantic centers with the next bounded ring radius", async () => {
    const attemptedRadii = []
    const coincidentLayout = elkLayout()
    coincidentLayout.children = coincidentLayout.children.map((node) => node.id === "beta" ? {...node, x: 0, y: 0} : node)
    const elk = {
      async layout(graph) {
        attemptedRadii.push(graph.layoutOptions["org.eclipse.elk.radial.radius"])
        return attemptedRadii.length === 1 ? coincidentLayout : elkLayout()
      },
    }

    const scene = await layoutTopologyOverview(overviewInput(), elk)

    expect(attemptedRadii).toEqual(["224", "448"])
    expect(validateTopologyOverview(scene, overviewInput())).toEqual({ok: true, errors: []})
  })

  it("fails closed after the bounded Radial radius attempts are exhausted", async () => {
    const attemptedRadii = []
    const invalidLayout = elkLayout()
    invalidLayout.children = invalidLayout.children.map((node) => node.id === "gamma" ? {...node, x: 130, y: 0} : node)
    const elk = {
      async layout(graph) {
        attemptedRadii.push(graph.layoutOptions["org.eclipse.elk.radial.radius"])
        return invalidLayout
      },
    }

    await expect(layoutTopologyOverview(overviewInput(), elk)).rejects.toThrow(
      "route alpha-beta intersects nonincident node gamma",
    )
    expect(attemptedRadii).toEqual(["224", "448", "896"])
  })

  it("lays out the bounded backbone instead of a high-cardinality inferred endpoint fanout", async () => {
    const input = prepareTopologyOverviewInput(densePollutedRadialGraph())
    const scene = await layoutTopologyOverview(input, new ELK())

    expect(input.manifest).toMatchObject({glyphs: 2, treeRelations: 1, omittedAttachmentNodes: 160})
    expect(scene.nodes.map((node) => node.id)).toEqual(["access", "core"])
    expect(validateTopologyOverview(scene, input)).toEqual({ok: true, errors: []})
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

  it("rejects nonincident crossing and collinearly overlapping semantic chords", () => {
    const input = routeCollisionInput()
    const crossing = decodeElkRadialOverview(routeCollisionLayout({
      a: {x: 0, y: 0}, b: {x: 300, y: 300}, c: {x: 0, y: 300}, d: {x: 300, y: 0},
    }), input)
    const overlap = decodeElkRadialOverview(routeCollisionLayout({
      a: {x: 0, y: 0}, b: {x: 500, y: 0}, c: {x: 200, y: 0}, d: {x: 700, y: 0},
    }), input)

    expect(validateTopologyOverview(crossing, input).errors).toContain("routes a-b and c-d cross")
    expect(validateTopologyOverview(overlap, input).errors).toContain("routes a-b and c-d have overlapping interiors")
  })

  it("allows only a shared semantic endpoint contact within route intersection tolerance", () => {
    const input = routeCollisionInput()
    input.treeRelations[1] = {id: "c-b", sourceId: "c", targetId: "b", semanticRelationIds: ["wire:c-b"]}
    const scene = JSON.parse(JSON.stringify(decodeElkRadialOverview(routeCollisionLayout({
      a: {x: 0, y: 0}, b: {x: 300, y: 0}, c: {x: 0, y: 300}, d: {x: 300, y: 300},
    }, input), input)))
    scene.routes[1] = {...scene.routes[1], points: [{x: 56, y: 300}, {x: 300, y: 56}]}
    scene.physicalRoutes = scene.routes

    expect(validateTopologyOverview(scene, input)).toEqual({ok: true, errors: []})
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

  it("applies overview geometry to numeric and whitespace-padded raw node IDs", () => {
    const input = numericIdOverviewInput()
    const scene = decodeElkRadialOverview({
      id: "root",
      children: [
        {id: "101", x: 0, y: 0, width: 112, height: 112},
        {id: "beta", x: 200, y: 0, width: 112, height: 112},
      ],
      edges: [{id: "101-beta", sources: ["101"], targets: ["beta"]}],
    }, input)

    const laidOut = applyTopologyOverviewToGraph({
      nodes: [{id: 101, x: 999, y: 999}, {id: " beta ", x: 999, y: 999}],
    }, scene)

    expect(laidOut.nodes).toEqual([
      expect.objectContaining({id: 101, x: 56, y: 56}),
      expect.objectContaining({id: " beta ", x: 256, y: 56}),
    ])
  })
})
