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
            startPoint: {x: 0, y: 0},
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
      {x: 100, y: 40},
      {x: 180, y: 40},
      {x: 220, y: 140},
    ])
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
})
