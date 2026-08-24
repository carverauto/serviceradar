import ELK from "elkjs/lib/elk.bundled.js"
import {describe, expect, it} from "vitest"

import {
  LANDSCAPE_PROFILE,
  buildElkSceneGraph,
  decodeElkScene,
  layoutTopologyScene,
  validateTopologyScene,
  viewportProfileForSize,
} from "./layout_elk_scene"
import {
  collapsedFarm01Graph,
  expandedFarm01Graph,
  reverseGraphArrays,
} from "./fixtures/farm01_topology_regression"
import {prepareTopologySceneInput} from "./topology_scene_graph"
import {routeStrokeHitsBox} from "./acceptance_geometry_assertions"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"
import {fitTopologyScene} from "./rendering_scene_view"

function findElkNode(node, id) {
  if (node?.id === id) return node
  for (const child of node?.children || []) {
    const found = findElkNode(child, id)
    if (found) return found
  }
  return null
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
      {id: "anchor", x: 20, y: 20, width: 40, height: 40},
      {id: "route-container", x: 100, y: 40, width: 260, height: 180},
      {
        id: "group",
        x: 200,
        y: 100,
        width: 200,
        height: 160,
        children: [
          {id: "gateway", x: 20, y: 30, width: 50, height: 50},
        ],
      },
    ],
    edges: [
      {
        id: "trunk",
        container: "route-container",
        sources: ["anchor"],
        targets: ["gateway"],
        sections: [
          {
            startPoint: {x: -40, y: 0},
            bendPoints: [{x: 80, y: 0}],
            endPoint: {x: 120, y: 100},
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

function normalizeScene(scene) {
  return JSON.parse(
    JSON.stringify(scene, (_key, value) => (
      typeof value === "number" ? Math.round(value * 1_000_000) / 1_000_000 : value
    )),
  )
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
    const group = findElkNode(elkGraph, expandedGroup.id)

    expect(group.children.map((child) => child.id)).toContain(expandedGroup.gatewayId)
    expect(
      group.children.filter(
        (child) => child.layoutOptions?.["serviceradar.kind"] === "endpoint-member",
      ),
    ).toHaveLength(24)
    expect(
      elkGraph.edges.filter(
        (edge) => edge.layoutOptions?.["serviceradar.render"] !== "false",
      ),
    ).toHaveLength(32)
    expect(elkGraph.layoutOptions).toMatchObject({
      "elk.algorithm": "layered",
      "elk.hierarchyHandling": "INCLUDE_CHILDREN",
      "elk.edgeRouting": "ORTHOGONAL",
      "elk.direction": "RIGHT",
    })
  })

  it("keeps collapsed summaries in the root scene without compound member groups", () => {
    const input = prepareTopologySceneInput(collapsedFarm01Graph())
    const elkGraph = buildElkSceneGraph(input, LANDSCAPE_PROFILE)

    expect(elkGraph.children.some((child) => child.id === input.groups[0].gatewayId)).toEqual(true)
    expect(input.groups.every((group) => findElkNode(elkGraph, group.id) === null)).toEqual(true)
  })

  it("decodes edge section points from edge.container coordinates", () => {
    const decoded = decodeElkScene(containerRelativeElkResult(), containerRelativeSceneInput())

    expect(decoded.nodes.find((node) => node.id === "gateway").center).toEqual({x: 245, y: 155})
    expect(decoded.routes.find((route) => route.id === "trunk").points).toEqual([
      {x: 60, y: 40},
      {x: 180, y: 40},
      {x: 220, y: 140},
    ])
    expect(validateTopologyScene(decoded)).toEqual({ok: true, errors: []})
  })

  it.each([
    ["missing source", undefined, ["gateway"]],
    ["extra source", ["anchor", "unknown"], ["gateway"]],
    ["missing target", ["anchor"], undefined],
    ["extra target", ["anchor"], ["gateway", "unknown"]],
    ["swapped endpoints", ["gateway"], ["anchor"]],
    ["unknown source", ["unknown"], ["gateway"]],
    ["unknown target", ["anchor"], ["unknown"]],
  ])("rejects a rendered ELK edge with %s bindings", (_description, sources, targets) => {
    const elkResult = containerRelativeElkResult()
    elkResult.edges[0].sources = sources
    elkResult.edges[0].targets = targets

    const scene = decodeElkScene(elkResult, containerRelativeSceneInput())
    const result = validateTopologyScene(scene)

    expect(result.ok).toEqual(false)
    expect(result.errors.some((error) => error.includes("endpoint binding"))).toEqual(true)
  })

  it("rejects an expected expanded group when ELK returns its nodes as root leaves", () => {
    const elkResult = containerRelativeElkResult()
    elkResult.children = elkResult.children.filter((child) => child.id !== "group")
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
    expect(validateTopologyScene(separated)).toEqual({ok: true, errors: []})
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

      expect(validateTopologyScene(first)).toEqual({ok: true, errors: []})
      expect(first.routes).toHaveLength(32)
      expect(normalizeScene(second)).toEqual(normalizeScene(first))
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
    expect(collisions).toEqual([])
  })
})
