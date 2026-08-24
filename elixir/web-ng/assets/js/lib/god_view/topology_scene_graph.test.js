import {describe, expect, it} from "vitest"

import {
  FARM01_EXPECTED,
  collapsedFarm01Graph,
  expandedFarm01Graph,
  reverseGraphArrays,
} from "./fixtures/farm01_topology_regression"
import {canonicalRenderedRelationId, prepareTopologySceneInput} from "./topology_scene_graph"

describe("topology_scene_graph", () => {
  it("preserves the farm01 expansion semantic delta without adding rendered routes", () => {
    const collapsed = prepareTopologySceneInput(collapsedFarm01Graph())
    const expanded = prepareTopologySceneInput(expandedFarm01Graph())

    expect(collapsed.manifest).toMatchObject(FARM01_EXPECTED.collapsed)
    expect(expanded.manifest).toMatchObject(FARM01_EXPECTED.expanded)
    expect(expanded.nodes.filter((node) => node.kind === "endpoint-member")).toHaveLength(24)
    expect(expanded.renderedRelations).toHaveLength(collapsed.renderedRelations.length)
  })

  it("canonicalizes relation identity independently of input order", () => {
    const forward = prepareTopologySceneInput(expandedFarm01Graph())
    const shuffled = prepareTopologySceneInput(reverseGraphArrays(expandedFarm01Graph()))

    expect(shuffled).toEqual(forward)
  })

  it("uses an undirected stable route identity with sorted semantic relation ids", () => {
    const scene = prepareTopologySceneInput({
      nodes: [
        {id: "zulu", details: {}},
        {id: "alpha", details: {}},
      ],
      edges: [
        {source: 0, target: 1, topologyClass: "backbone", label: "primary"},
        {id: "edge-01", source: 1, target: 0, topologyClass: "backbone", label: "reverse"},
      ],
    })

    expect(canonicalRenderedRelationId("zulu", "alpha")).toEqual("rendered:alpha|zulu")
    expect(scene.renderedRelations).toEqual([
      {
        id: "rendered:alpha|zulu",
        sourceId: "alpha",
        targetId: "zulu",
        relationIds: ["edge-01", "semantic:alpha|zulu|backbone|primary"],
      },
    ])
  })

  it("keeps expanded members as layout-only gateway constraints", () => {
    const scene = prepareTopologySceneInput(expandedFarm01Graph())
    const group = scene.groups.find((candidate) => candidate.expanded)

    expect(group).toMatchObject({
      id: "cluster:endpoints:farm01:gateway-01",
      anchorId: "farm01:gateway-01",
      gatewayId: "farm01:endpoint-summary-01",
      expanded: true,
    })
    expect(group.memberIds).toHaveLength(24)
    expect(scene.nodes.find((node) => node.id === group.gatewayId)?.render).toEqual(false)
    expect(scene.layoutRelations).toHaveLength(24)
    expect(scene.layoutRelations.every((relation) => relation.sourceId === group.gatewayId)).toEqual(true)
  })
})
