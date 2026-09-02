import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapEventFilterMethods} from "./lifecycle_bootstrap_event_filter_methods"
import {godViewLifecycleBootstrapEventLayerMethods} from "./lifecycle_bootstrap_event_layer_methods"
import {godViewLifecycleBootstrapEventMethods} from "./lifecycle_bootstrap_event_methods"
import {godViewLifecycleBootstrapEventResetViewMethods} from "./lifecycle_bootstrap_event_reset_view_methods"
import {godViewLifecycleBootstrapEventZoomMethods} from "./lifecycle_bootstrap_event_zoom_methods"
import {godViewLifecycleDomInteractionMethods} from "./lifecycle_dom_interaction_methods"
import {godViewLayoutClusterMethods} from "./layout_cluster_methods"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"
import {godViewRenderingGraphViewMethods} from "./rendering_graph_view_methods"

function topologyScene(overrides = {}) {
  return {
    nodes: [],
    routes: [],
    bounds: {minX: 0, minY: 0, maxX: 0, maxY: 0},
    ...overrides,
  }
}

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
    const deps = {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "regional"),
      refreshGraphLayersForViewState: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(
      ctx,
      bindApi(ctx, godViewLifecycleDomInteractionMethods),
      bindApi(ctx, godViewLifecycleBootstrapEventZoomMethods),
    )

    ctx.registerZoomModeEvent()
    handler({mode: "global"})

    expect(state.zoomMode).toEqual("global")
    expect(state.viewState.zoom).toEqual(-0.9)
    expect(deps.setZoomTier).toHaveBeenCalledWith("global", true)
    expect(state.deck.setProps).toHaveBeenCalled()
  })

  it("keeps a fixed managed zoom-mode change transactional when camera selection fails", () => {
    let handler = null
    const acceptedViewState = {zoom: 0, minZoom: -2, maxZoom: 5, target: [0, 0, 0]}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene(), nodes: []}
    const state = {
      zoomMode: "auto",
      zoomTier: "local",
      viewState: acceptedViewState,
      managedTopologyVisualDensity: "detail",
      lastGraph: graph,
      deck: {setProps: vi.fn()},
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
      handleEvent: vi.fn((name, fn) => {
        if (name === "god_view:set_zoom_mode") handler = fn
      }),
    }
    const deps = {
      managedViewStateForCamera: vi.fn(() => {
        throw new RangeError("no fixed-mode fit")
      }),
      refreshGraphLayersForViewState: vi.fn(),
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(
      ctx,
      bindApi(ctx, godViewLifecycleDomInteractionMethods),
      bindApi(ctx, godViewLifecycleBootstrapEventZoomMethods),
    )

    ctx.registerZoomModeEvent()
    expect(() => handler({mode: "global"})).not.toThrow()

    expect(state.zoomMode).toBe("auto")
    expect(state.viewState).toBe(acceptedViewState)
    expect(state.managedTopologyVisualDensity).toBe("detail")
    expect(deps.setZoomTier).not.toHaveBeenCalled()
    expect(state.summary.textContent).toBe("topology render unavailable")
  })

  it.each([
    ["global", -0.9, "detail"],
    ["regional", 0.35, "detail"],
    ["local", 1.65, "detail"],
  ])("keeps fixed %s camera within the permissive floor at detail semantics", (mode, expectedZoom, expectedDensity) => {
    let handler = null
    const scene = Object.freeze({
      bounds: Object.freeze({minX: 0, minY: 0, maxX: 32, maxY: 0}),
      nodes: Object.freeze([
        Object.freeze({id: "left", center: Object.freeze({x: 0, y: 0}), render: true}),
        Object.freeze({id: "right", center: Object.freeze({x: 32, y: 0}), render: true}),
      ]),
      routes: Object.freeze([]),
    })
    const graph = Object.freeze({
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
      _topologyScene: scene,
      nodes: Object.freeze([
        Object.freeze({id: "left", details: Object.freeze({cluster_kind: "endpoint-member", cluster_expanded: true})}),
        Object.freeze({id: "right", details: Object.freeze({cluster_kind: "endpoint-member", cluster_expanded: true})}),
      ]),
    })
    const state = {
      animationPhase: 0,
      zoomMode: "auto",
      managedTopologyVisualDensity: "detail",
      selectedNodeIndex: 1,
      zoomTier: "local",
      lastGraph: graph,
      viewState: {zoom: 1, minZoom: -2, maxZoom: 5, target: [16, 0, 0]},
      deck: {setProps: vi.fn()},
      handleEvent: vi.fn((name, fn) => {
        if (name === "god_view:set_zoom_mode") handler = fn
      }),
    }
    const deps = {
      renderGraph: vi.fn(),
      resolveZoomTier: vi.fn(() => "regional"),
      refreshGraphLayersForViewState: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(
      ctx,
      bindApi(ctx, godViewLayoutClusterMethods),
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
      bindApi(ctx, godViewLifecycleDomInteractionMethods),
      bindApi(ctx, godViewLifecycleBootstrapEventZoomMethods),
    )
    ctx.deps.setZoomTier = (...args) => ctx.setZoomTier(...args)
    ctx.deps.managedViewStateForCamera = (...args) => ctx.managedViewStateForCamera(...args)
    const setZoomTier = vi.spyOn(ctx, "setZoomTier")

    ctx.registerZoomModeEvent()
    handler({mode})

    expect(state.zoomMode).toBe(mode)
    expect(state.viewState.minZoom).toBe(-2)
    expect(state.viewState.minZoom).toBeLessThanOrEqual(state.viewState.zoom)
    expect(state.viewState.zoom).toBeCloseTo(expectedZoom, 12)
    expect(state.managedTopologyVisualDensity).toBe(expectedDensity)
    expect(state.lastGraph).toBe(graph)
    expect(state.zoomTier).toBe("local")
    expect(state.selectedNodeIndex).toBe(1)
    expect(setZoomTier).toHaveBeenCalledWith("local", true)
  })

  it("keeps selected managed semantics local when returning to auto zoom mode", () => {
    let handler = null
    const graph = Object.freeze({
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologyScene: Object.freeze({
        nodes: Object.freeze([]),
        routes: Object.freeze([]),
        bounds: Object.freeze({minX: 0, minY: 0, maxX: 0, maxY: 0}),
      }),
      nodes: Object.freeze([{id: "selected"}]),
    })
    const state = {
      zoomMode: "global",
      zoomTier: "local",
      selectedNodeIndex: 0,
      lastGraph: graph,
      viewState: {zoom: -1, minZoom: -2, maxZoom: 5, target: [0, 0, 0]},
      deck: {setProps: vi.fn()},
      handleEvent: vi.fn((name, fn) => {
        if (name === "god_view:set_zoom_mode") handler = fn
      }),
    }
    const deps = {renderGraph: vi.fn(), resolveZoomTier: vi.fn(() => "global")}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(
      ctx,
      bindApi(ctx, godViewLayoutClusterMethods),
      bindApi(ctx, godViewLifecycleBootstrapEventZoomMethods),
    )
    ctx.deps.setZoomTier = (...args) => ctx.setZoomTier(...args)

    ctx.registerZoomModeEvent()
    handler({mode: "auto"})

    expect(state.zoomMode).toBe("auto")
    expect(state.zoomTier).toBe("local")
    expect(state.selectedNodeIndex).toBe(0)
    expect(deps.resolveZoomTier).not.toHaveBeenCalled()
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

  it("registerResetViewEvent collapses expanded clusters before autoFit", () => {
    let handler = null
    const graph = {
      nodes: [
        {details: {cluster_expanded: false}},
        {details: {cluster_expanded: true}},
      ],
    }
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
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventResetViewMethods), {
      collapseAllClusters: vi.fn(),
    })

    ctx.registerResetViewEvent()
    handler()

    expect(state.userCameraLocked).toBe(false)
    expect(state.hasAutoFit).toBe(false)
    expect(ctx.collapseAllClusters).toHaveBeenCalledTimes(1)
    expect(deps.autoFitViewState).not.toHaveBeenCalled()
  })

  it("contains an infeasible managed fallback reset and preserves the accepted lock", () => {
    let handler = null
    const acceptedViewState = {zoom: 0, minZoom: -2, maxZoom: 5, target: [0, 0, 0]}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene(), nodes: []}
    const state = {
      deck: {setProps: vi.fn()},
      userCameraLocked: true,
      hasAutoFit: true,
      viewState: acceptedViewState,
      lastGraph: graph,
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
      handleEvent: vi.fn((name, fn) => {
        if (name === "god_view:reset_view") handler = fn
      }),
    }
    const deps = {
      autoFitViewState: vi.fn(() => {
        throw new RangeError("no reset fit")
      }),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventResetViewMethods))

    ctx.registerResetViewEvent()
    expect(() => handler()).not.toThrow()

    expect(state.userCameraLocked).toBe(true)
    expect(state.hasAutoFit).toBe(true)
    expect(state.viewState).toBe(acceptedViewState)
    expect(state.summary.textContent).toBe("topology render unavailable")
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
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapEventLayerMethods), {
      collapseAllClusters: vi.fn(),
    })

    ctx.registerLayerEvents()
    handlers["god_view:set_layers"]({layers: {mantle: false, crust: true, atmosphere: false, security: true}})
    handlers["god_view:set_topology_layers"]({layers: {backbone: true, inferred: true, endpoints: false}})

    expect(state.layers).toEqual({mantle: false, crust: true, atmosphere: false, security: true})
    expect(state.topologyLayers).toEqual({backbone: true, inferred: true, endpoints: false, mtr_paths: true})
    // Hiding attachment geometry must not throw away the operator's expansions: the server
    // defaults `endpoints` to false, so collapsing here closed open clusters on any layer push.
    expect(ctx.collapseAllClusters).not.toHaveBeenCalled()
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
