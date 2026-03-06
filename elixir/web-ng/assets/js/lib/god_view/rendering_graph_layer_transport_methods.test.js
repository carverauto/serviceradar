import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphLayerTransportMethods} from "./rendering_graph_layer_transport_methods"

describe("rendering_graph_layer_transport_methods", () => {
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
