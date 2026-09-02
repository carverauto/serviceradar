import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"

function topologyScene(overrides = {}) {
  return {
    nodes: [],
    routes: [],
    bounds: {minX: 0, minY: 0, maxX: 0, maxY: 0},
    ...overrides,
  }
}

describe("rendering_graph_layer_node_methods", () => {
  it("buildNodeAndLabelLayers makes node labels pickable", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
      canvas: {getBoundingClientRect: () => ({width: 400, height: 300})},
      deck: {getViewports: () => [{width: 400, height: 300, project: ([x, y]) => [200 + x, 150 + y]}]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods), {
      nodeColor: () => [255, 0, 0, 255],
      nodeNeutralColor: () => [128, 128, 128, 255],
      connectionKindFromLabel: () => "LINK",
    })

    const layers = ctx.buildNodeAndLabelLayers(
      {shape: "local"},
      [{index: 0, id: "sr:test", label: "test", position: [0, 0, 0], state: 2, operUp: 1, clusterCount: 1}],
      [],
    )

    const labelLayer = layers.find((layer) => layer.id === "god-view-node-labels")
    const hitboxLayer = layers.find((layer) => layer.id === "god-view-nodes-hitbox")
    const haloLayer = layers.find((layer) => layer.id === "god-view-nodes-halo")

    expect(hitboxLayer).toBeTruthy()
    expect(hitboxLayer.props.pickable).toEqual(true)
    expect(haloLayer).toBeTruthy()
    expect(haloLayer.props.pickable).toEqual(true)
    expect(labelLayer).toBeTruthy()
    expect(labelLayer.props.pickable).toEqual(true)
  })

  it("projects budgeted candidates and routes into the measured safe rectangle before building TextLayer", () => {
    const project = vi.fn(([x, y]) => [x, y])
    const scene = topologyScene({
      routes: [{
        id: "route:a-b",
        points: [{x: 65, y: 70}, {x: 135, y: 70}],
        metadata: {strokeWidth: 2},
      }],
    })
    const state = {
      animationPhase: 0,
      hoveredNodeIndex: null,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
      el: {id: "god-view"},
      canvas: {getBoundingClientRect: () => ({width: 220, height: 220})},
      deck: {getViewports: () => [{width: 220, height: 220, project}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 220, bottom: 220},
      topologyLabelMeasureText: () => ({width: 40, height: 12}),
    }
    const sceneBefore = JSON.stringify(scene)
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods), {
      nodeColor: () => [255, 0, 0, 255],
      nodeNeutralColor: () => [128, 128, 128, 255],
      connectionKindFromLabel: () => "LINK",
    })

    const effective = {shape: "local", _layoutMode: "elk-radial-overview", _topologyScene: scene}
    const layers = ctx.buildNodeAndLabelLayers(
      effective,
      [{index: 0, id: "router", label: "Router", position: [100, 100, 0], state: 2, operUp: 1, clusterCount: 1, details: {}}],
      [{midpoint: [100, 70, 0], connectionLabel: "LINK"}],
    )
    const labelLayer = layers.find((layer) => layer.id === "god-view-node-labels")
    const edgeLabelLayer = layers.find((layer) => layer.id === "god-view-edge-labels")
    const [labelDatum] = labelLayer.props.data

    expect(project).toHaveBeenCalledTimes(3)
    expect(labelDatum.labelAdmission).toEqual({
      nodeId: "router",
      anchor: "right",
      box: {left: 120, top: 90, right: 168, bottom: 110},
      pixelOffset: [24, 0],
      textAnchor: "start",
      alignmentBaseline: "center",
    })
    expect(labelLayer.props.getPixelOffset(labelDatum)).toEqual([24, 0])
    expect(labelLayer.props.getTextAnchor(labelDatum)).toEqual("start")
    expect(labelLayer.props.getAlignmentBaseline(labelDatum)).toEqual("center")
    expect(edgeLabelLayer).toBeUndefined()
    expect(effective._topologyScene).toBe(scene)
    expect(JSON.stringify(scene)).toEqual(sceneBefore)
  })

  it("preserves route endpoints and chooses a route-clear diagonal for four-way fanout", () => {
    const scene = topologyScene({
      routes: [
        {id: "north", sourceId: "router", targetId: "north", points: [{x: 100, y: 100}, {x: 100, y: 50}]},
        {id: "east", sourceId: "router", targetId: "east", points: [{x: 100, y: 100}, {x: 170, y: 100}]},
        {id: "south", sourceId: "router", targetId: "south", points: [{x: 100, y: 100}, {x: 100, y: 150}]},
        {id: "west", sourceId: "router", targetId: "west", points: [{x: 100, y: 100}, {x: 30, y: 100}]},
      ],
    })
    const state = {
      deck: {getViewports: () => [{width: 220, height: 220, project: ([x, y]) => [x, y]}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 220, bottom: 220},
      topologyLabelMeasureText: () => ({width: 40, height: 12}),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))
    const graph = {shape: "local", _layoutMode: "elk-radial-overview", _topologyScene: scene}
    const labels = [{
      id: "router",
      label: "Router",
      position: [100, 100, 0],
      state: 2,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }]

    const result = ctx.admitNodeLabelsForViewport(graph, labels, labels, {
      requiredLabelIds: ["router"],
    })

    expect(result.missingRequiredLabelIds).toEqual([])
    expect(result.admitted).toMatchObject([{nodeId: "router", anchor: "top-right"}])
  })

  it("recomputes admission from a changed Deck viewport without mutating or laying out the scene", () => {
    let projectedY = 100
    const project = vi.fn(([x]) => [x, projectedY])
    const scene = topologyScene()
    const layoutTopologyScene = vi.fn()
    const state = {
      hoveredNodeIndex: null,
      canvas: {getBoundingClientRect: () => ({width: 220, height: 220})},
      deck: {getViewports: () => [{width: 220, height: 220, project}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 220, bottom: 220},
      topologyLabelMeasureText: () => ({width: 40, height: 12}),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods), {
      layoutTopologyScene,
    })
    const effective = {shape: "local", _layoutMode: "elk-radial-overview", _topologyScene: scene}
    const labels = [{
      index: 0,
      id: "router",
      label: "Router",
      position: [100, 100, 0],
      state: 2,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }]

    const first = ctx.admitNodeLabelsForViewport(effective, labels)
    projectedY = 30
    const second = ctx.admitNodeLabelsForViewport(effective, labels)

    expect(first.admitted.map((item) => item.anchor)).toEqual(["top"])
    expect(second.admitted.map((item) => item.anchor)).toEqual(["right"])
    expect(project).toHaveBeenCalledTimes(2)
    expect(layoutTopologyScene).not.toHaveBeenCalled()
    expect(effective._topologyScene).toBe(scene)
  })

  it("selectNodeLabels suppresses endpoint-member and topology-sighting labels under budget pressure", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {id: "summary", label: "20 endpoints", clusterCount: 20, pps: 10, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "summary-2", label: "16 endpoints", clusterCount: 16, pps: 9, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "summary-3", label: "8 endpoints", clusterCount: 8, pps: 8, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "switch", label: "Switch", clusterCount: 1, pps: 1000, state: 2, selected: false, details: {}},
      {id: "endpoint-1", label: "192.0.2.10", clusterCount: 1, pps: 0, state: 2, selected: false, details: {cluster_kind: "endpoint-member"}},
      {id: "ghost", label: "192.0.2.11", clusterCount: 1, pps: 0, state: 3, selected: false, details: {identity_source: "mapper_topology_sighting"}},
      {id: "sr:sighting", label: "sr:deadbeef", clusterCount: 1, pps: 50, state: 2, selected: false, details: {identity_source: "mapper_topology_sighting"}},
      {id: "sr:a0", label: "sr:a0", clusterCount: 1, pps: 100, state: 2, selected: false, details: {}},
      {id: "selected-endpoint", label: "Laptop", clusterCount: 1, pps: 0, state: 2, selected: true, details: {cluster_kind: "endpoint-member"}},
    ], "local")

    expect(labels.map((node) => node.id)).toEqual([
      "selected-endpoint",
      "switch",
      "ghost",
      "summary",
      "summary-2",
      "summary-3",
    ])
  })

  it("selectNodeLabels enforces a per-shape budget", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels(
      Array.from({length: 24}, (_, index) => ({
        id: `node-${index}`,
        label: `Node ${index}`,
        clusterCount: 1,
        pps: 24 - index,
        state: 2,
        selected: false,
        details: {},
      })),
      "global",
    )

    expect(labels).toHaveLength(8)
    expect(labels[0].id).toEqual("node-0")
  })

  it("selectNodeLabels still preserves explicitly selected opaque identities", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {id: "sr:hidden", label: "sr:hidden", clusterCount: 1, pps: 0, state: 3, selected: false, details: {}},
      {id: "sr:selected", label: "sr:selected", clusterCount: 1, pps: 0, state: 3, selected: true, details: {}},
      {id: "router", label: "Router", clusterCount: 1, pps: 100, state: 2, selected: false, details: {}},
    ], "local")

    expect(labels.map((node) => node.id)).toEqual(["sr:selected", "router"])
  })

  it("selectNodeLabels gives a focused opaque identity the same admission candidacy as selection", () => {
    const state = {
      hoveredNodeIndex: 7,
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {index: 7, id: "sr:focused", label: "sr:focused", clusterCount: 1, pps: 0, state: 3, selected: false, details: {}},
      {index: 8, id: "router", label: "Router", clusterCount: 1, pps: 100, state: 2, selected: false, details: {}},
    ], "local")

    expect(labels.map((node) => node.id)).toEqual(["sr:focused", "router"])
  })

  it("selectNodeLabels always keeps topology-unplaced nodes visible", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      ...Array.from({length: 24}, (_, index) => ({
        id: `node-${index}`,
        label: `Node ${index}`,
        clusterCount: 1,
        pps: 50 - index,
        state: 2,
        selected: false,
        details: {},
      })),
      {
        id: "vjunos",
        label: "vJunos",
        clusterCount: 1,
        pps: 0,
        state: 3,
        selected: false,
        details: {topology_unplaced: true},
      },
    ], "global")

    expect(labels.map((node) => node.id)).toContain("vjunos")
  })

  it("selectNodeLabels reserves budget for backbone labels before endpoint summaries", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {id: "summary", label: "20 endpoints", clusterCount: 20, pps: 10, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "summary-2", label: "10 endpoints", clusterCount: 10, pps: 9, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "router-a", label: "Router A", clusterCount: 1, pps: 200, state: 2, selected: false, details: {}},
      {id: "switch-b", label: "Switch B", clusterCount: 1, pps: 180, state: 2, selected: false, details: {}},
      {id: "ap-c", label: "AP C", clusterCount: 1, pps: 160, state: 2, selected: false, details: {cluster_kind: "endpoint-anchor"}},
    ], "local")

    expect(labels.map((node) => node.id).slice(0, 3).sort()).toEqual(["ap-c", "router-a", "switch-b"])
  })

  it("selectNodeLabels includes expanded endpoint-member labels with a bounded budget", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {id: "router-a", label: "Router A", clusterCount: 1, pps: 200, state: 2, selected: false, details: {}},
      ...Array.from({length: 8}, (_, index) => ({
        id: `endpoint-${index + 1}`,
        label: `192.0.2.${index + 1}`,
        clusterCount: 1,
        pps: 20 - index,
        state: 2,
        selected: false,
        details: {
          cluster_kind: "endpoint-member",
          cluster_expanded: true,
          identity_source: "mapper_topology_sighting",
        },
      })),
    ], "local")

    expect(labels.map((node) => node.id)).toEqual([
      "endpoint-1",
      "endpoint-2",
      "endpoint-3",
      "endpoint-4",
      "endpoint-5",
      "endpoint-6",
      "endpoint-7",
      "endpoint-8",
      "router-a",
    ])
  })

  it("selectNodeLabels caps expanded endpoint-member labels so a large cluster stays readable", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {id: "router-a", label: "Router A", clusterCount: 1, pps: 200, state: 2, selected: false, details: {}},
      ...Array.from({length: 60}, (_, index) => ({
        id: `endpoint-${index + 1}`,
        label: `192.0.2.${index + 1}`,
        clusterCount: 1,
        pps: 20 - index,
        state: 2,
        selected: false,
        details: {
          cluster_kind: "endpoint-member",
          cluster_expanded: true,
        },
      })),
    ], "local")

    expect(labels.filter((node) => String(node.id).startsWith("endpoint-"))).toHaveLength(48)
    expect(labels.at(0).id).toEqual("endpoint-1")
    expect(labels.map((node) => node.id)).toContain("router-a")
  })

  it("selectNodeLabels hides the census bubble label once a cluster is expanded", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {
        id: "summary",
        label: "42 endpoints",
        clusterCount: 42,
        pps: 10,
        state: 3,
        selected: false,
        details: {cluster_kind: "endpoint-summary", cluster_expanded: true},
      },
      {id: "router-a", label: "Router A", clusterCount: 1, pps: 200, state: 2, selected: false, details: {}},
    ], "local")

    expect(labels.map((node) => node.id)).toEqual(["router-a"])
  })

  it("nodeLabelPixelOffset places expanded roster labels beside the panel", () => {
    const ctx = createStateBackedContext({}, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    expect(ctx.nodeLabelPixelOffset({details: {cluster_panel_side: "right"}})).toEqual([14, 0])
    expect(ctx.nodeLabelTextAnchor({details: {cluster_panel_side: "right"}})).toEqual("start")
    expect(ctx.nodeLabelPixelOffset({details: {cluster_panel_side: "left"}})).toEqual([-14, 0])
    expect(ctx.nodeLabelTextAnchor({details: {cluster_panel_side: "left"}})).toEqual("end")
    expect(ctx.nodeLabelPixelOffset({details: {}})).toEqual([0, -16])
  })

  it("topologyRouteStrokeWidth conservatively protects the widest visible routed stroke", () => {
    const state = {layers: {mantle: true, crust: true}}
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    expect(ctx.topologyRouteStrokeWidth({metadata: {strokeWidth: 9}})).toEqual(9)
    expect(ctx.topologyRouteStrokeWidth({})).toEqual(38)
    state.layers.mantle = false
    expect(ctx.topologyRouteStrokeWidth({})).toEqual(12)
    state.layers.crust = false
    expect(ctx.topologyRouteStrokeWidth({})).toEqual(0)
  })

  it("uses one truthful managed visual-density contract for glyphs, rings, routes, and labels", () => {
    const state = {
      animationPhase: Math.PI / 4,
      layers: {mantle: true, crust: true},
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))
    const member = {
      id: "member",
      selected: true,
      clusterCount: 1,
      details: {cluster_kind: "endpoint-member", cluster_expanded: true},
    }
    const summary = {
      id: "summary",
      clusterCount: 20,
      details: {cluster_kind: "endpoint-summary"},
    }
    const anchor = {
      id: "anchor",
      clusterCount: 1,
      details: {cluster_kind: "endpoint-anchor"},
    }

    expect(ctx.nodeVisibleOuterRadiusPixels(member, {managedVisualDensity: "overview"})).toBe(10)
    expect(ctx.nodeVisibleOuterRadiusPixels(member, {managedVisualDensity: "detail"})).toBe(20)
    expect(ctx.nodeCoreRadiusPixels(member)).toBeLessThanOrEqual(10)
    expect(ctx.nodeRingRadiusPixels(member, {managedVisualDensity: "overview"})).toBeLessThanOrEqual(9)
    expect(
      ctx.nodeRingRadiusPixels(member, {managedVisualDensity: "overview"}) + 1,
    ).toBeLessThanOrEqual(ctx.nodeVisibleOuterRadiusPixels(member, {managedVisualDensity: "overview"}))
    expect(ctx.nodeVisibleOuterRadiusPixels(summary, {managedVisualDensity: "overview"})).toBe(20)
    expect(ctx.nodeVisibleOuterRadiusPixels(anchor, {managedVisualDensity: "overview"})).toBe(12)
    expect(ctx.nodeVisibleOuterRadiusPixels(summary, {managedVisualDensity: "detail"})).toBe(41.375)
    expect(ctx.nodeVisibleOuterRadiusPixels(anchor, {managedVisualDensity: "detail"})).toBe(20)
    expect(ctx.nodeCoreRadiusPixels(summary, {managedVisualDensity: "overview"})).toBeLessThanOrEqual(20)
    expect(ctx.nodeCoreRadiusPixels(anchor, {managedVisualDensity: "overview"})).toBeLessThanOrEqual(12)
    expect(ctx.topologyRouteStrokeWidth({}, {managedVisualDensity: "overview"})).toBe(10)
    expect(ctx.topologyRouteStrokeWidth({}, {managedVisualDensity: "detail"})).toBe(12)
    expect(ctx.topologyRouteStrokeWidth({})).toBe(38)

    const labels = ctx.selectNodeLabels(
      Array.from({length: 24}, (_, index) => ({
        id: `node-${index}`,
        label: `Node ${index}`,
        details: {},
      })),
      "regional",
      {managedVisualDensity: "overview"},
    )
    expect(labels).toHaveLength(24)
  })

  it("invalidates every density-sensitive node accessor with unchanged layer data", () => {
    const nodeData = [{
      index: 0,
      id: "router",
      label: "Router",
      position: [100, 100, 0],
      state: 2,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }]
    const state = {
      animationPhase: 3.25,
      managedTopologyVisualDensity: "overview",
      layers: {mantle: true, crust: true, atmosphere: false, security: true},
      visual: {
        label: [255, 255, 255, 255],
        edgeLabel: [200, 200, 200, 255],
        nodeFill: [80, 120, 180, 255],
        particleBlend: [770, 771],
      },
      canvas: {getBoundingClientRect: () => ({width: 220, height: 220})},
      deck: {getViewports: () => [{width: 220, height: 220, project: ([x, y]) => [x, y]}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 220, bottom: 220},
      topologyLabelMeasureText: () => ({width: 40, height: 12}),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods), {
      nodeColor: () => [255, 0, 0, 255],
      nodeNeutralColor: () => [128, 128, 128, 255],
    })
    const effective = {
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologyScene: topologyScene(),
    }

    const overview = ctx.buildNodeAndLabelLayers(effective, nodeData, [])
    state.managedTopologyVisualDensity = "detail"
    const detail = ctx.buildNodeAndLabelLayers(effective, nodeData, [])
    const layer = (layers, id) => layers.find((candidate) => candidate.id === id)

    for (const id of ["god-view-nodes-halo", "god-view-nodes-hitbox", "god-view-nodes"]) {
      expect(layer(overview, id).props.data).toBe(nodeData)
      expect(layer(detail, id).props.data).toBe(nodeData)
      expect(layer(overview, id).props.updateTriggers.getRadius).toBe("overview")
      expect(layer(detail, id).props.updateTriggers.getRadius).toBe("detail")
    }
    expect(layer(overview, "god-view-nodes-ring").props.updateTriggers.getRadius).toEqual([3.25, "overview"])
    expect(layer(detail, "god-view-nodes-ring").props.updateTriggers.getRadius).toEqual([3.25, "detail"])
  })

  it.each(["elk-radial-overview", "elk-scene-detail"])(
    "uses managed label density for font size in %s while semantic shape stays local",
    (layoutMode) => {
    const nodeData = [{
      index: 0,
      id: "router",
      label: "Router",
      position: [100, 100, 0],
      state: 2,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }]
    const state = {
      animationPhase: 0,
      managedTopologyVisualDensity: "overview",
      layers: {mantle: true, crust: true, atmosphere: false, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
      canvas: {getBoundingClientRect: () => ({width: 220, height: 220})},
      deck: {getViewports: () => [{width: 220, height: 220, project: ([x, y]) => [x, y]}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 220, bottom: 220},
      topologyLabelMeasureText: () => ({width: 40, height: 12}),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods), {
      nodeColor: () => [255, 0, 0, 255],
      nodeNeutralColor: () => [128, 128, 128, 255],
    })
    const effective = {
      shape: "local",
      _layoutMode: layoutMode,
      _topologyScene: {
        nodes: [],
        routes: [],
        bounds: {minX: 0, minY: 0, maxX: 0, maxY: 0},
      },
    }

    const overview = ctx.buildNodeAndLabelLayers(effective, nodeData, [])
    state.managedTopologyVisualDensity = "detail"
    const detail = ctx.buildNodeAndLabelLayers(effective, nodeData, [])
    const overviewLabels = overview.find((layer) => layer.id === "god-view-node-labels")
    const detailLabels = detail.find((layer) => layer.id === "god-view-node-labels")

    expect(overviewLabels.props.getSize).toBe(10)
    expect(overviewLabels.props.sizeMinPixels).toBe(8)
    expect(detailLabels.props.getSize).toBe(12)
    expect(detailLabels.props.sizeMinPixels).toBe(10)
    },
  )

  it.each([
    {semanticLevel: "overview", layoutMode: "elk-radial-overview", density: "overview"},
    {semanticLevel: "detail", layoutMode: "elk-scene-detail", density: "detail"},
  ])("renders every $semanticLevel semantic label despite disabled mantle and legacy shape gating", ({semanticLevel, layoutMode, density}) => {
    const nodeData = [
      {id: "sr:opaque", label: "sr:opaque", details: {}},
      {id: "endpoint-member", label: "192.0.2.10", details: {cluster_kind: "endpoint-member"}},
      {id: "endpoint-summary", label: "20 endpoints", clusterCount: 20, details: {cluster_kind: "endpoint-summary"}},
      {id: "expanded-member", label: "192.0.2.11", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
      {id: "router", label: "Router", details: {}},
    ].map((node, index) => ({
      index,
      position: [80 + (index * 170), 180, 0],
      state: 2,
      operUp: 1,
      clusterCount: node.clusterCount || 1,
      ...node,
    }))
    const state = {
      animationPhase: 0,
      hoveredNodeIndex: null,
      managedTopologyVisualDensity: density,
      layers: {mantle: false, crust: true, atmosphere: false, security: true},
      visual: {
        label: [255, 255, 255, 255],
        edgeLabel: [200, 200, 200, 255],
        nodeFill: [80, 120, 180, 255],
      },
      canvas: {getBoundingClientRect: () => ({width: 1000, height: 360})},
      deck: {getViewports: () => [{width: 1000, height: 360, project: ([x, y]) => [x, y]}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 360},
      topologyLabelMeasureText: () => ({width: 72, height: 12}),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods), {
      nodeColor: () => [255, 0, 0, 255],
      nodeNeutralColor: () => [128, 128, 128, 255],
    })
    const effective = {
      shape: "legacy-hidden-shape",
      _layoutMode: layoutMode,
      _topologySemanticLevel: semanticLevel,
      _topologyScene: topologyScene(),
    }

    const layers = ctx.buildNodeAndLabelLayers(effective, nodeData, [])
    const glyphIds = layers.find((layer) => layer.id === "god-view-nodes").props.data.map((node) => node.id).sort()
    const labelLayer = layers.find((layer) => layer.id === "god-view-node-labels")
    const labelIds = labelLayer?.props.data.map((node) => node.id).sort() || []

    expect(glyphIds).toEqual([
      "endpoint-member",
      "endpoint-summary",
      "expanded-member",
      "router",
      "sr:opaque",
    ])
    expect(labelIds).toEqual(glyphIds)
  })

  it.each([
    {mantle: false, shape: "local"},
    {mantle: true, shape: "legacy-hidden-shape"},
  ])("preserves nonmanaged label gating for mantle=$mantle and shape=$shape", ({mantle, shape}) => {
    const nodeData = [{
      index: 0,
      id: "legacy-router",
      label: "Legacy router",
      position: [100, 100, 0],
      state: 2,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }]
    const state = {
      animationPhase: 0,
      layers: {mantle, crust: true, atmosphere: false, security: true},
      visual: {
        label: [255, 255, 255, 255],
        edgeLabel: [200, 200, 200, 255],
        nodeFill: [80, 120, 180, 255],
      },
      canvas: {getBoundingClientRect: () => ({width: 220, height: 220})},
      deck: {getViewports: () => [{width: 220, height: 220, project: ([x, y]) => [x, y]}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 220, bottom: 220},
      topologyLabelMeasureText: () => ({width: 72, height: 12}),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods), {
      nodeColor: () => [255, 0, 0, 255],
      nodeNeutralColor: () => [128, 128, 128, 255],
    })

    const layers = ctx.buildNodeAndLabelLayers({shape}, nodeData, [])

    expect(layers.find((layer) => layer.id === "god-view-nodes")).toBeTruthy()
    expect(layers.find((layer) => layer.id === "god-view-node-labels")).toBeUndefined()
  })

  it("fails managed detail construction closed and degrades an overview with observable dropped IDs", () => {
    const nodeData = ["zeta", "alpha"].map((id, index) => ({
      index,
      id,
      label: id,
      position: [20, 20, 0],
      state: 2,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }))
    const state = {
      animationPhase: 0,
      managedTopologyVisualDensity: "overview",
      layers: {mantle: true, crust: true, atmosphere: false, security: true},
      visual: {
        label: [255, 255, 255, 255],
        edgeLabel: [200, 200, 200, 255],
        nodeFill: [80, 120, 180, 255],
      },
      deck: {getViewports: () => [{width: 40, height: 40, project: ([x, y]) => [x, y]}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 40, bottom: 40},
      topologyLabelMeasureText: () => ({width: 40, height: 12}),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    // Detail is a bounded, deliberately framed set, so a label that cannot be
    // placed means the frame is wrong and construction fails closed with ids
    // the caller can act on.
    expect(() => ctx.buildNodeAndLabelLayers({
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologySemanticLevel: "detail",
      _topologyScene: topologyScene(),
    }, nodeData, [])).toThrow(/managed topology detail is missing required labels.*alpha, zeta/i)

    // An overview is unbounded in practice, so it degrades instead: the layers
    // still build and the ids that could not be placed stay observable rather
    // than blanking the whole surface.
    expect(() => ctx.buildNodeAndLabelLayers({
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologySemanticLevel: "overview",
      _topologyScene: topologyScene(),
    }, nodeData, [])).not.toThrow()
    expect(state.topologyDroppedLabelIds).toEqual(["alpha", "zeta"])
  })

  it("visualClusterCount only scales endpoint summaries", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    expect(ctx.visualClusterCount({clusterCount: 18, details: {cluster_kind: "endpoint-summary"}})).toEqual(18)
    expect(ctx.visualClusterCount({
      clusterCount: 42,
      details: {cluster_kind: "endpoint-summary", cluster_expanded: true},
    })).toEqual(1)
    expect(ctx.visualClusterCount({clusterCount: 18, details: {cluster_kind: "endpoint-anchor"}})).toEqual(1)
    expect(ctx.visualClusterCount({clusterCount: 18, details: {}})).toEqual(1)
  })
})

describe("rendering_graph_layer_node_methods expanded detail label degradation", () => {
  function unplaceableNodeData() {
    return ["zeta", "alpha"].map((id, index) => ({
      index,
      id,
      label: id,
      position: [20, 20, 0],
      state: 2,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }))
  }

  function crampedState() {
    return {
      animationPhase: 0,
      managedTopologyVisualDensity: "detail",
      layers: {mantle: true, crust: true, atmosphere: false, security: true},
      visual: {
        label: [255, 255, 255, 255],
        edgeLabel: [200, 200, 200, 255],
        nodeFill: [80, 120, 180, 255],
      },
      deck: {getViewports: () => [{width: 40, height: 40, project: ([x, y]) => [x, y]}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 40, bottom: 40},
      topologyLabelMeasureText: () => ({width: 40, height: 12}),
    }
  }

  function contextFor(state) {
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))
    return ctx
  }

  it("degrades a detail scene reached by expanding a cluster", () => {
    // Expansion is what makes a scene unbounded -- it can add arbitrarily many member
    // nodes -- so this is the case that must degrade, whichever semantic level it lands
    // in. No explicit marker: the level is derived from the expanded cluster, exactly as
    // production does it.
    const state = crampedState()
    const graph = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologyScene: topologyScene(),
      nodes: [
        {id: "gateway", details: {cluster_kind: "endpoint-anchor"}},
        {id: "cluster", details: {cluster_kind: "endpoint-summary", cluster_expanded: true}},
        {id: "alpha", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "zeta", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
      ],
    }

    expect(() => contextFor(state).buildNodeAndLabelLayers(graph, unplaceableNodeData(), [])).not.toThrow()
    expect(state.topologyDroppedLabelIds).toEqual(["alpha", "zeta"])
  })

  it("still fails a bounded detail frame closed when nothing is expanded", () => {
    const state = crampedState()
    const graph = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
      _topologyScene: topologyScene(),
      nodes: [{id: "gateway", details: {cluster_kind: "endpoint-anchor"}}],
    }

    expect(() => contextFor(state).buildNodeAndLabelLayers(graph, unplaceableNodeData(), []))
      .toThrow(/managed topology detail is missing required labels.*alpha, zeta/i)
  })
})
