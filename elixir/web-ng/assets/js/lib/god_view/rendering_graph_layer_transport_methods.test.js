import {describe, expect, it, vi} from "vitest"
import {ArcLayer, LineLayer, PathLayer} from "@deck.gl/layers"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphLayerTransportMethods} from "./rendering_graph_layer_transport_methods"

function topologyScene(overrides = {}) {
  return {
    nodes: [],
    routes: [],
    bounds: {minX: 0, minY: 0, maxX: 0, maxY: 0},
    ...overrides,
  }
}

describe("rendering_graph_layer_transport_methods", () => {
  it("keeps local ELK-tagged graphs without scene routes on the legacy transport layers", () => {
    const state = {
      animationPhase: 1.2,
      layers: {mantle: true, crust: true, atmosphere: false, security: false},
      visual: {mantleEdgeBase: [30, 80, 140], mantleEdgeAlphaBase: 128, mantleEdgeAlphaBoost: 32},
    }
    const ctx = createStateBackedContext(state, {geoGridData: vi.fn(() => [])})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
      edgeTelemetryArcColors: vi.fn(() => ({source: [100, 100, 255, 120], target: [200, 120, 255, 120]})),
      edgeWidthPixels: vi.fn(() => 2.2),
      edgeIsFocused: vi.fn(() => false),
    })

    const out = ctx.buildTransportAndEffectLayers(
      {shape: "local", _layoutMode: "elk-scene", _topologyScene: {}},
      [],
      [{sourcePosition: [0, 0, 0], targetPosition: [40, 20, 0], topologyClass: "backbone"}],
    )

    expect(out.mantleLayers[0]).toBeInstanceOf(LineLayer)
    expect(out.crustLayers[0]).toBeInstanceOf(ArcLayer)
  })

  it("renders routed topology edges through one shared PathLayer path", () => {
    const state = {
      animationPhase: 1.2,
      hoveredEdgeKey: "local:route:a-b",
      selectedEdgeKey: "local:route:a-b",
      layers: {mantle: true, crust: true, atmosphere: false, security: false},
      visual: {
        mantleEdgeBase: [30, 80, 140],
        mantleEdgeAlphaBase: 128,
        mantleEdgeAlphaBoost: 32,
      },
    }
    const ctx = createStateBackedContext(state, {geoGridData: vi.fn(() => [])})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
      edgeTelemetryColor: vi.fn(() => [100, 160, 255, 150]),
      edgeWidthPixels: vi.fn(() => 2.2),
      edgeIsFocused: vi.fn(() => true),
    })
    const edge = {
      interactionKey: "local:route:a-b",
      path: [[0, 0, 0], [40, 0, 0], [40, 80, 0]],
      sourcePosition: [0, 0, 0],
      targetPosition: [40, 80, 0],
      topologyClass: "backbone",
    }

    const out = ctx.buildTransportAndEffectLayers(
      {shape: "local", _layoutMode: "elk-radial-overview", _topologyScene: topologyScene({routes: [{id: "route:a-b"}]})},
      [],
      [edge],
    )

    expect(out.mantleLayers[0]).toBeInstanceOf(PathLayer)
    expect(out.crustLayers[0]).toBeInstanceOf(PathLayer)
    expect(out.mantleLayers[0].props.getPath(edge)).toBe(edge.path)
    expect(out.crustLayers[0].props.getPath(edge)).toBe(edge.path)
    expect(out.mantleLayers[0].props.jointRounded).toBe(true)
    expect(out.crustLayers[0].props.jointRounded).toBe(true)
    expect(out.mantleLayers[0]).not.toBeInstanceOf(ArcLayer)
    expect(out.crustLayers[0]).not.toBeInstanceOf(ArcLayer)
    expect(out.crustLayers[0].props.getColor(edge)).toEqual([100, 160, 255, 255])
  })

  it("renders manifold rails and trunks beneath semantic branches without making them pick targets", () => {
    const state = {
      animationPhase: 1.2,
      layers: {mantle: true, crust: true, atmosphere: false, security: false},
      visual: {
        mantleEdgeBase: [30, 80, 140],
        mantleEdgeAlphaBase: 128,
        mantleEdgeAlphaBoost: 32,
      },
    }
    const ctx = createStateBackedContext(state, {geoGridData: vi.fn(() => [])})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
      edgeTelemetryColor: vi.fn(() => [100, 160, 255, 150]),
      edgeWidthPixels: vi.fn(() => 2.2),
      edgeIsFocused: vi.fn(() => false),
    })
    const semantic = {
      routeId: "route:a-b",
      interactionKey: "local:route:a-b",
      path: [[40, 0, 0], [80, 0, 0]],
    }
    const auxiliary = {
      routeId: "manifold:a:source:rail",
      auxiliary: true,
      interactionKey: null,
      semanticRouteIds: ["route:a-b"],
      path: [[0, -20, 0], [0, 20, 0]],
    }

    const out = ctx.buildTransportAndEffectLayers(
      {shape: "local", _layoutMode: "elk-scene-detail", _topologyScene: topologyScene({routes: [{id: "route:a-b"}]})},
      [],
      [semantic, auxiliary],
    )

    expect(out.mantleLayers.map((layer) => layer.id)).toEqual([
      "god-view-edges-mantle-auxiliary",
      "god-view-edges-mantle",
    ])
    expect(out.crustLayers.map((layer) => layer.id)).toEqual([
      "god-view-edges-crust-auxiliary",
      "god-view-edges-crust",
    ])
    for (const layers of [out.mantleLayers, out.crustLayers]) {
      expect(layers[0].props.data).toEqual([auxiliary])
      expect(layers[0].props.pickable).toBe(false)
      expect(layers[1].props.data).toEqual([semantic])
      expect(layers[1].props.pickable).toBe(true)
    }
  })

  it.each([
    ["overview", 10],
    ["detail", 12],
  ])("caps every focused managed PathLayer stroke at the %s density", (density, maximum) => {
    const state = {
      animationPhase: 1.2,
      managedTopologyVisualDensity: density,
      hoveredEdgeKey: "local:route:a-b",
      selectedEdgeKey: "local:route:a-b",
      viewState: {zoom: 3},
      layers: {mantle: true, crust: true, atmosphere: false, security: false},
      visual: {
        mantleEdgeBase: [30, 80, 140],
        mantleEdgeAlphaBase: 128,
        mantleEdgeAlphaBoost: 32,
      },
    }
    const ctx = createStateBackedContext(state, {geoGridData: vi.fn(() => [])})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
      edgeTelemetryColor: vi.fn(() => [100, 160, 255, 150]),
      edgeWidthPixels: vi.fn(() => 100),
      edgeIsFocused: vi.fn(() => true),
    })
    const edge = {
      interactionKey: "local:route:a-b",
      path: [[0, 0, 0], [40, 0, 0]],
      topologyClass: "backbone",
    }

    const out = ctx.buildTransportAndEffectLayers(
      {shape: "regional", _layoutMode: "elk-scene-detail", _topologyScene: topologyScene({routes: [{id: "route:a-b"}]})},
      [],
      [edge],
    )

    expect(out.mantleLayers[0].props.getWidth(edge)).toBe(maximum)
    expect(out.crustLayers[0].props.getWidth(edge)).toBe(maximum)
  })

  it("invalidates both managed route width accessors when density changes with identical edge data", () => {
    const edgeData = [{
      interactionKey: "local:route:a-b",
      path: [[0, 0, 0], [40, 0, 0]],
      topologyClass: "backbone",
    }]
    const state = {
      animationPhase: 1.2,
      managedTopologyVisualDensity: "overview",
      viewState: {zoom: 3},
      layers: {mantle: true, crust: true, atmosphere: false, security: false},
      visual: {
        mantleEdgeBase: [30, 80, 140],
        mantleEdgeAlphaBase: 128,
        mantleEdgeAlphaBoost: 32,
      },
    }
    const ctx = createStateBackedContext(state, {geoGridData: vi.fn(() => [])})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
      edgeTelemetryColor: vi.fn(() => [100, 160, 255, 150]),
      edgeWidthPixels: vi.fn(() => 100),
      edgeIsFocused: vi.fn(() => false),
    })
    const effective = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologyScene: topologyScene({routes: [{id: "route:a-b"}]}),
    }

    const overview = ctx.buildTransportAndEffectLayers(effective, [], edgeData)
    state.managedTopologyVisualDensity = "detail"
    const detail = ctx.buildTransportAndEffectLayers(effective, [], edgeData)

    for (const key of ["mantleLayers", "crustLayers"]) {
      expect(overview[key][0].props.data).toBe(edgeData)
      expect(detail[key][0].props.data).toBe(edgeData)
      expect(overview[key][0].props.updateTriggers.getWidth).toContain("overview")
      expect(detail[key][0].props.updateTriggers.getWidth).toContain("detail")
    }
  })

  it("leaves legacy LineLayer and ArcLayer width behavior unchanged", () => {
    const state = {
      animationPhase: 1.2,
      managedTopologyVisualDensity: "overview",
      hoveredEdgeKey: "legacy",
      selectedEdgeKey: "legacy",
      viewState: {zoom: 3},
      layers: {mantle: true, crust: true, atmosphere: false, security: false},
      visual: {
        mantleEdgeBase: [30, 80, 140],
        mantleEdgeAlphaBase: 128,
        mantleEdgeAlphaBoost: 32,
      },
    }
    const ctx = createStateBackedContext(state, {geoGridData: vi.fn(() => [])})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
      edgeTelemetryArcColors: vi.fn(() => ({source: [100, 100, 255, 120], target: [200, 120, 255, 120]})),
      edgeWidthPixels: vi.fn(() => 100),
      edgeIsFocused: vi.fn(() => true),
    })
    const edge = {sourcePosition: [0, 0, 0], targetPosition: [40, 0, 0], topologyClass: "backbone"}

    const out = ctx.buildTransportAndEffectLayers({shape: "regional"}, [], [edge])

    expect(out.mantleLayers[0]).toBeInstanceOf(LineLayer)
    expect(out.crustLayers[0]).toBeInstanceOf(ArcLayer)
    expect(out.mantleLayers[0].props.getWidth(edge)).toBe(38)
    expect(out.crustLayers[0].props.getWidth(edge)).toBe(12)
  })

  it("buildTransportAndEffectLayers includes atmosphere particles with additive blend settings", () => {
    const state = {
      animationPhase: 1.2,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      packetFlowEnabled: true,
      packetFlowShaderEnabled: true,
      visual: {pulse: [255, 64, 64, 220], particleBlend: [770, 1, 1, 1]},
    }
    const deps = {geoGridData: vi.fn(() => [])}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
      buildPacketFlowInstances: vi.fn(() => [{
        from: [0, 0],
        to: [10, 10],
        seed: 0.2,
        speed: 1,
        jitter: 8,
        size: 2.6,
        color: [100, 200, 255, 220],
      }]),
      edgeTelemetryColor: vi.fn(() => [40, 170, 220, 45]),
      edgeTelemetryArcColors: vi.fn(() => ({source: [100, 100, 255, 120], target: [200, 120, 255, 120]})),
      edgeWidthPixels: vi.fn(() => 2.2),
      edgeIsFocused: vi.fn(() => false),
    })

    const out = ctx.buildTransportAndEffectLayers(
      {shape: "local"},
      [{state: 0, position: [0, 0, 0]}],
      [{sourcePosition: [0, 0, 0], targetPosition: [100, 50, 0], flowBps: 10, flowPps: 10, capacityBps: 100}],
    )

    expect(out.mantleLayers).toHaveLength(1)
    expect(out.crustLayers).toHaveLength(1)
    expect(out.atmosphereLayers).toHaveLength(1)
    expect(out.securityLayers).toHaveLength(1)
    expect(out.atmosphereLayers[0].id).toEqual("god-view-atmosphere-particles")
    expect(out.atmosphereLayers[0].props.parameters.blendFunc).toEqual([770, 1, 1, 1])
    expect(out.atmosphereLayers[0].props.parameters.depthTest).toEqual(false)
  })

  it("buildTransportAndEffectLayers omits atmosphere particles when layer toggle is disabled", () => {
    const state = {
      animationPhase: 1.2,
      layers: {mantle: true, crust: true, atmosphere: false, security: true},
      packetFlowEnabled: true,
      visual: {pulse: [255, 64, 64, 220]},
    }
    const deps = {geoGridData: vi.fn(() => [])}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
      buildPacketFlowInstances: vi.fn(() => []),
      edgeTelemetryColor: vi.fn(() => [40, 170, 220, 45]),
      edgeTelemetryArcColors: vi.fn(() => ({source: [100, 100, 255, 120], target: [200, 120, 255, 120]})),
      edgeWidthPixels: vi.fn(() => 2.2),
      edgeIsFocused: vi.fn(() => false),
    })

    const out = ctx.buildTransportAndEffectLayers(
      {shape: "local"},
      [{state: 0, position: [0, 0, 0]}],
      [{sourcePosition: [0, 0, 0], targetPosition: [100, 50, 0], flowBps: 10, flowPps: 10, capacityBps: 100}],
    )

    expect(out.atmosphereLayers).toHaveLength(0)
  })

  it("buildTransportAndEffectLayers renders endpoint attachments more softly than backbone links", () => {
    const state = {
      animationPhase: 1.2,
      layers: {mantle: true, crust: true, atmosphere: true, security: false},
      packetFlowEnabled: true,
      packetFlowShaderEnabled: true,
      visual: {
        pulse: [255, 64, 64, 220],
        particleBlend: [770, 1, 1, 1],
        mantleEdgeBase: [30, 80, 140],
        mantleEdgeAlphaBase: 128,
        mantleEdgeAlphaBoost: 32,
      },
    }
    const deps = {geoGridData: vi.fn(() => [])}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
      buildPacketFlowInstances: vi.fn(() => []),
      edgeTelemetryArcColors: vi.fn(() => ({source: [100, 100, 255, 120], target: [200, 120, 255, 120]})),
      edgeWidthPixels: vi.fn(() => 6),
      edgeIsFocused: vi.fn(() => false),
    })

    const edges = [
      {sourcePosition: [0, 0, 0], targetPosition: [100, 0, 0], flowBps: 10, flowPps: 10, capacityBps: 100, topologyClass: "backbone"},
      {sourcePosition: [0, 20, 0], targetPosition: [100, 20, 0], flowBps: 10, flowPps: 10, capacityBps: 100, topologyClass: "endpoints"},
    ]

    const out = ctx.buildTransportAndEffectLayers({shape: "local"}, [], edges)
    const mantleProps = out.mantleLayers[0].props
    const crustProps = out.crustLayers[0].props

    expect(mantleProps.getWidth(edges[1])).toBeLessThan(mantleProps.getWidth(edges[0]))
    expect(mantleProps.getColor(edges[1])[3]).toBeLessThan(mantleProps.getColor(edges[0])[3])
    expect(crustProps.getWidth(edges[1])).toBeLessThan(crustProps.getWidth(edges[0]))
    expect(crustProps.getSourceColor(edges[1])[3]).toBeLessThan(crustProps.getSourceColor(edges[0])[3])
  })
})
