import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapEventFilterMethods} from "./lifecycle_bootstrap_event_filter_methods"
import {godViewLifecycleBootstrapEventLayerMethods} from "./lifecycle_bootstrap_event_layer_methods"
import {godViewLifecycleBootstrapEventMethods} from "./lifecycle_bootstrap_event_methods"
import {godViewLifecycleBootstrapEventResetViewMethods} from "./lifecycle_bootstrap_event_reset_view_methods"
import {godViewLifecycleBootstrapEventZoomMethods} from "./lifecycle_bootstrap_event_zoom_methods"

describe("lifecycle_bootstrap_event_methods", () => {
  it("registerLifecycleEvents wires filter/zoom/layer/reset registration", () => {
    const state = {}
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventMethods), {
      registerFilterEvent: vi.fn(),
      registerZoomModeEvent: vi.fn(),
      registerLayerEvents: vi.fn(),
      registerResetViewEvent: vi.fn(),
    })

    ctx.registerLifecycleEvents()

    expect(ctx.registerFilterEvent).toHaveBeenCalledTimes(1)
    expect(ctx.registerZoomModeEvent).toHaveBeenCalledTimes(1)
    expect(ctx.registerLayerEvents).toHaveBeenCalledTimes(1)
    expect(ctx.registerResetViewEvent).toHaveBeenCalledTimes(1)
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
    const ctx = createStateBackedContext(state, deps)
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
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventZoomMethods))

    ctx.registerZoomModeEvent()
    handler({mode: "global"})

    expect(state.zoomMode).toEqual("global")
    expect(state.viewState.zoom).toEqual(-0.9)
    expect(deps.setZoomTier).toHaveBeenCalledWith("global", true)
    expect(state.deck.setProps).toHaveBeenCalled()
  })

  it("registerResetViewEvent clears camera lock and re-triggers autoFit", () => {
    let handler = null
    const graph = {nodes: [{x: 0, y: 0}, {x: 100, y: 100}]}
    const state = {
      deck: {setProps: vi.fn()},
      userCameraLocked: true,
      hasAutoFit: true,
      lastGraph: graph,
      handleEvent: vi.fn((name, fn) => {
        if (name === "god_view:reset_view") handler = fn
      }),
    }
    const deps = {autoFitViewState: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventResetViewMethods))

    ctx.registerResetViewEvent()
    handler()

    expect(state.userCameraLocked).toBe(false)
    expect(state.hasAutoFit).toBe(false)
    expect(deps.autoFitViewState).toHaveBeenCalledWith(graph)
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
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventLayerMethods))

    ctx.registerLayerEvents()
    handlers["god_view:set_layers"]({layers: {mantle: false, crust: true, atmosphere: false, security: true}})
    handlers["god_view:set_topology_layers"]({layers: {backbone: true, inferred: true, endpoints: false}})

    expect(state.layers).toEqual({mantle: false, crust: true, atmosphere: false, security: true})
    expect(state.topologyLayers).toEqual({backbone: true, inferred: true, endpoints: false, mtr_paths: true})
    expect(deps.renderGraph).toHaveBeenCalledTimes(2)
  })

  it("registerLayerEvents preserves mtr_paths when omitted in payload", () => {
    const handlers = {}
    const state = {
      topologyLayers: {backbone: true, inferred: false, endpoints: true, mtr_paths: true},
      lastGraph: {nodes: []},
      handleEvent: vi.fn((name, fn) => {
        handlers[name] = fn
      }),
    }
    const deps = {renderGraph: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventLayerMethods))

    ctx.registerLayerEvents()
    handlers["god_view:set_topology_layers"]({layers: {backbone: false, inferred: true, endpoints: false}})

    expect(state.topologyLayers).toEqual({
      backbone: false,
      inferred: true,
      endpoints: false,
      mtr_paths: true,
    })
  })
})
