import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapEventFilterMethods} from "./lifecycle_bootstrap_event_filter_methods"
import {godViewLifecycleBootstrapEventLayerMethods} from "./lifecycle_bootstrap_event_layer_methods"
import {godViewLifecycleBootstrapEventMethods} from "./lifecycle_bootstrap_event_methods"
import {godViewLifecycleBootstrapEventZoomMethods} from "./lifecycle_bootstrap_event_zoom_methods"

describe("lifecycle_bootstrap_event_methods", () => {
  it("registerLifecycleEvents wires filter/zoom/layer registration", () => {
    const state = {}
    const ctx = createStateBackedContext(state, {}, Object.keys(state))
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventMethods), {
      registerFilterEvent: vi.fn(),
      registerZoomModeEvent: vi.fn(),
      registerLayerEvents: vi.fn(),
    })

    ctx.registerLifecycleEvents()

    expect(ctx.registerFilterEvent).toHaveBeenCalledTimes(1)
    expect(ctx.registerZoomModeEvent).toHaveBeenCalledTimes(1)
    expect(ctx.registerLayerEvents).toHaveBeenCalledTimes(1)
  })

  it("registerFilterEvent updates filters and rerenders when graph exists", () => {
    let handler = null
    const state = {
      filters: {},
      lastGraph: {nodes: []},
      handleEvent: vi.fn((name, fn) => {
        if (name === "god_view:set_filters") handler = fn
      }),
    }
    const deps = {renderGraph: vi.fn()}
    const ctx = createStateBackedContext(state, deps, Object.keys(state))
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventFilterMethods))

    ctx.registerFilterEvent()
    handler({filters: {root_cause: false, affected: true, healthy: false, unknown: true}})

    expect(state.filters).toEqual({
      root_cause: false,
      affected: true,
      healthy: false,
      unknown: true,
    })
    expect(deps.renderGraph).toHaveBeenCalledWith(state.lastGraph)
  })

  it("registerZoomModeEvent updates view state and tier in manual mode", () => {
    let handler = null
    const state = {
      zoomMode: "auto",
      viewState: {zoom: 1, minZoom: -2, maxZoom: 5},
      deck: {setProps: vi.fn()},
      handleEvent: vi.fn((name, fn) => {
        if (name === "god_view:set_zoom_mode") handler = fn
      }),
    }
    const deps = {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "regional")}
    const ctx = createStateBackedContext(state, deps, Object.keys(state))
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventZoomMethods))

    ctx.registerZoomModeEvent()
    handler({mode: "global"})

    expect(state.zoomMode).toEqual("global")
    expect(state.viewState.zoom).toEqual(-0.9)
    expect(deps.setZoomTier).toHaveBeenCalledWith("global", true)
    expect(state.deck.setProps).toHaveBeenCalled()
  })

  it("registerLayerEvents updates topology + visual layers and rerenders", () => {
    const handlers = {}
    const state = {
      layers: {},
      topologyLayers: {},
      lastGraph: {nodes: []},
      handleEvent: vi.fn((name, fn) => {
        handlers[name] = fn
      }),
    }
    const deps = {renderGraph: vi.fn()}
    const ctx = createStateBackedContext(state, deps, Object.keys(state))
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventLayerMethods))

    ctx.registerLayerEvents()
    handlers["god_view:set_layers"]({layers: {mantle: false, crust: true, atmosphere: false, security: true}})
    handlers["god_view:set_topology_layers"]({layers: {backbone: true, inferred: true, endpoints: false}})

    expect(state.layers).toEqual({mantle: false, crust: true, atmosphere: false, security: true})
    expect(state.topologyLayers).toEqual({backbone: true, inferred: true, endpoints: false})
    expect(deps.renderGraph).toHaveBeenCalledTimes(2)
  })
})
