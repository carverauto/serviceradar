import {describe, expect, it, vi} from "vitest"

import {godViewLifecycleBootstrapEventFilterMethods} from "./lifecycle_bootstrap_event_filter_methods"
import {godViewLifecycleBootstrapEventLayerMethods} from "./lifecycle_bootstrap_event_layer_methods"
import {godViewLifecycleBootstrapEventMethods} from "./lifecycle_bootstrap_event_methods"
import {godViewLifecycleBootstrapEventZoomMethods} from "./lifecycle_bootstrap_event_zoom_methods"

describe("lifecycle_bootstrap_event_methods", () => {
  it("registerLifecycleEvents wires filter/zoom/layer registration", () => {
    const ctx = {
      ...godViewLifecycleBootstrapEventMethods,
      registerFilterEvent: vi.fn(),
      registerZoomModeEvent: vi.fn(),
      registerLayerEvents: vi.fn(),
    }

    ctx.registerLifecycleEvents()

    expect(ctx.registerFilterEvent).toHaveBeenCalledTimes(1)
    expect(ctx.registerZoomModeEvent).toHaveBeenCalledTimes(1)
    expect(ctx.registerLayerEvents).toHaveBeenCalledTimes(1)
  })

  it("registerFilterEvent updates filters and rerenders when graph exists", () => {
    let handler = null
    const ctx = {
      ...godViewLifecycleBootstrapEventFilterMethods,
      filters: {},
      lastGraph: {nodes: []},
      renderGraph: vi.fn(),
      handleEvent: vi.fn((name, fn) => {
        if (name === "god_view:set_filters") handler = fn
      }),
    }

    ctx.registerFilterEvent()
    handler({filters: {root_cause: false, affected: true, healthy: false, unknown: true}})

    expect(ctx.filters).toEqual({
      root_cause: false,
      affected: true,
      healthy: false,
      unknown: true,
    })
    expect(ctx.renderGraph).toHaveBeenCalledWith(ctx.lastGraph)
  })

  it("registerZoomModeEvent updates view state and tier in manual mode", () => {
    let handler = null
    const ctx = {
      ...godViewLifecycleBootstrapEventZoomMethods,
      zoomMode: "auto",
      viewState: {zoom: 1, minZoom: -2, maxZoom: 5},
      deck: {setProps: vi.fn()},
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "regional"),
      handleEvent: vi.fn((name, fn) => {
        if (name === "god_view:set_zoom_mode") handler = fn
      }),
    }

    ctx.registerZoomModeEvent()
    handler({mode: "global"})

    expect(ctx.zoomMode).toEqual("global")
    expect(ctx.viewState.zoom).toEqual(-0.9)
    expect(ctx.setZoomTier).toHaveBeenCalledWith("global", true)
    expect(ctx.deck.setProps).toHaveBeenCalled()
  })

  it("registerLayerEvents updates topology + visual layers and rerenders", () => {
    const handlers = {}
    const ctx = {
      ...godViewLifecycleBootstrapEventLayerMethods,
      layers: {},
      topologyLayers: {},
      lastGraph: {nodes: []},
      renderGraph: vi.fn(),
      handleEvent: vi.fn((name, fn) => {
        handlers[name] = fn
      }),
    }

    ctx.registerLayerEvents()
    handlers["god_view:set_layers"]({layers: {mantle: false, crust: true, atmosphere: false, security: true}})
    handlers["god_view:set_topology_layers"]({layers: {backbone: true, inferred: true, endpoints: false}})

    expect(ctx.layers).toEqual({mantle: false, crust: true, atmosphere: false, security: true})
    expect(ctx.topologyLayers).toEqual({backbone: true, inferred: true, endpoints: false})
    expect(ctx.renderGraph).toHaveBeenCalledTimes(2)
  })
})
