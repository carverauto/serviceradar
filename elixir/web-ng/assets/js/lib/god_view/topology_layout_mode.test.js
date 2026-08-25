import {describe, expect, it} from "vitest"

import {
  hasManagedTopologyScene,
  isDetailScene,
  isOverviewScene,
  topologySemanticLevel,
} from "./topology_layout_mode"

describe("topology_layout_mode", () => {
  it("normalizes only the explicit bounded-detail marker to detail", () => {
    expect(topologySemanticLevel()).toBe("overview")
    expect(topologySemanticLevel({})).toBe("overview")
    expect(topologySemanticLevel({_topologySemanticLevel: "overview"})).toBe("overview")
    expect(topologySemanticLevel({_topologySemanticLevel: "DETAIL"})).toBe("overview")
    expect(topologySemanticLevel({_topologySemanticLevel: "detail"})).toBe("detail")
  })

  it("recognizes only radial overview and Layered detail scenes as managed", () => {
    const overview = {_layoutMode: "elk-radial-overview", _topologyScene: {routes: []}}
    const detail = {_layoutMode: "elk-scene-detail", _topologyScene: {routes: []}}

    expect(isOverviewScene(overview)).toBe(true)
    expect(isDetailScene(detail)).toBe(true)
    expect(hasManagedTopologyScene(overview)).toBe(true)
    expect(hasManagedTopologyScene(detail)).toBe(true)
  })

  it.each([
    {_layoutMode: "elk-scene", _topologyScene: {routes: []}},
    {_layoutMode: "elk-radial-overview-error", _topologyScene: {routes: []}},
    {_layoutMode: "elk-scene-detail-error", _topologyScene: {routes: []}},
    {_layoutMode: "elk-radial-overview"},
    {_layoutMode: "elk-scene-detail"},
    {_layoutMode: "elk-radial-overview", _topologyScene: "malformed"},
    {_layoutMode: "elk-scene-detail", _topologyScene: true},
  ])("rejects legacy, error, and sceneless modes as managed scene authorities", (graph) => {
    expect(hasManagedTopologyScene(graph)).toBe(false)
    expect(isOverviewScene(graph)).toBe(false)
    expect(isDetailScene(graph)).toBe(false)
  })
})
