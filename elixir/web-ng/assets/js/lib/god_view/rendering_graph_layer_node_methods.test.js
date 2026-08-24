import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"

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
    const scene = {
      routes: [{
        id: "route:a-b",
        points: [{x: 65, y: 70}, {x: 135, y: 70}],
        metadata: {strokeWidth: 2},
      }],
    }
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

    const effective = {shape: "local", _layoutMode: "elk-scene", _topologyScene: scene}
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

  it("recomputes admission from a changed Deck viewport without mutating or laying out the scene", () => {
    let projectedY = 100
    const project = vi.fn(([x]) => [x, projectedY])
    const scene = {routes: []}
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
    const effective = {shape: "local", _layoutMode: "elk-scene", _topologyScene: scene}
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
    expect(labels).toHaveLength(8)
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
      _layoutMode: "elk-scene",
      _topologyScene: {routes: []},
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

  it("uses managed label density for font size while semantic shape stays local", () => {
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
    const effective = {shape: "local", _layoutMode: "elk-scene", _topologyScene: {routes: []}}

    const overview = ctx.buildNodeAndLabelLayers(effective, nodeData, [])
    state.managedTopologyVisualDensity = "detail"
    const detail = ctx.buildNodeAndLabelLayers(effective, nodeData, [])
    const overviewLabels = overview.find((layer) => layer.id === "god-view-node-labels")
    const detailLabels = detail.find((layer) => layer.id === "god-view-node-labels")

    expect(overviewLabels.props.getSize).toBe(10)
    expect(overviewLabels.props.sizeMinPixels).toBe(8)
    expect(detailLabels.props.getSize).toBe(12)
    expect(detailLabels.props.sizeMinPixels).toBe(10)
  })

  it("backfills collision-blocked overview priorities from the remaining semantic candidates", () => {
    const blocked = Array.from({length: 8}, (_, index) => ({
      index,
      id: `blocked-${index}`,
      label: `Blocked ${index}`,
      position: [500, 300, 0],
      state: 0,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }))
    const fallbackPoints = [[60, 60], [300, 60], [600, 540], [900, 540]]
    const fallback = fallbackPoints.map((position, index) => ({
      index: blocked.length + index,
      id: `fallback-${index}`,
      label: `Fallback ${index}`,
      position: [...position, 0],
      state: 1,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }))
    const scene = {
      routes: [
        {points: [{x: 510, y: 300}, {x: 510, y: 350}]},
        {points: [{x: 450, y: 310}, {x: 550, y: 310}]},
        {points: [{x: 490, y: 300}, {x: 490, y: 350}]},
      ],
    }
    const state = {
      animationPhase: 0,
      hoveredNodeIndex: null,
      managedTopologyVisualDensity: "overview",
      layers: {mantle: true, crust: true, atmosphere: false, security: true},
      visual: {
        label: [255, 255, 255, 255],
        edgeLabel: [200, 200, 200, 255],
        nodeFill: [80, 120, 180, 255],
      },
      canvas: {getBoundingClientRect: () => ({width: 1000, height: 600})},
      deck: {getViewports: () => [{width: 1000, height: 600, project: ([x, y]) => [x, y]}]},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 600},
      topologyLabelMeasureText: () => ({width: 48, height: 12}),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods), {
      nodeColor: () => [255, 0, 0, 255],
      nodeNeutralColor: () => [128, 128, 128, 255],
    })
    const effective = {shape: "local", _layoutMode: "elk-scene", _topologyScene: scene}
    const labelsFor = (nodes) => ctx
      .buildNodeAndLabelLayers(effective, nodes, [])
      .find((layer) => layer.id === "god-view-node-labels")
      .props.data
      .map((node) => ({id: node.id, admission: node.labelAdmission}))

    const first = labelsFor([...blocked, ...fallback])
    const reordered = labelsFor([...fallback, ...blocked].reverse())

    expect(first.map(({id}) => id)).toEqual([
      "blocked-0",
      "fallback-0",
      "fallback-1",
      "fallback-2",
      "fallback-3",
    ])
    expect(reordered).toEqual(first)
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
