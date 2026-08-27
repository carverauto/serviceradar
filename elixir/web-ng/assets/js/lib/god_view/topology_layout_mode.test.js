import {describe, expect, it} from "vitest"

import {
  hasManagedTopologyScene,
  isDetailScene,
  isOverviewScene,
  hasExpandedCluster,
  topologySemanticLevel,
} from "./topology_layout_mode"

describe("topology_layout_mode", () => {
  const scene = {
    nodes: [],
    routes: [],
    bounds: {minX: 0, minY: 0, maxX: 0, maxY: 0},
  }

  it("normalizes only the explicit bounded-detail marker to detail", () => {
    expect(topologySemanticLevel()).toBe("overview")
    expect(topologySemanticLevel({})).toBe("overview")
    expect(topologySemanticLevel({_topologySemanticLevel: "overview"})).toBe("overview")
    expect(topologySemanticLevel({_topologySemanticLevel: "DETAIL"})).toBe("overview")
    expect(topologySemanticLevel({_topologySemanticLevel: "detail"})).toBe("detail")
  })

  it("recognizes only radial overview and Layered detail scenes as managed", () => {
    const overview = {_layoutMode: "elk-radial-overview", _topologyScene: scene}
    const detail = {_layoutMode: "elk-scene-detail", _topologyScene: scene}

    expect(isOverviewScene(overview)).toBe(true)
    expect(isDetailScene(detail)).toBe(true)
    expect(hasManagedTopologyScene(overview)).toBe(true)
    expect(hasManagedTopologyScene(detail)).toBe(true)
  })

  it.each([
    {_layoutMode: "elk-scene", _topologyScene: scene},
    {_layoutMode: "elk-radial-overview-error", _topologyScene: scene},
    {_layoutMode: "elk-scene-detail-error", _topologyScene: scene},
    {_layoutMode: "elk-radial-overview"},
    {_layoutMode: "elk-scene-detail"},
    {_layoutMode: "elk-radial-overview", _topologyScene: "malformed"},
    {_layoutMode: "elk-scene-detail", _topologyScene: true},
    {_layoutMode: "elk-radial-overview", _topologyScene: []},
    {_layoutMode: "elk-scene-detail", _topologyScene: {}},
    {_layoutMode: "elk-radial-overview", _topologyScene: {...scene, nodes: {}}},
    {_layoutMode: "elk-scene-detail", _topologyScene: {...scene, routes: null}},
    {_layoutMode: "elk-radial-overview", _topologyScene: {...scene, bounds: {}}},
    {
      _layoutMode: "elk-scene-detail",
      _topologyScene: {...scene, bounds: {minX: 0, minY: 0, maxX: Number.NaN, maxY: 0}},
    },
    {
      _layoutMode: "elk-radial-overview",
      _topologyScene: {...scene, bounds: {minX: 1, minY: 0, maxX: 0, maxY: 0}},
    },
  ])("rejects legacy, error, and sceneless modes as managed scene authorities", (graph) => {
    expect(hasManagedTopologyScene(graph)).toBe(false)
    expect(isOverviewScene(graph)).toBe(false)
    expect(isDetailScene(graph)).toBe(false)
  })
})

describe("topology_layout_mode expansion-derived semantic level", () => {
  // An expanded cluster elaborates the radial atlas in place, so it must NOT promote the
  // graph to the bounded-detail scene -- that re-laid the whole backbone with the layered
  // algorithm. `hasExpandedCluster` still reports the expansion for the label-admission
  // paths, which degrade rather than failing closed on an unbounded scene.
  it("keeps an expanded cluster in the radial atlas", () => {
    const expanded = {
      nodes: [
        {id: "gw", details: {cluster_kind: "endpoint-anchor"}},
        {id: "cluster", details: {cluster_kind: "endpoint-summary", cluster_expanded: true}},
      ],
    }

    expect(topologySemanticLevel(expanded)).toBe("overview")
    expect(hasExpandedCluster(expanded)).toBe(true)
  })

  it("keeps a fully collapsed graph in radial overview", () => {
    expect(topologySemanticLevel({
      nodes: [
        {id: "gw", details: {cluster_kind: "endpoint-anchor"}},
        {id: "cluster", details: {cluster_kind: "endpoint-summary", cluster_expanded: false}},
      ],
    })).toBe("overview")
  })

  it("ignores malformed node collections when deriving the semantic level", () => {
    expect(topologySemanticLevel({nodes: "malformed"})).toBe("overview")
    expect(topologySemanticLevel({nodes: [null, 7, {details: null}]})).toBe("overview")
  })
})
