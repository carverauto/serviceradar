import {describe, expect, it} from "vitest"
import ELK from "elkjs/lib/elk.bundled.js"

import {routeStrokeHitsBox} from "./acceptance_geometry_assertions"
import {bindApi, createStateBackedContext} from "./api_helpers"
import {collapsedFarm01Graph} from "./fixtures/farm01_topology_regression"
import {PORTRAIT_PROFILE, applyTopologySceneToGraph, layoutTopologyScene} from "./layout_elk_scene"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"
import {godViewRenderingGraphViewMethods} from "./rendering_graph_view_methods"
import {managedNodeVisualRole} from "./rendering_managed_visual_density"
import {prepareTopologySceneInput} from "./topology_scene_graph"

function concurrentExpandedFarm01Graph() {
  const graph = collapsedFarm01Graph()
  const expanded = new Set([1, 2])
  const nodes = graph.nodes.map((node) => {
    const ordinal = Number(String(node.id).match(/endpoint-summary-(\d+)$/)?.[1])
    return expanded.has(ordinal)
      ? {...node, details: {...node.details, cluster_expanded: true}}
      : node
  })
  const edges = [...graph.edges]

  for (const ordinal of expanded) {
    const suffix = String(ordinal).padStart(2, "0")
    const anchorId = `farm01:gateway-${suffix}`
    const clusterId = `cluster:endpoints:${anchorId}`
    const anchorIndex = nodes.findIndex((node) => node.id === anchorId)
    const offset = nodes.length
    for (let memberOrdinal = 1; memberOrdinal <= 24; memberOrdinal += 1) {
      const memberSuffix = String(memberOrdinal).padStart(2, "0")
      nodes.push({
        id: `farm01:endpoint-member-${suffix}-${memberSuffix}`,
        label: `Farm01 gateway ${ordinal} endpoint ${memberOrdinal}`,
        state: 1,
        operUp: 1,
        details: {
          cluster_id: clusterId,
          cluster_kind: "endpoint-member",
          cluster_anchor_id: anchorId,
          cluster_expanded: true,
        },
      })
      edges.push({
        id: `farm01:attachment:member-${suffix}-${memberSuffix}`,
        source: anchorIndex,
        target: offset + memberOrdinal - 1,
        topologyClass: "endpoints",
        evidenceClass: "endpoint-attachment",
      })
    }
  }

  return {nodes, edges}
}

function project(point, viewState, width, height) {
  const scale = 2 ** viewState.zoom
  return [
    (width / 2) + ((Number(point.x) - viewState.target[0]) * scale),
    (height / 2) + ((Number(point.y) - viewState.target[1]) * scale),
  ]
}

function overlaps(left, right, epsilon = 0.5) {
  return Math.min(left.right, right.right) - Math.max(left.left, right.left) > epsilon
    && Math.min(left.bottom, right.bottom) - Math.max(left.top, right.top) > epsilon
}

describe("managed topology visual density", () => {
  it("keeps the canonical concurrent portrait scene truthful at overview density", async () => {
    const source = concurrentExpandedFarm01Graph()
    const scene = await layoutTopologyScene(prepareTopologySceneInput(source), {
      engine: new ELK(),
      profile: PORTRAIT_PROFILE,
    })
    const graph = {shape: "local", ...applyTopologySceneToGraph(source, scene)}
    const width = 800
    const height = 1000
    const safeRect = {left: 0, top: 0, right: 800, bottom: 960}
    const state = {
      animationPhase: 0,
      deck: {setProps() {}},
      hasAutoFit: false,
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: width, clientHeight: height},
      topologyLabelSafeRect: safeRect,
      topologyLabelMeasureText: (text) => ({width: String(text).length * 6, height: 12}),
    }
    const ctx = createStateBackedContext(state, {
      setZoomTier() {},
      resolveZoomTier: () => "local",
    })
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState(graph)

    const scale = 2 ** state.viewState.zoom
    const selection = ctx.managedVisualDensityForViewScale(graph, scale)
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(selection.managedVisualDensity).toBe("overview")
    expect(selection.constraints.detail.scale).toBeCloseTo(40 / 208, 12)
    expect(selection.constraints.detail.limitingRolePair).toEqual(["member", "member"])
    expect([
      selection.constraints.detail.leftId,
      selection.constraints.detail.rightId,
    ].sort()).toEqual([
      "farm01:endpoint-member-01-01",
      "farm01:endpoint-member-01-02",
    ])
    expect(selection.constraints.overview.scale).toBeCloseTo(22 / 224, 12)
    expect(selection.constraints.overview.limitingRolePair).toEqual(["ordinary", "anchor"])
    expect(scale - selection.constraints.overview.scale).toBeGreaterThan(0)
    // These are projected pixel margins at the smallest supported concurrent
    // portrait safe rectangle. They keep fixed-width glyphs and 10px routes
    // disjoint after browser rounding without weakening the renderer floors.
    expect((224 * scale) - 22).toBeGreaterThan(0.5)
    expect((208 * scale) - 20).toBeGreaterThan(1)
    expect((104 * scale) - 10).toBeGreaterThan(0.5)

    const graphNodeById = new Map(graph.nodes.map((node) => [node.id, node]))
    const glyphs = scene.nodes.flatMap((sceneNode) => {
      if (sceneNode.render === false) return []
      const node = graphNodeById.get(sceneNode.id)
      const role = managedNodeVisualRole(node)
      const options = {managedVisualDensity: "overview"}
      const coreRadius = ctx.nodeCoreRadiusPixels(node)
      const ringRadius = ctx.nodeRingRadiusPixels(node, options)
      const ringOuterRadius = ringRadius + (node.selected ? 1 : 0.5)
      const outerRadius = ctx.nodeVisibleOuterRadiusPixels(node, options)
      const [x, y] = project(sceneNode.center, state.viewState, width, height)
      expect(coreRadius, `${sceneNode.id} ${role} core`).toBeLessThanOrEqual(outerRadius)
      expect(ringOuterRadius, `${sceneNode.id} ${role} ring outline`).toBeLessThanOrEqual(outerRadius)
      if (role === "ordinary" || role === "member") {
        expect(outerRadius, `${sceneNode.id} ${role} overview outer`).toBeLessThanOrEqual(10)
      }
      return [{
        nodeId: sceneNode.id,
        role,
        left: x - outerRadius,
        top: y - outerRadius,
        right: x + outerRadius,
        bottom: y + outerRadius,
      }]
    })
    expect(new Set(glyphs.map((glyph) => glyph.role))).toEqual(
      new Set(["summary", "anchor", "member", "ordinary"]),
    )

    for (let left = 0; left < glyphs.length; left += 1) {
      expect(glyphs[left].left).toBeGreaterThanOrEqual(safeRect.left - 1)
      expect(glyphs[left].top).toBeGreaterThanOrEqual(safeRect.top - 1)
      expect(glyphs[left].right).toBeLessThanOrEqual(safeRect.right + 1)
      expect(glyphs[left].bottom).toBeLessThanOrEqual(safeRect.bottom + 1)
      for (let right = left + 1; right < glyphs.length; right += 1) {
        expect(
          overlaps(glyphs[left], glyphs[right]),
          `${glyphs[left].nodeId}(${glyphs[left].role}) overlaps ${glyphs[right].nodeId}(${glyphs[right].role})`,
        ).toBe(false)
      }
    }

    const glyphById = new Map(glyphs.map((glyph) => [glyph.nodeId, glyph]))
    for (const route of scene.physicalRoutes) {
      const renderedRoute = {
        sourceId: route.sourceId,
        targetId: route.targetId,
        strokeWidth: ctx.topologyRouteStrokeWidth(route, {managedVisualDensity: "overview"}),
        projectedPoints: route.points.map((point) => project(point, state.viewState, width, height)),
      }
      expect(renderedRoute.strokeWidth).toBe(10)
      for (const glyph of glyphById.values()) {
        if ((route.incidentNodeIds || [route.sourceId, route.targetId]).includes(glyph.nodeId)) continue
        expect(
          routeStrokeHitsBox(renderedRoute, glyph),
          `${renderedRoute.sourceId}->${renderedRoute.targetId} hits ${glyph.nodeId}(${glyph.role})`,
        ).toBe(false)
      }
    }
  }, 20_000)
})
