import ELK from "elkjs/lib/elk.bundled.js"
import {describe, expect, it} from "vitest"

import {
  LANDSCAPE_PROFILE,
  PORTRAIT_PROFILE,
  applyTopologySceneToGraph,
  buildElkSceneGraph,
  elkGroupContainerId,
  decodeElkScene,
  layoutTopologyScene,
  validateTopologyScene,
  viewportProfileForSize,
} from "./layout_elk_scene"
import {bindApi, createStateBackedContext} from "./api_helpers"
import {
  collapsedFarm01Graph,
  expandedFarm01Graph,
  reverseGraphArrays,
} from "./fixtures/farm01_topology_regression"
import {prepareTopologySceneInput} from "./topology_scene_graph"
import {routeStrokeHitsBox} from "./acceptance_geometry_assertions"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"
import {godViewRenderingGraphViewMethods} from "./rendering_graph_view_methods"
import {managedVisualDensityContract} from "./rendering_managed_visual_density"
import {fitTopologyScene} from "./rendering_scene_view"

function findElkNode(node, id) {
  if (node?.id === id) return node
  for (const child of node?.children || []) {
    const found = findElkNode(child, id)
    if (found) return found
  }
  return null
}

function allElkEdges(node) {
  return [
    ...(node?.edges || []),
    ...(node?.children || []).flatMap((child) => allElkEdges(child)),
  ]
}

function locallyRelatedGroupSceneInput() {
  return {
    nodes: [
      {id: "anchor", kind: "node", groupId: null, render: true},
      {id: "gateway", kind: "endpoint-summary", groupId: "group", render: false},
      {id: "member-a", kind: "endpoint-member", groupId: "group", render: true},
      {id: "member-b", kind: "endpoint-member", groupId: "group", render: true},
    ],
    groups: [{
      id: "group",
      anchorId: "anchor",
      gatewayId: "gateway",
      memberIds: ["member-a", "member-b"],
      expanded: true,
    }],
    renderedRelations: [
      {id: "root-trunk", sourceId: "anchor", targetId: "gateway", relationIds: ["root"]},
      {id: "local-member", sourceId: "member-a", targetId: "member-b", relationIds: ["local"]},
    ],
    layoutRelations: [
      {id: "pack-a", sourceId: "gateway", targetId: "member-a"},
      {id: "pack-b", sourceId: "gateway", targetId: "member-b"},
    ],
  }
}

function directedFanoutSceneInput() {
  return {
    nodes: [
      {id: "hub", kind: "node", groupId: null, render: true},
      ...["in-a", "in-b", "out-a", "out-b", "out-c", "out-d"].map((id) => ({
        id,
        kind: "node",
        groupId: null,
        render: true,
      })),
    ],
    groups: [],
    renderedRelations: [
      {id: "in-a-hub", sourceId: "in-a", targetId: "hub", relationIds: ["in-a"]},
      {id: "in-b-hub", sourceId: "in-b", targetId: "hub", relationIds: ["in-b"]},
      {id: "hub-out-a", sourceId: "hub", targetId: "out-a", relationIds: ["out-a"]},
      {id: "hub-out-b", sourceId: "hub", targetId: "out-b", relationIds: ["out-b"]},
      {id: "hub-out-c", sourceId: "hub", targetId: "out-c", relationIds: ["out-c"]},
      {id: "hub-out-d", sourceId: "hub", targetId: "out-d", relationIds: ["out-d"]},
    ],
    layoutRelations: [],
  }
}

function degreeTwoFanoutSceneInput() {
  return {
    nodes: ["hub", "leaf-a", "leaf-b"].map((id) => ({
      id,
      kind: "node",
      groupId: null,
      render: true,
    })),
    groups: [],
    renderedRelations: [
      {id: "hub-a", sourceId: "hub", targetId: "leaf-a", relationIds: ["semantic:hub-a"]},
      {id: "hub-b", sourceId: "hub", targetId: "leaf-b", relationIds: ["semantic:hub-b"]},
    ],
    layoutRelations: [],
    graphKey: "degree-two-fanout",
    manifest: {nodes: 3, renderedRoutes: 2, renderedGlyphs: 3},
  }
}

function degreeTwoNodeBoundElkResult() {
  return {
    id: "root",
    x: 0,
    y: 0,
    width: 612,
    height: 512,
    children: [
      {id: "hub", x: 0, y: 0, width: 112, height: 112},
      {id: "leaf-a", x: 500, y: 0, width: 112, height: 112},
      {id: "leaf-b", x: 500, y: 400, width: 112, height: 112},
    ],
    edges: [
      {
        id: "hub-a",
        sources: ["hub"],
        targets: ["leaf-a"],
        sections: [{startPoint: {x: 112, y: 28}, endPoint: {x: 500, y: 28}}],
      },
      {
        id: "hub-b",
        sources: ["hub"],
        targets: ["leaf-b"],
        sections: [{
          startPoint: {x: 112, y: 84},
          bendPoints: [{x: 300, y: 84}, {x: 300, y: 456}],
          endPoint: {x: 500, y: 456},
        }],
      },
    ],
  }
}

function containerRelativeSceneInput() {
  return {
    nodes: [
      {id: "anchor", kind: "node", groupId: null, render: true},
      {id: "gateway", kind: "endpoint-summary", groupId: "group", render: false},
    ],
    groups: [
      {
        id: "group",
        anchorId: "anchor",
        gatewayId: "gateway",
        memberIds: [],
        expanded: true,
      },
    ],
    renderedRelations: [
      {
        id: "trunk",
        sourceId: "anchor",
        targetId: "gateway",
        relationIds: ["semantic:trunk"],
      },
    ],
    layoutRelations: [],
    graphKey: "container-relative",
    manifest: {nodes: 2, renderedRoutes: 1, renderedGlyphs: 1},
  }
}

function containerRelativeElkResult() {
  return {
    id: "root",
    x: 0,
    y: 0,
    width: 500,
    height: 300,
    children: [
      {
        id: "anchor",
        x: 20,
        y: 20,
        width: 112,
        height: 112,
        ports: [{id: "port:anchor:trunk", x: 112, y: 56, width: 0, height: 0}],
      },
      {id: "route-container", x: 100, y: 40, width: 260, height: 180},
      {
        id: elkGroupContainerId("group"),
        x: 200,
        y: 100,
        width: 200,
        height: 160,
        children: [
          {
            id: "gateway",
            x: 20,
            y: 30,
            width: 112,
            height: 112,
            ports: [{id: "port:gateway:trunk", x: 0, y: 56, width: 0, height: 0}],
          },
        ],
      },
    ],
    edges: [
      {
        id: "trunk",
        container: "route-container",
        sources: ["port:anchor:trunk"],
        targets: ["port:gateway:trunk"],
        sections: [
          {
            startPoint: {x: 32, y: 36},
            bendPoints: [{x: 80, y: 36}],
            endPoint: {x: 120, y: 146},
          },
        ],
      },
    ],
  }
}

function validScene() {
  return {
    nodes: [
      {id: "left", center: {x: 0, y: 0}, width: 20, height: 20, groupId: null, render: true},
      {id: "right", center: {x: 100, y: 0}, width: 20, height: 20, groupId: null, render: true},
    ],
    groups: [],
    routes: [
      {
        id: "left-right",
        sourceId: "left",
        targetId: "right",
        points: [{x: 10, y: 0}, {x: 90, y: 0}],
        relationIds: ["semantic:left-right"],
        metadata: {},
      },
    ],
    bounds: {minX: -10, minY: -10, maxX: 110, maxY: 10},
  }
}

function twoRouteScene({thirdNode, fourthNode, secondRoutePoints}) {
  return {
    nodes: [
      {id: "a", center: {x: 0, y: 500}, width: 10, height: 10, groupId: null, render: true},
      {id: "b", center: {x: 1000, y: 500}, width: 10, height: 10, groupId: null, render: true},
      {id: "c", center: thirdNode, width: 10, height: 10, groupId: null, render: true},
      {id: "d", center: fourthNode, width: 10, height: 10, groupId: null, render: true},
    ],
    groups: [],
    routes: [
      {
        id: "a-b",
        sourceId: "a",
        targetId: "b",
        points: [{x: 5, y: 500}, {x: 995, y: 500}],
        relationIds: ["semantic:a-b"],
        metadata: {},
      },
      {
        id: "c-d",
        sourceId: "c",
        targetId: "d",
        points: secondRoutePoints,
        relationIds: ["semantic:c-d"],
        metadata: {},
      },
    ],
    bounds: {minX: -5, minY: -5, maxX: 1005, maxY: 1005},
  }
}

function routedScene(nodes, routes) {
  const sceneNodes = nodes.map(({id, x, y}) => ({
    id,
    center: {x, y},
    width: 10,
    height: 10,
    groupId: null,
    render: true,
  }))
  const xs = sceneNodes.map((node) => node.center.x)
  const ys = sceneNodes.map((node) => node.center.y)
  return {
    nodes: sceneNodes,
    groups: [],
    routes: routes.map((route) => ({
      ...route,
      relationIds: [`semantic:${route.id}`],
      metadata: {},
    })),
    bounds: {
      minX: Math.min(...xs) - 5,
      minY: Math.min(...ys) - 5,
      maxX: Math.max(...xs) + 5,
      maxY: Math.max(...ys) + 5,
    },
  }
}

function normalizeScene(scene) {
  return JSON.parse(
    JSON.stringify(scene, (_key, value) => (
      typeof value === "number" ? Math.round(value * 1_000_000) / 1_000_000 : value
    )),
  )
}

function glyphBoxesOverlap(left, right, epsilon = 1) {
  return Math.min(left.right, right.right) - Math.max(left.left, right.left) > epsilon
    && Math.min(left.bottom, right.bottom) - Math.max(left.top, right.top) > epsilon
}

function pointContactsSegmentForTest(point, start, end, epsilon = 0.01) {
  const dx = end.x - start.x
  const dy = end.y - start.y
  const lengthSquared = (dx * dx) + (dy * dy)
  if (lengthSquared <= epsilon * epsilon) {
    return Math.hypot(point.x - start.x, point.y - start.y) <= epsilon
  }
  const position = (((point.x - start.x) * dx) + ((point.y - start.y) * dy)) / lengthSquared
  if (position < -epsilon || position > 1 + epsilon) return false
  const closest = {x: start.x + (position * dx), y: start.y + (position * dy)}
  return Math.hypot(point.x - closest.x, point.y - closest.y) <= epsilon
}

describe("layout_elk_scene", () => {
  it("quantizes usable viewport shape into stable landscape and portrait profiles", () => {
    expect(viewportProfileForSize(1920, 1080, {left: 320, right: 0})).toBe(LANDSCAPE_PROFILE)
    expect(viewportProfileForSize(900, 1000, {top: 100, bottom: 100}).direction).toEqual("DOWN")
  })

  it("builds expanded endpoint membership as one compound ELK group", () => {
    const input = prepareTopologySceneInput(expandedFarm01Graph())
    const elkGraph = buildElkSceneGraph(input, LANDSCAPE_PROFILE)
    const expandedGroup = input.groups.find((group) => group.expanded)
    const group = findElkNode(elkGraph, elkGroupContainerId(expandedGroup.id))

    expect(group.children.map((child) => child.id)).toContain(expandedGroup.gatewayId)
    expect(
      group.children.filter(
        (child) => child.layoutOptions?.["serviceradar.kind"] === "endpoint-member",
      ),
    ).toHaveLength(24)
    const gateway = group.children.find((child) => child.id === expandedGroup.gatewayId)
    const member = group.children.find(
      (child) => child.layoutOptions?.["serviceradar.kind"] === "endpoint-member",
    )
    expect({width: gateway.width, height: gateway.height}).toEqual({width: 112, height: 112})
    expect(gateway.layoutOptions?.["serviceradar.render"]).toEqual("false")
    expect({width: member.width, height: member.height}).toEqual({width: 96, height: 96})
    const packingEdges = group.edges.filter(
      (edge) => edge.layoutOptions?.["serviceradar.render"] === "false",
    )
    const portOwnerById = new Map(group.children.flatMap(
      (child) => (child.ports || []).map((port) => [port.id, child.id]),
    ))
    const endpointOwner = (endpointId) => portOwnerById.get(endpointId) || endpointId
    const packingEdgeTo = (memberId) => packingEdges.find(
      (edge) => endpointOwner(edge.targets[0]) === memberId,
    )
    const memberIds = [...expandedGroup.memberIds].sort((left, right) => left.localeCompare(right))
    expect(packingEdges).toHaveLength(24)
    for (const memberId of memberIds.slice(0, 4)) {
      expect(endpointOwner(packingEdgeTo(memberId)?.sources[0])).toEqual(expandedGroup.gatewayId)
    }
    expect(endpointOwner(packingEdgeTo(memberIds[4])?.sources[0])).toEqual(memberIds[0])
    expect(
      elkGraph.edges.filter(
        (edge) => edge.layoutOptions?.["serviceradar.render"] === "true",
      ),
    ).toHaveLength(32)
    expect(elkGraph.layoutOptions).toMatchObject({
      "elk.algorithm": "layered",
      "elk.hierarchyHandling": "INCLUDE_CHILDREN",
      "elk.edgeRouting": "ORTHOGONAL",
      "elk.direction": "RIGHT",
    })
  })

  it.each([
    [PORTRAIT_PROFILE, "SOUTH", "NORTH"],
    [LANDSCAPE_PROFILE, "EAST", "WEST"],
  ])("fans rendered relations through one ELK-authored manifold per node role without inflating the visible glyph", (
    profile,
    sourceSide,
    targetSide,
  ) => {
    const elkGraph = buildElkSceneGraph(directedFanoutSceneInput(), profile)
    const nodes = []
    const edges = []
    const visit = (node) => {
      nodes.push(node)
      edges.push(...(node.edges || []))
      for (const child of node.children || []) visit(child)
    }
    visit(elkGraph)
    const portOwners = new Map(nodes.flatMap(
      (node) => (node.ports || []).map((port) => [port.id, node]),
    ))
    const renderedEdges = edges.filter(
      (edge) => edge.layoutOptions?.["serviceradar.render"] === "true",
    )

    expect(portOwners.size).toBeGreaterThan(0)
    for (const edge of renderedEdges) {
      const sourceOwner = portOwners.get(edge.sources[0])
      const targetOwner = portOwners.get(edge.targets[0])
      expect(sourceOwner?.layoutOptions?.["serviceradar.kind"]).toBe(
        sourceOwner?.layoutOptions?.["serviceradar.node-id"] === "hub" ? "fanout-manifold" : "node",
      )
      expect(targetOwner?.layoutOptions?.["serviceradar.kind"]).toBe(
        targetOwner?.layoutOptions?.["serviceradar.node-id"] === "hub" ? "fanout-manifold" : "node",
      )
    }
    const hub = nodes.find((node) => node.id === "hub")
    expect({width: hub.width, height: hub.height}).toEqual({width: 112, height: 112})
    expect(hub.ports).toHaveLength(2)

    const hubManifolds = nodes.filter(
      (node) => node.layoutOptions?.["serviceradar.node-id"] === "hub" &&
        node.layoutOptions?.["serviceradar.kind"] === "fanout-manifold",
    )
    expect(hubManifolds).toHaveLength(2)
    const sourceManifold = hubManifolds.find(
      (node) => node.layoutOptions?.["serviceradar.endpoint"] === "source",
    )
    const targetManifold = hubManifolds.find(
      (node) => node.layoutOptions?.["serviceradar.endpoint"] === "target",
    )
    const crossAxisDimension = profile.direction === "DOWN" ? "width" : "height"
    const flowAxisDimension = profile.direction === "DOWN" ? "height" : "width"
    expect(sourceManifold?.[crossAxisDimension]).toBe(5 * 208)
    expect(sourceManifold?.[flowAxisDimension]).toBe(0)
    expect(targetManifold?.[crossAxisDimension]).toBe(3 * 208)
    expect(targetManifold?.[flowAxisDimension]).toBe(0)
    expect(
      sourceManifold.ports
        .filter((port) => port.id.includes(":branch:"))
        .map((port) => port.layoutOptions["elk.port.side"]),
    ).toEqual([sourceSide, sourceSide, sourceSide, sourceSide])
    expect(
      targetManifold.ports
        .filter((port) => port.id.includes(":branch:"))
        .map((port) => port.layoutOptions["elk.port.side"]),
    ).toEqual([targetSide, targetSide])
    expect(
      edges.filter(
        (edge) => edge.layoutOptions?.["serviceradar.kind"] === "fanout-trunk" &&
          edge.layoutOptions?.["serviceradar.node-id"] === "hub",
      ),
    ).toHaveLength(2)
    for (const leafId of ["in-a", "in-b", "out-a", "out-b", "out-c", "out-d"]) {
      expect(nodes.some((node) => (
        node.layoutOptions?.["serviceradar.kind"] === "fanout-manifold" &&
        node.layoutOptions?.["serviceradar.node-id"] === leafId
      ))).toBe(false)
      expect(nodes.find((node) => node.id === leafId)?.ports).toHaveLength(1)
    }
  })

  it("packs portrait endpoint compounds across five ELK lanes before extending the flow axis", () => {
    const input = prepareTopologySceneInput(expandedFarm01Graph())
    const elkGraph = buildElkSceneGraph(input, PORTRAIT_PROFILE)
    const expandedGroup = input.groups.find((group) => group.expanded)
    const group = findElkNode(elkGraph, elkGroupContainerId(expandedGroup.id))
    const packingEdges = group.edges.filter(
      (edge) => edge.layoutOptions?.["serviceradar.render"] === "false",
    )
    const memberIds = [...expandedGroup.memberIds].sort((left, right) => left.localeCompare(right))
    const edgeTo = (memberId) => packingEdges.find((edge) => edge.targets[0] === memberId)

    for (const memberId of memberIds.slice(0, 5)) {
      expect(edgeTo(memberId)?.sources).toEqual([expandedGroup.gatewayId])
    }
    expect(edgeTo(memberIds[5])?.sources).toEqual([memberIds[0]])
  })

  it("owns every relation at its lowest common compound without duplicating root edges", () => {
    const elkGraph = buildElkSceneGraph(locallyRelatedGroupSceneInput(), PORTRAIT_PROFILE)
    const group = findElkNode(elkGraph, elkGroupContainerId("group"))

    expect(elkGraph.edges.map((edge) => edge.id)).toEqual(["root-trunk"])
    expect(group.edges.map((edge) => edge.id)).toEqual(["local-member", "pack-a", "pack-b"])
    expect(group.edges.find((edge) => edge.id === "local-member")?.layoutOptions).toMatchObject({
      "serviceradar.render": "true",
    })
    expect(group.edges.filter(
      (edge) => edge.layoutOptions?.["serviceradar.render"] === "false",
    )).toHaveLength(2)
    expect(allElkEdges(elkGraph).map((edge) => edge.id).sort()).toEqual([
      "local-member",
      "pack-a",
      "pack-b",
      "root-trunk",
    ])
  })

  it("keeps collapsed summaries in the root scene without compound member groups", () => {
    const input = prepareTopologySceneInput(collapsedFarm01Graph())
    const elkGraph = buildElkSceneGraph(input, LANDSCAPE_PROFILE)
    const visibleSummaries = input.nodes.filter((node) => node.kind === "endpoint-summary" && node.render)

    expect(elkGraph.children.some((child) => child.id === input.groups[0].gatewayId)).toEqual(true)
    expect(input.groups.every((group) => findElkNode(elkGraph, elkGroupContainerId(group.id)) === null)).toEqual(true)
    expect(visibleSummaries).toHaveLength(6)
    for (const summary of visibleSummaries) {
      const elkSummary = findElkNode(elkGraph, summary.id)
      expect({width: elkSummary.width, height: elkSummary.height}).toEqual({width: 448, height: 448})
    }
  })

  it("decodes edge section points from edge.container coordinates", () => {
    const decoded = decodeElkScene(containerRelativeElkResult(), containerRelativeSceneInput())

    expect(decoded.nodes.find((node) => node.id === "gateway").center).toEqual({x: 276, y: 186})
    expect(decoded.routes.find((route) => route.id === "trunk").points).toEqual([
      {x: 132, y: 76},
      {x: 180, y: 76},
      {x: 220, y: 186},
    ])
    expect(validateTopologyScene(decoded)).toEqual({
      ok: true,
      errors: [],
      diagnostics: {routeCrossingPairs: 0},
    })
  })

  it.each([
    ["missing source", undefined, ["port:gateway:trunk"]],
    ["extra source", ["port:anchor:trunk", "unknown"], ["port:gateway:trunk"]],
    ["missing target", ["port:anchor:trunk"], undefined],
    ["extra target", ["port:anchor:trunk"], ["port:gateway:trunk", "unknown"]],
    ["swapped endpoints", ["port:gateway:trunk"], ["port:anchor:trunk"]],
    ["unknown source", ["unknown"], ["port:gateway:trunk"]],
    ["unknown target", ["port:anchor:trunk"], ["unknown"]],
  ])("rejects a rendered ELK edge with %s bindings", (_description, sources, targets) => {
    const elkResult = containerRelativeElkResult()
    elkResult.edges[0].sources = sources
    elkResult.edges[0].targets = targets

    const scene = decodeElkScene(elkResult, containerRelativeSceneInput())
    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors.some((error) => error.includes("endpoint binding"))).toEqual(true)
  })

  it("rejects a direct route section that misses its declared ELK port center", () => {
    const elkResult = containerRelativeElkResult()
    elkResult.edges[0].sections[0].startPoint = {x: 32, y: 16}

    const scene = decodeElkScene(elkResult, containerRelativeSceneInput())
    const result = validateTopologyScene(scene)

    expect(result.ok).toBe(false)
    expect(result.errors).toContain(
      "route trunk section source does not contact bound ELK port port:anchor:trunk",
    )
  })

  it("rejects an ELK result that shrinks a requested glyph envelope", () => {
    const elkResult = containerRelativeElkResult()
    elkResult.children.find((child) => child.id === "anchor").width = 111

    const scene = decodeElkScene(elkResult, containerRelativeSceneInput())
    const result = validateTopologyScene(scene)

    expect(result.ok).toBe(false)
    expect(result.errors).toContain("node anchor is smaller than its required 112 x 112 ELK envelope")
  })

  it("rejects ELK results that resize a fanout manifold rail", async () => {
    const input = degreeTwoFanoutSceneInput()
    const validResult = await new ELK().layout(buildElkSceneGraph(input, LANDSCAPE_PROFILE))
    const nonzeroFlow = JSON.parse(JSON.stringify(validResult))
    findElkNode(nonzeroFlow, "manifold:hub:source").width = 1
    const wrongCrossAxis = JSON.parse(JSON.stringify(validResult))
    findElkNode(wrongCrossAxis, "manifold:hub:source").height = (3 * 208) - 1

    for (const elkResult of [nonzeroFlow, wrongCrossAxis]) {
      const scene = decodeElkScene(elkResult, input)
      const result = validateTopologyScene(scene)

      expect(result.ok).toBe(false)
      expect(result.errors).toContain(
        "manifold manifold:hub:source must retain one zero flow axis and exact 624 cross-axis length",
      )
    }
  })

  it("rejects degree-two fanout decoded as raw node-bound routes without its required manifold", () => {
    const scene = decodeElkScene(degreeTwoNodeBoundElkResult(), degreeTwoFanoutSceneInput())
    const result = validateTopologyScene(scene)

    expect(scene.manifolds).toHaveLength(1)
    expect(scene.physicalRoutes).toHaveLength(4)
    expect(result.ok).toBe(false)
    expect(result.errors).toEqual(expect.arrayContaining([
      expect.stringContaining("endpoint binding"),
      expect.stringContaining("manifold manifold:hub:source"),
    ]))
  })

  it("rejects an expected expanded group when ELK returns its nodes as root leaves", () => {
    const elkResult = containerRelativeElkResult()
    elkResult.children = elkResult.children.filter((child) => child.id !== elkGroupContainerId("group"))
    elkResult.children.push({id: "gateway", x: 220, y: 130, width: 50, height: 50})

    const scene = decodeElkScene(elkResult, containerRelativeSceneInput())
    const result = validateTopologyScene(scene)

    expect(scene.groups).toHaveLength(1)
    expect(result.ok).toEqual(false)
    expect(result.errors.some((error) => error.includes("group group has non-finite geometry"))).toEqual(true)
  })

  it("rejects non-finite decoded geometry", () => {
    const scene = validScene()
    scene.nodes[0].center.x = Number.NaN

    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors.some((error) => error.includes("non-finite"))).toEqual(true)
  })

  it("rejects rendered relations without exactly one non-degenerate section", () => {
    const elkResult = containerRelativeElkResult()
    elkResult.edges[0].sections.push({
      startPoint: {x: 0, y: 0},
      endPoint: {x: 1, y: 1},
    })
    const scene = decodeElkScene(elkResult, containerRelativeSceneInput())

    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors.some((error) => error.includes("continuous section"))).toEqual(true)
  })

  it("treats route points at or below the 0.01 layout tolerance as degenerate", () => {
    for (const delta of [0.009, 0.01]) {
      const scene = validScene()
      scene.nodes[0] = {...scene.nodes[0], center: {x: 0, y: 0}, width: 0.001, height: 0.001}
      scene.nodes[1] = {...scene.nodes[1], center: {x: delta + 0.001, y: 0}, width: 0.001, height: 0.001}
      scene.routes[0].points = [{x: 0.0005, y: 0}, {x: delta + 0.0005, y: 0}]

      expect(validateTopologyScene(scene).ok, `delta ${delta}`).toEqual(false)
    }

    const separated = validScene()
    separated.nodes[0] = {...separated.nodes[0], center: {x: 0, y: 0}, width: 0.001, height: 0.001}
    separated.nodes[1] = {...separated.nodes[1], center: {x: 0.0111, y: 0}, width: 0.001, height: 0.001}
    separated.routes[0].points = [{x: 0.0005, y: 0}, {x: 0.0106, y: 0}]
    expect(validateTopologyScene(separated)).toEqual({
      ok: true,
      errors: [],
      diagnostics: {routeCrossingPairs: 0},
    })
  })

  it("rejects a finite route shifted away from both declared endpoint boundaries", () => {
    const scene = validScene()
    scene.routes[0].points = [{x: 10, y: 20}, {x: 90, y: 20}]

    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors).toEqual(expect.arrayContaining([
      expect.stringContaining("source endpoint left"),
      expect.stringContaining("target endpoint right"),
    ]))
  })

  it("rejects a route whose polyline ends contact the opposite declared endpoints", () => {
    const scene = validScene()
    scene.routes[0].points = [{x: 90, y: 0}, {x: 10, y: 0}]

    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors).toEqual(expect.arrayContaining([
      expect.stringContaining("source endpoint left"),
      expect.stringContaining("target endpoint right"),
    ]))
  })

  it.each([
    ["source", "left", [
      {x: 10, y: 0},
      {x: 20, y: 0},
      {x: 0, y: 0},
      {x: 20, y: 20},
      {x: 90, y: 0},
    ]],
    ["target", "right", [
      {x: 10, y: 0},
      {x: 80, y: 20},
      {x: 100, y: 0},
      {x: 80, y: 0},
      {x: 90, y: 0},
    ]],
  ])("rejects a route that exits and re-enters its %s node", (role, nodeId, points) => {
    const scene = validScene()
    scene.routes[0].points = points

    expect(validateTopologyScene(scene)).toEqual({
      ok: false,
      errors: [`route left-right traverses incident ${role} node ${nodeId} open interior`],
      diagnostics: {routeCrossingPairs: 0},
    })
  })

  it("rejects a rendered relation repeated in multiple ELK containers", () => {
    const elkResult = containerRelativeElkResult()
    elkResult.children[1].edges = [{...elkResult.edges[0]}]
    const scene = decodeElkScene(elkResult, containerRelativeSceneInput())

    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors.some((error) => error.includes("continuous section"))).toEqual(true)
  })

  it("rejects overlapping non-nested boxes", () => {
    const scene = validScene()
    scene.nodes[1].center = {x: 5, y: 0}

    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors.some((error) => error.includes("overlap"))).toEqual(true)
  })

  it("rejects members outside their compound group", () => {
    const scene = validScene()
    scene.nodes.push({
      id: "member",
      center: {x: 210, y: 60},
      width: 20,
      height: 20,
      groupId: "group",
      render: true,
    })
    scene.groups.push({
      id: "group",
      bounds: {minX: 120, minY: 0, maxX: 200, maxY: 100},
      memberIds: ["member"],
      anchorId: "left",
      gatewayId: "member",
    })

    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors.some((error) => error.includes("outside group"))).toEqual(true)
  })

  it("rejects routes through nonincident padded node interiors", () => {
    const scene = validScene()
    scene.nodes.push({
      id: "obstacle",
      center: {x: 50, y: 0},
      width: 20,
      height: 20,
      groupId: null,
      render: true,
    })

    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors.some((error) => error.includes("intersects"))).toEqual(true)
  })

  it("rejects positive-length collinear overlap between distinct rendered routes", () => {
    const scene = twoRouteScene({
      thirdNode: {x: 200, y: 0},
      fourthNode: {x: 800, y: 1000},
      secondRoutePoints: [
        {x: 200, y: 5},
        {x: 200, y: 500},
        {x: 800, y: 500},
        {x: 800, y: 995},
      ],
    })

    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors).toContain("routes a-b and c-d have coincident interior segments")
  })

  it("accepts one proper point crossing and reports it as a route-pair diagnostic", () => {
    const scene = twoRouteScene({
      thirdNode: {x: 500, y: 0},
      fourthNode: {x: 500, y: 1000},
      secondRoutePoints: [{x: 500, y: 5}, {x: 500, y: 995}],
    })

    const result = validateTopologyScene(scene)

    expect(result).toEqual({
      ok: true,
      errors: [],
      diagnostics: {routeCrossingPairs: 1},
    })
  })

  it("classifies a proper crossing consistently on short internal segments", () => {
    const scene = routedScene(
      [
        {id: "a", x: -1000, y: 0},
        {id: "b", x: 1000, y: 0},
        {id: "c", x: 0, y: -1000},
        {id: "d", x: 0, y: 1000},
      ],
      [
        {
          id: "a-b",
          sourceId: "a",
          targetId: "b",
          points: [{x: -995, y: 0}, {x: 0, y: 0}, {x: 0.02, y: 0}, {x: 995, y: 0}],
        },
        {
          id: "c-d",
          sourceId: "c",
          targetId: "d",
          points: [{x: 0, y: -995}, {x: 0, y: -0.4}, {x: 0.02, y: 0.4}, {x: 0, y: 995}],
        },
      ],
    )

    expect(validateTopologyScene(scene)).toEqual({
      ok: true,
      errors: [],
      diagnostics: {routeCrossingPairs: 1},
    })
  })

  it("rejects long coincident interiors within the linear geometry epsilon", () => {
    const scene = routedScene(
      [
        {id: "a", x: -10000, y: 0},
        {id: "b", x: 10000, y: 0},
        {id: "c", x: -5000, y: 1000},
        {id: "d", x: 5000, y: 1000},
      ],
      [
        {id: "a-b", sourceId: "a", targetId: "b", points: [{x: -9995, y: 0}, {x: 9995, y: 0}]},
        {
          id: "c-d",
          sourceId: "c",
          targetId: "d",
          points: [{x: -5000, y: 995}, {x: -5000, y: 0.005}, {x: 5000, y: 0.005}, {x: 5000, y: 995}],
        },
      ],
    )

    const result = validateTopologyScene(scene)

    expect(result.ok).toBe(false)
    expect(result.errors).toContain("routes a-b and c-d have coincident interior segments")
  })

  it("accepts long parallel interiors separated beyond the linear geometry epsilon", () => {
    const scene = routedScene(
      [
        {id: "a", x: -10000, y: 0},
        {id: "b", x: 10000, y: 0},
        {id: "c", x: -5000, y: 1000},
        {id: "d", x: 5000, y: 1000},
      ],
      [
        {id: "a-b", sourceId: "a", targetId: "b", points: [{x: -9995, y: 0}, {x: 9995, y: 0}]},
        {
          id: "c-d",
          sourceId: "c",
          targetId: "d",
          points: [{x: -5000, y: 995}, {x: -5000, y: 0.02}, {x: 5000, y: 0.02}, {x: 5000, y: 995}],
        },
      ],
    )

    expect(validateTopologyScene(scene)).toEqual({
      ok: true,
      errors: [],
      diagnostics: {routeCrossingPairs: 0},
    })
  })

  it("allows a genuine shared semantic endpoint contact without a diagnostic", () => {
    const scene = routedScene(
      [
        {id: "a", x: -1000, y: 0},
        {id: "b", x: 1000, y: 0},
        {id: "c", x: 0, y: 1000},
      ],
      [
        {id: "a-b", sourceId: "a", targetId: "b", points: [{x: -995, y: 0}, {x: 995, y: 0}]},
        {
          id: "a-c",
          sourceId: "a",
          targetId: "c",
          points: [{x: -995, y: 0}, {x: -500, y: 500}, {x: 0, y: 995}],
        },
      ],
    )

    expect(validateTopologyScene(scene)).toEqual({
      ok: true,
      errors: [],
      diagnostics: {routeCrossingPairs: 0},
    })
  })

  it("allows but diagnoses an unrelated endpoint-on-interior T contact", () => {
    const scene = routedScene(
      [
        {id: "a", x: -1000, y: 0},
        {id: "b", x: 1000, y: 0},
        {id: "c", x: 0, y: -1000},
        {id: "d", x: 500, y: -1000},
      ],
      [
        {id: "a-b", sourceId: "a", targetId: "b", points: [{x: -995, y: 0}, {x: 995, y: 0}]},
        {
          id: "c-d",
          sourceId: "c",
          targetId: "d",
          points: [{x: 0, y: -995}, {x: 0, y: 0}, {x: 500, y: -995}],
        },
      ],
    )

    expect(validateTopologyScene(scene)).toEqual({
      ok: true,
      errors: [],
      diagnostics: {routeCrossingPairs: 1},
    })
  })

  it("diagnoses an incident route pair that crosses again away from its shared endpoint", () => {
    const scene = routedScene(
      [
        {id: "a", x: -1000, y: 0},
        {id: "b", x: 1000, y: 0},
        {id: "c", x: 500, y: -1000},
      ],
      [
        {id: "a-b", sourceId: "a", targetId: "b", points: [{x: -995, y: 0}, {x: 995, y: 0}]},
        {
          id: "a-c",
          sourceId: "a",
          targetId: "c",
          points: [{x: -995, y: 0}, {x: -500, y: 500}, {x: 500, y: -995}],
        },
      ],
    )

    expect(validateTopologyScene(scene)).toEqual({
      ok: true,
      errors: [],
      diagnostics: {routeCrossingPairs: 1},
    })
  })

  it("lays out both farm01 fixtures deterministically with valid groups and routes", async () => {
    for (const graph of [collapsedFarm01Graph(), expandedFarm01Graph()]) {
      const input = prepareTopologySceneInput(graph)
      const first = await layoutTopologyScene(input, {
        engine: new ELK(),
        profile: LANDSCAPE_PROFILE,
      })
      const second = await layoutTopologyScene(
        prepareTopologySceneInput(reverseGraphArrays(graph)),
        {engine: new ELK(), profile: LANDSCAPE_PROFILE},
      )

      expect(validateTopologyScene(first)).toEqual({
        ok: true,
        errors: [],
        diagnostics: {routeCrossingPairs: 0},
      })
      expect(first.routes).toHaveLength(32)
      for (const route of first.routes) {
        if (!route.sourceManifoldId) {
          expect(route.sourceContactId).toBe(`port:${route.sourceId}:${route.id}`)
        }
        if (!route.targetManifoldId) {
          expect(route.targetContactId).toBe(`port:${route.targetId}:${route.id}`)
        }
      }
      expect(normalizeScene(second)).toEqual(normalizeScene(first))
    }
  })

  it("labels the Layered adapter output as bounded detail", async () => {
    const graph = collapsedFarm01Graph()
    const scene = await layoutTopologyScene(prepareTopologySceneInput(graph), {
      engine: new ELK(),
      profile: LANDSCAPE_PROFILE,
    })

    expect(applyTopologySceneToGraph(graph, scene)._layoutMode).toBe("elk-scene-detail")
  })

  it("keeps every Farm01 manifold physically connected from its fitted glyph to every semantic branch", async () => {
    for (const graph of [collapsedFarm01Graph(), expandedFarm01Graph()]) {
      const scene = await layoutTopologyScene(prepareTopologySceneInput(graph), {
        engine: new ELK(),
        profile: LANDSCAPE_PROFILE,
      })
      const effective = applyTopologySceneToGraph(graph, scene)
      const state = {
        animationPhase: 0,
        deck: {setProps() {}},
        hasAutoFit: false,
        userCameraLocked: false,
        zoomMode: "auto",
        layers: {mantle: true, crust: true},
        managedTopologyCameraBaseMinZoom: -8,
        viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
        el: {clientWidth: 1920, clientHeight: 1080},
        topologyLabelSafeRect: {left: 0, top: 0, right: 1920, bottom: 1030},
      }
      const context = createStateBackedContext(state, {
        setZoomTier() {},
        resolveZoomTier() { return "local" },
      })
      Object.assign(
        context,
        bindApi(context, godViewRenderingGraphLayerNodeMethods),
        bindApi(context, godViewRenderingGraphViewMethods),
      )
      context.selectNodeLabels = undefined
      context.admitNodeLabelsForViewport = undefined
      context.autoFitViewState(effective)

      const scale = 2 ** state.viewState.zoom
      const routeRadius = managedVisualDensityContract(state.managedTopologyVisualDensity).routeMaxWidth / 2
      const graphNodeById = new Map(effective.nodes.map((node) => [node.id, node]))
      const sceneNodeById = new Map(scene.nodes.map((node) => [node.id, node]))
      const routeById = new Map(scene.routes.map((route) => [route.id, route]))
      for (const manifold of scene.manifolds) {
        const trunkRoute = scene.physicalRoutes.find((route) => route.id === `${manifold.id}:trunk`)
        const glyphJunctionId = `${manifold.id}:junction:glyph`
        expect([trunkRoute.sourceContactId, trunkRoute.targetContactId]).toContain(glyphJunctionId)
        expect(trunkRoute.junctions).toContainEqual({id: glyphJunctionId, point: manifold.nodeContact})
        expect([trunkRoute.sourceContactId, trunkRoute.targetContactId]).not.toContain(manifold.nodeId)
        const sceneNode = sceneNodeById.get(manifold.nodeId)
        const glyphRadius = context.nodeVisibleOuterRadiusPixels(
          graphNodeById.get(manifold.nodeId),
          {managedVisualDensity: state.managedTopologyVisualDensity},
        )
        const centerDistance = Math.hypot(
          manifold.nodeContact.x - sceneNode.center.x,
          manifold.nodeContact.y - sceneNode.center.y,
        ) * scale
        expect(
          centerDistance,
          `${manifold.id} glyph contact at scale ${scale}`,
        ).toBeLessThanOrEqual(glyphRadius + routeRadius + 1)
        expect(manifold.trunkPoints.some((point) => (
          Math.hypot(point.x - manifold.nodeContact.x, point.y - manifold.nodeContact.y) <= 0.01
        ))).toBe(true)
        expect(manifold.trunkPoints.some((point) => (
          Math.hypot(point.x - manifold.trunkContact.x, point.y - manifold.trunkContact.y) <= 0.01
        ))).toBe(true)
        for (const branch of manifold.branchContacts) {
          const route = routeById.get(branch.routeId)
          const routePoint = manifold.endpoint === "source" ? route.points[0] : route.points.at(-1)
          expect(Math.hypot(
            routePoint.x - branch.point.x,
            routePoint.y - branch.point.y,
          )).toBeLessThanOrEqual(0.01)
          expect(manifold.railPoints.some((point, index, points) => (
            index > 0 && pointContactsSegmentForTest(branch.point, points[index - 1], point)
          ))).toBe(true)
        }
      }
    }
  })

  it("keeps every expanded Farm01 route clear of every nonincident rendered glyph at fitted scale", async () => {
    const graph = expandedFarm01Graph()
    const scene = await layoutTopologyScene(prepareTopologySceneInput(graph), {
      engine: new ELK(),
      profile: LANDSCAPE_PROFILE,
    })
    const viewport = {width: 1920, height: 1080, minZoom: -3, maxZoom: 5}
    const safeRect = {left: 0, top: 0, right: 1920, bottom: 1030}
    const graphNodeById = new Map(graph.nodes.map((node) => [node.id, node]))
    const nodeMethods = godViewRenderingGraphLayerNodeMethods
    const radiusContext = {visualClusterCount: nodeMethods.visualClusterCount}
    const renderedNodes = scene.nodes.filter((node) => node.render)
    const glyphBoxes = renderedNodes.map((node) => {
      const radius = nodeMethods.nodeHaloRadiusPixels.call(radiusContext, graphNodeById.get(node.id))
      return {nodeId: node.id, width: radius * 2, height: radius * 2}
    })
    const {viewState} = fitTopologyScene({scene, viewport, safeRect, glyphBoxes})
    const scale = 2 ** viewState.zoom
    expect(scale).toBeGreaterThanOrEqual(40 / 192)
    const project = (point) => ({
      x: (viewport.width / 2) + ((point.x - viewState.target[0]) * scale),
      y: (viewport.height / 2) + ((point.y - viewState.target[1]) * scale),
    })
    const glyphs = glyphBoxes.map((glyph) => {
      const node = scene.nodes.find((candidate) => candidate.id === glyph.nodeId)
      const center = project(node.center)
      return {
        nodeId: glyph.nodeId,
        left: center.x - (glyph.width / 2),
        top: center.y - (glyph.height / 2),
        right: center.x + (glyph.width / 2),
        bottom: center.y + (glyph.height / 2),
      }
    })
    const glyphOverlaps = []
    for (let left = 0; left < glyphs.length; left += 1) {
      for (let right = left + 1; right < glyphs.length; right += 1) {
        if (glyphBoxesOverlap(glyphs[left], glyphs[right])) {
          glyphOverlaps.push(`${glyphs[left].nodeId}->${glyphs[right].nodeId}`)
        }
      }
    }
    const collisions = scene.routes.flatMap((route) => {
      const projectedRoute = {...route, strokeWidth: 6, projectedPoints: route.points.map(project)}
      return glyphs
        .filter((glyph) => glyph.nodeId !== route.sourceId && glyph.nodeId !== route.targetId)
        .filter((glyph) => routeStrokeHitsBox(projectedRoute, glyph))
        .map((glyph) => `${route.id}->${glyph.nodeId}`)
    })

    expect(collisions).not.toContain(
      "rendered:farm01:attachment-02|farm01:gateway-02->farm01:attachment-08",
    )
    expect(glyphOverlaps).toEqual([])
    expect(collisions).toEqual([])
  })
})

describe("expanded group whose summary node carries the cluster id", () => {
  // Production names the endpoint-cluster summary node with the cluster id itself
  // (`build_endpoint_cluster_node` sets `id: group.cluster_id`), so the compound group and
  // one of its own children share an identifier. The regression fixtures give the summary a
  // separate id, which is why this never showed up in a test while every real expansion
  // failed.
  function productionShapedGraph(memberCount) {
    const anchorId = "sr:anchor-1"
    const clusterId = `cluster:endpoints:${anchorId}`
    const nodes = [
      {id: anchorId, label: "switch", state: 1, operUp: 1,
        details: {cluster_kind: "endpoint-anchor", cluster_anchor_id: anchorId}},
      {id: clusterId, label: `${memberCount} endpoints`, state: 1, operUp: 1, clusterCount: memberCount,
        details: {cluster_id: clusterId, cluster_kind: "endpoint-summary",
          cluster_anchor_id: anchorId, cluster_expanded: true}},
    ]
    const edges = [{id: "att:summary", source: 0, target: 1,
      topologyClass: "endpoints", evidenceClass: "endpoint-attachment"}]
    for (let index = 0; index < memberCount; index += 1) {
      edges.push({id: `att:member-${index}`, source: 0, target: nodes.length,
        topologyClass: "endpoints", evidenceClass: "endpoint-attachment"})
      nodes.push({id: `sr:member-${index}`, label: `endpoint ${index}`, state: 1, operUp: 1,
        details: {cluster_id: clusterId, cluster_kind: "endpoint-member",
          cluster_anchor_id: anchorId, cluster_expanded: true}})
    }
    return {nodes, edges}
  }

  it("keeps every member inside the group the ELK container actually laid out", async () => {
    const input = prepareTopologySceneInput(productionShapedGraph(13))
    const group = input.groups.find((candidate) => (candidate.memberIds || []).length > 0)
    expect(group.id, "this fixture only means something while the ids collide").toBe(group.gatewayId)

    const scene = await layoutTopologyScene(input, {engine: new ELK()})
    const laidOut = scene.groups.find((candidate) => candidate.id === group.id)
    const byId = new Map(scene.nodes.map((node) => [node.id, node]))

    for (const memberId of laidOut.memberIds) {
      const node = byId.get(memberId)
      expect(node, `${memberId} must be in the scene`).toBeTruthy()
      expect(node.center.x - node.width / 2).toBeGreaterThanOrEqual(laidOut.bounds.minX - 1)
      expect(node.center.x + node.width / 2).toBeLessThanOrEqual(laidOut.bounds.maxX + 1)
      expect(node.center.y - node.height / 2).toBeGreaterThanOrEqual(laidOut.bounds.minY - 1)
      expect(node.center.y + node.height / 2).toBeLessThanOrEqual(laidOut.bounds.maxY + 1)
    }
  })
})
