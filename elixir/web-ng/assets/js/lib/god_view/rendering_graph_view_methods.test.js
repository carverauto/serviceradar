import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"
import {godViewRenderingGraphViewMethods} from "./rendering_graph_view_methods"

function projectNode(node, state) {
  const scale = 2 ** state.viewState.zoom
  const [targetX = 0, targetY = 0] = state.viewState.target || [0, 0, 0]

  return {
    x: state.el.clientWidth / 2 + (node.x - targetX) * scale,
    y: state.el.clientHeight / 2 + (node.y - targetY) * scale,
  }
}

describe("rendering_graph_view_methods", () => {
  it("autoFitViewState uses asymmetric padding to keep the graph inside the usable canvas", () => {
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "local",
      viewState: {minZoom: -2, maxZoom: 8, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1200, clientHeight: 800},
    }

    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    ctx.autoFitViewState({
      nodes: [
        {x: 0, y: 0},
        {x: 100, y: 100},
      ],
    })

    expect(state.hasAutoFit).toBe(true)
    expect(state.isProgrammaticViewUpdate).toBe(true)
    expect(state.viewState.target[0]).toBeGreaterThan(50)
    expect(state.viewState.target[1]).toBeGreaterThan(50)
    expect(state.deck.setProps).toHaveBeenCalled()
  })

  it("autoFitViewState ignores endpoint fanout and unplaced lanes for radial overview framing", () => {
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "local",
      viewState: {minZoom: -2, maxZoom: 8, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1200, clientHeight: 800},
    }

    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    ctx.autoFitViewState({
      _layoutMode: "client-radial",
      nodes: [
        {id: "core", x: 320, y: 280, details: {}},
        {id: "agg-a", x: 470, y: 200, details: {}},
        {id: "agg-b", x: 470, y: 360, details: {}},
        {
          id: "cluster-summary",
          x: 610,
          y: 280,
          details: {cluster_kind: "endpoint-summary"},
        },
        {
          id: "endpoint-1",
          x: 980,
          y: 40,
          details: {cluster_kind: "endpoint-member"},
        },
        {
          id: "endpoint-2",
          x: 1040,
          y: 520,
          details: {cluster_kind: "endpoint-member"},
        },
        {
          id: "vjunos",
          x: 1180,
          y: 620,
          details: {topology_unplaced: true, topology_plane: "unplaced"},
        },
      ],
    })

    expect(state.hasAutoFit).toBe(true)
    expect(state.viewState.target[0]).toBeLessThan(700)
    expect(state.viewState.target[1]).toBeGreaterThan(220)
    expect(state.viewState.target[1]).toBeLessThan(360)
  })

  it("autoFitViewState frames expanded endpoint fanout that is visibly rendered", () => {
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      viewState: {minZoom: -2, maxZoom: 8, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1200, clientHeight: 800},
    }

    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    const topEndpoint = {
      id: "endpoint-top",
      x: 650,
      y: -180,
      details: {cluster_kind: "endpoint-member", cluster_expanded: true},
    }
    const bottomEndpoint = {
      id: "endpoint-bottom",
      x: 650,
      y: 740,
      details: {cluster_kind: "endpoint-member", cluster_expanded: true},
    }

    ctx.autoFitViewState({
      _layoutMode: "client-radial",
      nodes: [
        {id: "core", x: 320, y: 280, details: {}},
        {id: "agg", x: 470, y: 280, details: {}},
        {id: "cluster-summary", x: 610, y: 280, details: {cluster_kind: "endpoint-summary"}},
        topEndpoint,
        bottomEndpoint,
        {
          id: "collapsed-endpoint",
          x: 1500,
          y: -800,
          details: {cluster_kind: "endpoint-member"},
        },
      ],
    })

    const padding = ctx.fitViewPadding(state.el.clientWidth, state.el.clientHeight)
    const projectedTop = projectNode(topEndpoint, state)
    const projectedBottom = projectNode(bottomEndpoint, state)

    expect(projectedTop.y).toBeGreaterThanOrEqual(padding.top)
    expect(projectedBottom.y).toBeLessThanOrEqual(state.el.clientHeight - padding.bottom)
    expect(state.viewState.zoom).toBeLessThan(0.2)
  })

  it("autoFitViewState keeps client-radial overviews in local zoom tier without forcing a high zoom", () => {
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      viewState: {minZoom: -2, maxZoom: 8, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1200, clientHeight: 800},
    }

    const deps = {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "regional"),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    ctx.autoFitViewState({
      _layoutMode: "client-radial",
      nodes: [
        {id: "core", x: 320, y: 280, details: {}},
        {id: "left", x: -640, y: 280, details: {}},
        {id: "right", x: 1640, y: 280, details: {}},
      ],
    })

    expect(state.viewState.zoom).toBeLessThan(1.1)
    expect(deps.setZoomTier).toHaveBeenCalledWith("local", true)
  })

  it("fitViewPadding reserves extra space for controls and summary chrome", () => {
    const ctx = createStateBackedContext({}, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    expect(ctx.fitViewPadding(1200, 800)).toEqual({
      left: 72,
      right: 216,
      top: 72,
      bottom: 96,
    })
  })

  it("autoFitViewState includes endpoint summaries in radial overview framing", () => {
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "local",
      viewState: {minZoom: -2, maxZoom: 8, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1200, clientHeight: 800},
    }

    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    ctx.autoFitViewState({
      _layoutMode: "client-radial",
      nodes: [
        {id: "core", x: 220, y: 280, details: {}},
        {id: "agg", x: 420, y: 280, details: {}},
        {id: "cluster-a", x: 980, y: 180, details: {cluster_kind: "endpoint-summary"}},
        {id: "cluster-b", x: 1040, y: 360, details: {cluster_kind: "endpoint-summary"}},
      ],
    })

    expect(state.viewState.target[0]).toBeGreaterThan(560)
    expect(state.viewState.target[0]).toBeLessThan(760)
    expect(state.viewState.zoom).toBeLessThan(1)
  })

  it("autoFitViewState uses complete immutable ELK scene bounds and keeps the managed view local", () => {
    const scene = {
      bounds: {minX: -200, minY: -100, maxX: 9800, maxY: 700},
      nodes: [
        {id: "left", center: {x: -144, y: 0}, width: 112, height: 112},
        {id: "right", center: {x: 9744, y: 600}, width: 112, height: 112},
      ],
      groups: [],
      routes: [{
        id: "route",
        sourceId: "left",
        targetId: "right",
        strokeWidth: 40,
        points: [{x: -200, y: 0}, {x: 9800, y: 700}],
      }],
    }
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      managedTopologyCameraBaseMinZoom: -2,
      viewState: {minZoom: -2, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1000, clientHeight: 700},
      topologyLabelSafeRect: {left: 40, top: 30, right: 820, bottom: 610},
    }
    const deps = {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "regional")}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState({
      _layoutMode: "elk-scene-detail",
      _topologyScene: scene,
      nodes: [
        {id: "left", x: -144, y: 0, details: {}},
        {id: "right", x: 9744, y: 600, details: {}},
      ],
    })

    const topLeft = projectNode({x: scene.bounds.minX, y: scene.bounds.minY}, state)
    const bottomRight = projectNode({x: scene.bounds.maxX, y: scene.bounds.maxY}, state)
    expect(topLeft.x - 20).toBeGreaterThanOrEqual(state.topologyLabelSafeRect.left - 1)
    expect(topLeft.y - 20).toBeGreaterThanOrEqual(state.topologyLabelSafeRect.top - 1)
    expect(bottomRight.x + 20).toBeLessThanOrEqual(state.topologyLabelSafeRect.right + 1)
    expect(bottomRight.y + 20).toBeLessThanOrEqual(state.topologyLabelSafeRect.bottom + 1)
    expect(state.viewState.zoom).toBeLessThan(-3)
    expect(state.viewState.minZoom).toBeCloseTo(state.viewState.zoom, 12)
    expect(deps.setZoomTier).toHaveBeenCalledWith("local", true)
    expect(scene.bounds).toEqual({minX: -200, minY: -100, maxX: 9800, maxY: 700})
  })

  it("fits the live wide-scene ratio twice without raising minZoom above containment", () => {
    const containmentScale = 0.019548
    const worldSpan = (1000 - 20) / containmentScale
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: worldSpan, maxY: 100},
      nodes: [
        {id: "left", center: {x: 0, y: 50}, width: 0, height: 0, render: true},
        {id: "right", center: {x: worldSpan, y: 50}, width: 0, height: 0, render: true},
      ],
      groups: [],
      routes: [],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologySemanticLevel: "overview",
      _layoutCacheKey: "live-wide-fit-ratio",
      _topologyScene: scene,
      nodes: [
        {id: "left", x: 0, y: 50, label: "Left", details: {}},
        {id: "right", x: worldSpan, y: 50, label: "Right", details: {}},
      ],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyCameraBaseMinZoom: -12,
      viewState: {minZoom: -12, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1000, clientHeight: 300},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 300},
      topologyLabelMeasureText: () => ({width: 24, height: 12}),
    }
    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState(graph)
    const first = structuredClone(state.viewState)
    ctx.autoFitViewState(graph, {force: true})
    const second = structuredClone(state.viewState)

    expect(2 ** first.zoom).toBeCloseTo(containmentScale, 6)
    expect(first.zoom).toBeLessThan(Math.log2(0.089285))
    expect(first.minZoom).toBeLessThanOrEqual(first.zoom)
    expect(second.zoom).toBeCloseTo(first.zoom, 12)
    expect(second.target[0]).toBeCloseTo(first.target[0], 12)
    expect(second.target[1]).toBeCloseTo(first.target[1], 12)
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(state.deck.setProps).toHaveBeenCalledTimes(2)
  })

  it("fails managed fitting when renderer-derived glyph extents are unavailable", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 100, maxY: 100},
      nodes: [{id: "visible", center: {x: 50, y: 50}, width: 1, height: 1, render: true}],
      groups: [],
      routes: [],
    }
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      viewState: {minZoom: -3, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 300, clientHeight: 180},
      topologyLabelSafeRect: {left: 20, top: 20, right: 280, bottom: 160},
    }
    const ctx = createStateBackedContext(state, {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "local")})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    expect(() => ctx.autoFitViewState({
      _layoutMode: "elk-scene-detail",
      _topologyScene: scene,
      nodes: [{id: "visible", x: 50, y: 50, details: {}}],
    })).toThrow(/renderer-derived glyph extents/i)
  })

  it("uses only actually rendered scene nodes for managed glyph feasibility", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 100},
      nodes: [
        {id: "visible-left", center: {x: 100, y: 50}, width: 1, height: 1, render: true},
        {id: "hidden", center: {x: 100, y: 50}, width: 1, height: 1, render: false},
        {id: "visible-right", center: {x: 900, y: 50}, width: 1, height: 1, render: true},
      ],
      groups: [],
      routes: [],
    }
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 500, clientHeight: 180},
      topologyLabelSafeRect: {left: 20, top: 20, right: 480, bottom: 160},
    }
    const ctx = createStateBackedContext(state, {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "local")})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )
    const graph = {
      _layoutMode: "elk-radial-overview",
      _topologySemanticLevel: "overview",
      _topologyScene: scene,
      nodes: [
        {id: "visible-left", x: 100, y: 50, label: "L", details: {}},
        {id: "hidden", x: 100, y: 50, clusterCount: 100, details: {cluster_kind: "endpoint-summary"}},
        {id: "visible-right", x: 900, y: 50, label: "R", details: {}},
      ],
    }

    expect(() => ctx.autoFitViewState(graph)).not.toThrow()
  })

  it("uses the overview contract at the radial semantic boundary and preserves graph shape", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 192, maxY: 1},
      nodes: [
        {id: "left", center: {x: 0, y: 0}, width: 1, height: 1, render: true},
        {id: "right", center: {x: 192, y: 0}, width: 1, height: 1, render: true},
      ],
      groups: [],
      routes: [],
    }
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 300, clientHeight: 200},
      topologyLabelSafeRect: {left: 0, top: 0, right: 300, bottom: 200},
    }
    const deps = {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "regional")}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )
    const originalSelect = ctx.selectNodeLabels
    ctx.selectNodeLabels = vi.fn((...args) => originalSelect(...args))
    const graph = {
      shape: "regional",
      _layoutMode: "elk-radial-overview",
      _topologySemanticLevel: "overview",
      _topologyScene: scene,
      nodes: [
        {id: "left", x: 0, y: 0, label: "Left", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "right", x: 192, y: 0, label: "Right", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
      ],
    }

    expect(() => ctx.autoFitViewState(graph)).not.toThrow()
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(graph.shape).toBe("regional")
    expect(ctx.selectNodeLabels).toHaveBeenLastCalledWith(
      expect.any(Array),
      "regional",
      {managedVisualDensity: "overview"},
    )
  })

  it("keeps radial overview density for a single endpoint summary", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 1, maxY: 1},
      nodes: [{id: "summary", center: {x: 0.5, y: 0.5}, width: 1, height: 1, render: true}],
      groups: [],
      routes: [],
    }
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyCameraBaseMinZoom: -8,
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 180, clientHeight: 200},
      topologyLabelSafeRect: {left: 0, top: 0, right: 180, bottom: 200},
    }
    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState({
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologySemanticLevel: "overview",
      _layoutCacheKey: "single-summary",
      _topologyScene: scene,
      nodes: [{
        id: "summary",
        x: 0.5,
        y: 0.5,
        clusterCount: 100,
        details: {cluster_kind: "endpoint-summary"},
      }],
    })

    expect(state.managedTopologyVisualDensity).toBe("overview")
  })

  it("keeps a fitted overview contract across manual and user-locked camera selection", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 1, maxY: 1},
      nodes: [{id: "node", center: {x: 0.5, y: 0.5}, width: 1, height: 1, render: true}],
      groups: [],
      routes: [],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologySemanticLevel: "overview",
      _layoutCacheKey: "single-node-narrow-safe-width",
      _topologyScene: scene,
      nodes: [{id: "node", x: 0.5, y: 0.5, details: {}}],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyCameraBaseMinZoom: -8,
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 320, clientHeight: 260},
      topologyLabelSafeRect: {left: 0, top: 0, right: 30, bottom: 260},
    }
    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )
    ctx.selectNodeLabels = undefined
    ctx.admitNodeLabelsForViewport = undefined

    ctx.autoFitViewState(graph)
    expect(state.managedTopologyVisualDensity).toBe("overview")

    const manual = ctx.managedViewStateForCamera(graph, state.viewState)
    expect(manual.managedVisualDensity).toBe("overview")

    state.userCameraLocked = true
    ctx.autoFitViewState(graph, {force: true})
    expect(state.managedTopologyVisualDensity).toBe("overview")

    const acceptedViewState = state.viewState
    state.topologyLabelSafeRect = {left: 0, top: 0, right: 15, bottom: 260}
    expect(() => ctx.autoFitViewState(graph, {force: true})).not.toThrow()
    expect(state.viewState).toBe(acceptedViewState)
    expect(state.managedTopologyVisualDensity).toBe("overview")
  })

  it("uses the overview semantic route cap without probing detail density", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 100, maxY: 0},
      nodes: [],
      groups: [],
      routes: [{
        id: "route",
        sourceId: "left",
        targetId: "right",
        points: [{x: 0, y: 0}, {x: 100, y: 0}],
      }],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologySemanticLevel: "overview",
      _layoutCacheKey: "single-route-narrow-safe-height",
      _topologyScene: scene,
      nodes: [],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyCameraBaseMinZoom: -8,
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 320, clientHeight: 260},
      topologyLabelSafeRect: {left: 0, top: 0, right: 320, bottom: 11},
    }
    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState(graph)
    expect(state.managedTopologyVisualDensity).toBe("overview")

    const manual = ctx.managedViewStateForCamera(graph, state.viewState)
    expect(manual.managedVisualDensity).toBe("overview")
  })

  it("selects a density whose routed stroke clears every nonincident glyph after fitting", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 10000, maxY: 264},
      nodes: [
        {id: "a", center: {x: 56, y: 56}, width: 112, height: 112, render: true},
        {id: "b", center: {x: 9944, y: 56}, width: 112, height: 112, render: true},
        {id: "c", center: {x: 5000, y: 208}, width: 112, height: 112, render: true},
      ],
      groups: [],
      routes: [{
        id: "a-b",
        sourceId: "a",
        targetId: "b",
        points: [{x: 112, y: 56}, {x: 9888, y: 56}],
      }],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "route-glyph-clearance",
      _topologyScene: scene,
      nodes: [
        {id: "a", x: 56, y: 56, details: {}},
        {id: "b", x: 9944, y: 56, details: {}},
        {id: "c", x: 5000, y: 208, details: {}},
      ],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyCameraBaseMinZoom: -8,
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1000, clientHeight: 500},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 500},
    }
    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState(graph)

    expect(state.managedTopologyVisualDensity).toBe("overview")
    const scale = 2 ** state.viewState.zoom
    const routeToNodeCenterPx = Math.abs(208 - 56) * scale
    const nodeRadiusPx = ctx.nodeVisibleOuterRadiusPixels(
      graph.nodes[2],
      {managedVisualDensity: state.managedTopologyVisualDensity},
    )
    const routeRadiusPx = 5
    expect(routeToNodeCenterPx).toBeGreaterThanOrEqual(nodeRadiusPx + routeRadiusPx - 1e-6)
  })

  it("selects a density whose parallel routed strokes remain visually separated after fitting", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 10_000, maxY: 1300},
      nodes: [],
      groups: [],
      routes: [
        {
          id: "upper",
          sourceId: "upper-left",
          targetId: "upper-right",
          points: [
            {x: 0, y: 0},
            {x: 1000, y: 100},
            {x: 9000, y: 100},
            {x: 10_000, y: 0},
          ],
        },
        {
          id: "lower",
          sourceId: "lower-left",
          targetId: "lower-right",
          points: [
            {x: 0, y: 1300},
            {x: 2000, y: 210},
            {x: 8000, y: 210},
            {x: 10_000, y: 1300},
          ],
        },
      ],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "route-route-clearance",
      _topologyScene: scene,
      nodes: [],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyCameraBaseMinZoom: -8,
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1000, clientHeight: 500},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 500},
    }
    const ctx = createStateBackedContext(state, {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "local")})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState(graph)

    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(110 * (2 ** state.viewState.zoom)).toBeGreaterThanOrEqual(10 - 1e-6)
  })

  it.each([
    {
      name: "cross once before running nearly parallel",
      route: {
        id: "other",
        sourceId: "other-top",
        targetId: "other-right",
        points: [{x: 100, y: -100}, {x: 100, y: 0}, {x: 200, y: 1}, {x: 900, y: 1}],
      },
    },
    {
      name: "share an endpoint before running nearly parallel",
      route: {
        id: "other",
        sourceId: "shared",
        targetId: "other-right",
        points: [{x: 0, y: 0}, {x: 100, y: 100}, {x: 200, y: 1}, {x: 900, y: 1}],
      },
    },
  ])("still constrains noncontact route portions when routes $name", ({route}) => {
    const graph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: `contact-then-parallel:${route.sourceId}`,
      _topologyScene: {
        bounds: {minX: 0, minY: -100, maxX: 1000, maxY: 100},
        nodes: [],
        groups: [],
        routes: [
          {
            id: "baseline",
            sourceId: "shared",
            targetId: "baseline-right",
            points: [{x: 0, y: 0}, {x: 1000, y: 0}],
          },
          route,
        ],
      },
      nodes: [],
    }
    const ctx = createStateBackedContext({animationPhase: 0}, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    const selection = ctx.managedVisualDensityForViewScale(graph, 10)

    expect(selection.managedVisualDensity).toBe("overview")
    expect(selection.constraints.overview).toMatchObject({
      scale: 10,
      limitingKind: "route-route",
      limitingRolePair: ["route", "route"],
    })
    // The ladder degrades rather than failing closed: a scale too tight for overview now
    // selects the compact tier instead of leaving the scene with no feasible density at all.
    expect(ctx.managedVisualDensityForViewScale(graph, 9).managedVisualDensity).toBe("compact")
  })

  it.each([
    {
      name: "one segment against two",
      baseline: [{x: 0, y: 0}, {x: 1000, y: 0}],
      sibling: [{x: 0, y: 0}, {x: 100, y: 100}, {x: 900, y: 1}],
    },
    {
      name: "two segments against two",
      baseline: [{x: 0, y: 0}, {x: 100, y: 0}, {x: 1000, y: 0}],
      sibling: [{x: 0, y: 0}, {x: 100, y: 1}, {x: 900, y: 1}],
    },
  ])("does not exempt the complete $name short-route pair at a shared endpoint", ({baseline, sibling}) => {
    const graph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: `short-shared-endpoint:${baseline.length}:${sibling[1].y}`,
      _topologyScene: {
        bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 100},
        nodes: [],
        groups: [],
        routes: [
          {id: "baseline", sourceId: "shared", targetId: "baseline-right", points: baseline},
          {id: "sibling", sourceId: "shared", targetId: "sibling-right", points: sibling},
        ],
      },
      nodes: [],
    }
    const ctx = createStateBackedContext({animationPhase: 0}, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    const selection = ctx.managedVisualDensityForViewScale(graph, 11)

    expect(selection.managedVisualDensity).toBe("overview")
    expect(selection.constraints.overview).toMatchObject({
      limitingKind: "route-route",
      limitingRolePair: ["route", "route"],
    })
    expect(selection.constraints.overview.scale).toBeGreaterThan(9)
    // The ladder degrades rather than failing closed: a scale too tight for overview now
    // selects the compact tier instead of leaving the scene with no feasible density at all.
    expect(ctx.managedVisualDensityForViewScale(graph, 9).managedVisualDensity).toBe("compact")
  })

  it("bounds a shared endpoint funnel to endpoint chrome when long terminal legs nearly overlap", () => {
    const graph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "long-shared-endpoint-funnel",
      _topologyScene: {
        bounds: {minX: 0, minY: -100, maxX: 1000, maxY: 100},
        nodes: [],
        groups: [],
        routes: [
          {
            id: "upper",
            sourceId: "shared",
            targetId: "upper-right",
            points: [{x: 0, y: 0}, {x: 900, y: 0}, {x: 1000, y: 100}],
          },
          {
            id: "lower",
            sourceId: "shared",
            targetId: "lower-right",
            points: [{x: 0, y: 0}, {x: 900, y: 1}, {x: 1000, y: -100}],
          },
        ],
      },
      nodes: [],
    }
    const ctx = createStateBackedContext({animationPhase: 0}, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    const selection = ctx.managedVisualDensityForViewScale(graph, 100)

    expect(selection.managedVisualDensity).toBe("overview")
    expect(selection.constraints.overview).toMatchObject({
      limitingKind: "route-route",
      limitingRolePair: ["route", "route"],
    })
    expect(selection.constraints.overview.scale).toBeGreaterThan(10)
    // Still genuinely infeasible: overview alone needs scale ~93.75 here, so the compact tier
    // cannot reach scale 10 either and the ladder is exhausted. This is the case that must
    // still throw -- degrading is not the same as always succeeding.
    expect(() => ctx.managedVisualDensityForViewScale(graph, 10)).toThrow(/no feasible managed visual density/i)
  })

  it.each([
    {name: "short coordinates", length: 0.02, gap: 0.005, feasibleScale: 2000},
    {name: "long coordinates", length: 20_000, gap: 5, feasibleScale: 2},
  ])("normalizes route contact math for $name", ({name, length, gap, feasibleScale}) => {
    const graph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: `near-parallel:${name}`,
      _topologyScene: {
        bounds: {minX: 0, minY: 0, maxX: length, maxY: gap},
        nodes: [],
        groups: [],
        routes: [
          {id: "upper", sourceId: "upper-left", targetId: "upper-right", points: [{x: 0, y: 0}, {x: length, y: 0}]},
          {id: "lower", sourceId: "lower-left", targetId: "lower-right", points: [{x: 0, y: gap}, {x: length, y: gap}]},
        ],
      },
      nodes: [],
    }
    const ctx = createStateBackedContext({animationPhase: 0}, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    const selection = ctx.managedVisualDensityForViewScale(graph, feasibleScale)

    expect(selection.managedVisualDensity).toBe("overview")
    expect(selection.constraints.overview).toMatchObject({
      scale: feasibleScale,
      limitingKind: "route-route",
    })
    expect(
      ctx.managedVisualDensityForViewScale(graph, feasibleScale * 0.9).managedVisualDensity,
    ).toBe("compact")
  })

  it("leaves an accepted proper route crossing under the route validator contract", () => {
    const graph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "accepted-proper-crossing",
      _topologyScene: {
        bounds: {minX: 0, minY: 0, maxX: 100, maxY: 100},
        nodes: [],
        groups: [],
        routes: [
          {id: "down", sourceId: "top-left", targetId: "bottom-right", points: [{x: 0, y: 0}, {x: 100, y: 100}]},
          {id: "up", sourceId: "bottom-left", targetId: "top-right", points: [{x: 0, y: 100}, {x: 100, y: 0}]},
        ],
      },
      nodes: [],
    }
    const ctx = createStateBackedContext({animationPhase: 0}, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    const selection = ctx.managedVisualDensityForViewScale(graph, 0.1)

    expect(selection.managedVisualDensity).toBe("detail")
    expect(selection.constraints.detail.scale).toBe(0)
    expect(selection.constraints.overview.scale).toBe(0)
  })

  it("keeps a feasible managed scene in the highest-detail contract", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 192, maxY: 1},
      nodes: [
        {id: "left", center: {x: 0, y: 0}, width: 1, height: 1, render: true},
        {id: "right", center: {x: 192, y: 0}, width: 1, height: 1, render: true},
      ],
      groups: [],
      routes: [],
    }
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 300, clientHeight: 200},
      topologyLabelSafeRect: {left: 0, top: 0, right: 300, bottom: 200},
    }
    const ctx = createStateBackedContext(state, {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "local")})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState({
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
      _topologyScene: scene,
      nodes: [
        {id: "left", x: 0, y: 0, details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "right", x: 192, y: 0, details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
      ],
    })

    expect(state.managedTopologyVisualDensity).toBe("detail")
  })

  it("selects manual-zoom density from actual role-specific glyph separation", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 600, maxY: 192},
      nodes: [
        {id: "member-left", center: {x: 0, y: 0}, width: 96, height: 96, render: true},
        {id: "member-right", center: {x: 192, y: 0}, width: 96, height: 96, render: true},
        {id: "anchor", center: {x: 0, y: 192}, width: 112, height: 112, render: true},
        {id: "summary", center: {x: 600, y: 192}, width: 448, height: 448, render: true},
      ],
      groups: [],
      routes: [],
    }
    const graph = {
      _layoutMode: "elk-scene-detail",
      _topologyScene: scene,
      nodes: [
        {id: "member-left", clusterCount: 1, details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "member-right", clusterCount: 1, details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "anchor", clusterCount: 1, details: {cluster_kind: "endpoint-anchor"}},
        {id: "summary", clusterCount: 100, details: {cluster_kind: "endpoint-summary"}},
      ],
    }
    const state = {animationPhase: 0}
    const ctx = createStateBackedContext(state, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    const detail = ctx.managedVisualDensityForViewScale(graph, 0.4)
    const overview = ctx.managedVisualDensityForViewScale(graph, 0.2)

    expect(detail.managedVisualDensity).toBe("detail")
    expect(overview.managedVisualDensity).toBe("overview")
    expect(detail.constraints.detail.limitingRolePair).toEqual(["member", "member"])
    expect(overview.constraints.overview.scale).toBeLessThanOrEqual(0.2)
    expect(() => ctx.managedVisualDensityForViewScale(graph, 0.01)).toThrow(
      /no feasible managed visual density.*scale=0.01/i,
    )
  })

  it("reuses routed-geometry constraints across immutable hydration of the same layout key", () => {
    const routePoints = (onRead, y) => ({
      id: `route-${y}`,
      sourceId: `left-${y}`,
      targetId: `right-${y}`,
      get points() {
        onRead()
        return [{x: 0, y}, {x: 1000, y}]
      },
    })
    const hydratedGraph = (onRead) => ({
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "stable-hydrated-layout",
      _topologyScene: {
        key: "stable-scene",
        bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 100},
        nodes: [],
        groups: [],
        routes: [routePoints(onRead, 0), routePoints(onRead, 100)],
      },
      nodes: [],
    })
    let firstRouteReads = 0
    let hydratedRouteReads = 0
    const ctx = createStateBackedContext({animationPhase: 0}, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    const first = ctx.managedVisualDensityForViewScale(
      hydratedGraph(() => { firstRouteReads += 1 }),
      1,
    )
    const hydrated = ctx.managedVisualDensityForViewScale(
      hydratedGraph(() => { hydratedRouteReads += 1 }),
      1,
    )

    expect(first.managedVisualDensity).toBe("detail")
    expect(hydrated.managedVisualDensity).toBe("detail")
    expect(firstRouteReads).toBeGreaterThan(0)
    expect(hydratedRouteReads).toBe(0)
  })

  it("does not promote the overview separation constraint into a camera minimum", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 192, maxY: 1},
      nodes: [
        {id: "left", center: {x: 0, y: 0}, width: 96, height: 96, render: true},
        {id: "right", center: {x: 192, y: 0}, width: 96, height: 96, render: true},
      ],
      groups: [],
      routes: [],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "overview",
      _topologyScene: scene,
      nodes: [
        {id: "left", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "right", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
      ],
    }
    const ctx = createStateBackedContext({
      animationPhase: 0,
      managedTopologyCameraBaseMinZoom: -8,
    }, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    expect(typeof ctx.managedViewStateForCamera).toBe("function")
    const selected = ctx.managedViewStateForCamera(graph, {
      zoom: -8,
      minZoom: -8,
      maxZoom: 5,
      target: [96, 0, 0],
    })

    expect(selected.viewState.minZoom).toBe(-8)
    expect(selected.viewState.zoom).toBe(-8)
    expect(selected.viewState.minZoom).toBeLessThanOrEqual(selected.viewState.zoom)
    expect(selected.managedVisualDensity).toBe("overview")
  })

  it("does not ratchet scene camera floors from glyph-separation constraints", () => {
    const managedPairGraph = (distance) => {
      const scene = {
        bounds: {minX: 0, minY: 0, maxX: distance, maxY: 1},
        nodes: [
          {id: "left", center: {x: 0, y: 0}, width: 96, height: 96, render: true},
          {id: "right", center: {x: distance, y: 0}, width: 96, height: 96, render: true},
        ],
        groups: [],
        routes: [],
      }
      return {
        shape: "local",
        _layoutMode: "elk-radial-overview",
        _topologySemanticLevel: "overview",
        _topologyScene: scene,
        nodes: [
          {id: "left", x: 0, y: 0, details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
          {id: "right", x: distance, y: 0, details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
        ],
      }
    }
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      zoomMode: "auto",
      managedTopologyCameraBaseMinZoom: -2,
      viewState: {minZoom: -2, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1000, clientHeight: 700},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 700},
    }
    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState(managedPairGraph(32))
    expect(state.viewState.minZoom).toBe(-2)
    expect(state.viewState.minZoom).toBeLessThanOrEqual(state.viewState.zoom)

    state.hasAutoFit = false
    const looseGraph = managedPairGraph(192)
    ctx.autoFitViewState(looseGraph)

    expect(state.viewState.minZoom).toEqual(-2)
    expect(state.managedTopologySceneForMinZoom).toBe(looseGraph._topologyScene)
  })

  it("retains a fitted scene floor across immutable cache hydration with the same layout key", () => {
    const managedGraph = () => ({
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
      _layoutCacheKey: "portrait-layout",
      _topologyScene: {
        bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 1},
        nodes: [
          {id: "left", center: {x: 0, y: 0}, width: 96, height: 96, render: true},
          {id: "right", center: {x: 1000, y: 0}, width: 96, height: 96, render: true},
        ],
        groups: [],
        routes: [],
      },
      nodes: [
        {id: "left", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "right", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
      ],
    })
    const state = {animationPhase: 0, managedTopologyCameraBaseMinZoom: -2}
    const ctx = createStateBackedContext(state, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )
    const accepted = managedGraph()
    const fitted = ctx.managedViewStateForCamera(
      accepted,
      {zoom: -4, minZoom: -2, maxZoom: 5, target: [500, 0, 0]},
      {fittedContainmentZoom: -4},
    )
    expect(fitted.viewState.minZoom).toEqual(-4)

    const hydrated = managedGraph()
    expect(hydrated._topologyScene).not.toBe(accepted._topologyScene)
    const manual = ctx.managedViewStateForCamera(hydrated, {
      ...fitted.viewState,
      zoom: -8,
      minZoom: -2,
    })

    expect(manual.viewState.minZoom).toEqual(-4)
    expect(manual.viewState.zoom).toEqual(-4)
  })

  it("forced managed refit leaves a user-locked camera untouched", () => {
    const originalViewState = {minZoom: -3, maxZoom: 5, zoom: 2, target: [777, 555, 0]}
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      hasAutoFit: true,
      userCameraLocked: true,
      zoomMode: "auto",
      viewState: originalViewState,
      el: {clientWidth: 1000, clientHeight: 700},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 700},
    }
    const ctx = createStateBackedContext(state, {setZoomTier: vi.fn(), resolveZoomTier: vi.fn()})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState({
      _layoutMode: "elk-scene-detail",
      _topologyScene: expandedSceneForViewTest(),
      nodes: [{id: "node", x: 0, y: 0}],
    }, {force: true})

    expect(state.viewState).toBe(originalViewState)
    expect(state.deck.setProps).not.toHaveBeenCalled()
  })

  it("reselects feasible density for a new managed scene without moving a user-locked camera", () => {
    const originalViewState = {minZoom: -3, maxZoom: 5, zoom: -2, target: [777, 555, 0]}
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 96, maxY: 1},
      nodes: [
        {id: "left", center: {x: 0, y: 0}, width: 96, height: 96, render: true},
        {id: "right", center: {x: 96, y: 0}, width: 96, height: 96, render: true},
      ],
      groups: [],
      routes: [],
    }
    const graph = {
      _layoutMode: "elk-scene-detail",
      _topologyScene: scene,
      nodes: [
        {id: "left", x: 0, y: 0, details: {}},
        {id: "right", x: 96, y: 0, details: {}},
      ],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      hasAutoFit: true,
      userCameraLocked: true,
      zoomMode: "auto",
      managedTopologyVisualDensity: "detail",
      viewState: originalViewState,
      el: {clientWidth: 1000, clientHeight: 700},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 700},
    }
    const ctx = createStateBackedContext(state, {setZoomTier: vi.fn(), resolveZoomTier: vi.fn()})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    ctx.autoFitViewState(graph, {force: true})

    expect(state.viewState).toBe(originalViewState)
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(state.deck.setProps).not.toHaveBeenCalled()
  })

  it("focusClusterNeighborhood recenters and zooms toward an expanded cluster neighborhood", () => {
    const state = {
      deck: {setProps: vi.fn()},
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      viewState: {minZoom: -2, maxZoom: 8, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1200, clientHeight: 800},
    }

    const deps = {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    const focused = ctx.focusClusterNeighborhood(
      {
        nodes: [
          {id: "anchor-1", x: 500, y: 120, details: {}},
          {id: "cluster:endpoints:sr:test", x: 560, y: 220, details: {cluster_id: "cluster:endpoints:sr:test", cluster_anchor_id: "anchor-1"}},
          {id: "endpoint-1", x: 520, y: 340, details: {cluster_id: "cluster:endpoints:sr:test", cluster_kind: "endpoint-member"}},
          {id: "endpoint-2", x: 610, y: 340, details: {cluster_id: "cluster:endpoints:sr:test", cluster_kind: "endpoint-member"}},
        ],
      },
      "cluster:endpoints:sr:test",
    )

    expect(focused).toBe(true)
    expect(state.viewState.zoom).toBeGreaterThan(1)
    expect(state.viewState.target[0]).toBeGreaterThan(540)
    expect(state.viewState.target[1]).toBeGreaterThan(200)
    expect(state.viewState.target[1]).toBeLessThan(260)
    expect(state.isProgrammaticViewUpdate).toBe(true)
    expect(state.deck.setProps).toHaveBeenCalled()
    expect(deps.setZoomTier).toHaveBeenCalled()
  })

  it("focusClusterNeighborhood includes radial cluster fanout footprint when framing the local view", () => {
    const state = {
      deck: {setProps: vi.fn()},
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      viewState: {minZoom: -2, maxZoom: 8, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1200, clientHeight: 800},
    }

    const deps = {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    const focused = ctx.focusClusterNeighborhood(
      {
        _layoutMode: "client-radial",
        nodes: [
          {id: "switch-1", x: 420, y: 280, details: {}},
          {
            id: "cluster-anchor",
            x: 520,
            y: 280,
            details: {cluster_id: "cluster:endpoints:sr:test", cluster_kind: "endpoint-anchor", cluster_anchor_id: "switch-1"},
          },
          {
            id: "cluster:endpoints:sr:test",
            x: 650,
            y: 280,
            details: {cluster_id: "cluster:endpoints:sr:test", cluster_kind: "endpoint-summary", cluster_anchor_id: "switch-1"},
          },
          {
            id: "endpoint-1",
            x: 760,
            y: 180,
            details: {cluster_id: "cluster:endpoints:sr:test", cluster_kind: "endpoint-member", cluster_anchor_id: "switch-1"},
          },
          {
            id: "endpoint-2",
            x: 820,
            y: 280,
            details: {cluster_id: "cluster:endpoints:sr:test", cluster_kind: "endpoint-member", cluster_anchor_id: "switch-1"},
          },
          {
            id: "endpoint-3",
            x: 760,
            y: 380,
            details: {cluster_id: "cluster:endpoints:sr:test", cluster_kind: "endpoint-member", cluster_anchor_id: "switch-1"},
          },
        ],
      },
      "cluster:endpoints:sr:test",
    )

    expect(focused).toBe(true)
    expect(state.viewState.zoom).toBeGreaterThan(0.9)
    expect(state.viewState.target[0]).toBeGreaterThan(600)
    expect(state.viewState.target[0]).toBeLessThan(760)
    expect(state.viewState.target[1]).toBeGreaterThan(220)
    expect(state.viewState.target[1]).toBeLessThan(320)
  })

  it("fails detail focus closed instead of retrying missing labels at overview density", () => {
    const group = {
      id: "g",
      bounds: {minX: 0, minY: 0, maxX: 192, maxY: 1},
      memberIds: ["left", "right"],
    }
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 192, maxY: 1},
      nodes: [
        {id: "left", center: {x: 0, y: 0}, width: 1, height: 1, groupId: "g", render: true},
        {id: "right", center: {x: 192, y: 0}, width: 1, height: 1, groupId: "g", render: true},
      ],
      groups: [group],
      routes: [],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
      _layoutCacheKey: "narrow-focus",
      _topologyScene: scene,
      // Nothing expanded: this is a bounded frame, which is the case that still fails
      // closed. The subject here is that focus does not silently retry at overview
      // density, not how the scene became bounded.
      nodes: [
        {id: "left", x: 0, y: 0, details: {}},
        {id: "right", x: 192, y: 0, details: {}},
      ],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyVisualDensity: "detail",
      managedTopologyCameraBaseMinZoom: -8,
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 50, clientHeight: 200},
      topologyLabelSafeRect: {left: 0, top: 0, right: 50, bottom: 200},
    }
    const deps = {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "local")}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )
    ctx.admitNodeLabelsForViewport = vi.fn((_effective, _candidates, _protectedNodes, options) => ({
      admitted: [],
      detailsFallbackIds: [],
      missingRequiredLabelIds: options.managedVisualDensity === "detail" ? ["zeta", "alpha"] : [],
    }))

    expect(() => ctx.focusClusterNeighborhood(graph, "g")).toThrow(
      /topology focus.*missing required labels.*alpha, zeta/i,
    )
    expect(state.managedTopologyVisualDensity).toBe("detail")
    expect(state.deck.setProps).not.toHaveBeenCalled()
    expect(ctx.admitNodeLabelsForViewport.mock.calls.map((call) => call[3].managedVisualDensity)).toEqual(["detail"])
  })

  it("uses overview density directly for overview-semantic focus", () => {
    const group = {id: "g", bounds: {minX: 0, minY: 0, maxX: 100, maxY: 1}, memberIds: ["member"]}
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 100, maxY: 1},
      nodes: [{id: "member", center: {x: 50, y: 0}, width: 1, height: 1, groupId: "g", render: true}],
      groups: [group],
      routes: [],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-radial-overview",
      _topologySemanticLevel: "overview",
      _layoutCacheKey: "overview-focus-density",
      _topologyScene: scene,
      nodes: [{id: "member", x: 50, y: 0, label: "Member", details: {cluster_kind: "endpoint-member"}}],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyVisualDensity: "overview",
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 300, clientHeight: 200},
      topologyLabelSafeRect: {left: 0, top: 0, right: 300, bottom: 200},
    }
    const ctx = createStateBackedContext(state, {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "local")})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )
    const originalAdmission = ctx.admitNodeLabelsForViewport
    ctx.admitNodeLabelsForViewport = vi.fn((...args) => originalAdmission(...args))

    expect(ctx.focusClusterNeighborhood(graph, "g")).toBe(true)
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(ctx.admitNodeLabelsForViewport.mock.calls.map((call) => call[3].managedVisualDensity)).toEqual(["overview"])
  })

  it("lets a complete managed focus fit below the configured base zoom without clipping it", () => {
    const group = {
      id: "wide-group",
      bounds: {minX: 944, minY: 0, maxX: 10_056, maxY: 112},
      anchorId: "anchor",
      gatewayId: "gateway",
      memberIds: ["far-member"],
    }
    const scene = {
      bounds: {minX: -56, minY: 0, maxX: 10_056, maxY: 112},
      nodes: [
        {id: "anchor", center: {x: 0, y: 56}, width: 112, height: 112, render: true},
        {id: "gateway", center: {x: 1000, y: 56}, width: 112, height: 112, groupId: "wide-group", render: true},
        {id: "far-member", center: {x: 10_000, y: 56}, width: 112, height: 112, groupId: "wide-group", render: true},
      ],
      groups: [group],
      routes: [{
        id: "trunk",
        sourceId: "anchor",
        targetId: "gateway",
        points: [{x: 56, y: 56}, {x: 944, y: 56}],
      }],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
      _layoutCacheKey: "wide-focus",
      _topologyScene: scene,
      nodes: [
        {id: "anchor", x: 0, y: 56, label: "Anchor", details: {cluster_kind: "endpoint-anchor"}},
        {id: "gateway", x: 1000, y: 56, label: "Gateway", details: {cluster_kind: "endpoint-summary"}},
        {id: "far-member", x: 10_000, y: 56, label: "Far", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
      ],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      userCameraLocked: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyCameraBaseMinZoom: -2,
      viewState: {minZoom: -2, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1000, clientHeight: 400},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 400},
      topologyLabelMeasureText: () => ({width: 6, height: 12}),
    }
    const ctx = createStateBackedContext(state, {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "local")})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )

    expect(ctx.focusClusterNeighborhood(graph, group.id)).toBe(true)

    expect(state.viewState.zoom).toBeLessThan(-2)
    const scale = 2 ** state.viewState.zoom
    const left = (state.el.clientWidth / 2) + ((group.bounds.minX - state.viewState.target[0]) * scale)
    const right = (state.el.clientWidth / 2) + ((group.bounds.maxX - state.viewState.target[0]) * scale)
    expect(left).toBeGreaterThanOrEqual(state.topologyLabelSafeRect.left - 1)
    expect(right).toBeLessThanOrEqual(state.topologyLabelSafeRect.right + 1)
  })

  it("contains managed detail focus to the selected ELK neighborhood without a density floor", () => {
    const selectedGroup = {
      id: "selected",
      bounds: {minX: 944, minY: 0, maxX: 20_056, maxY: 112},
      anchorId: "anchor",
      gatewayId: "gateway",
      memberIds: ["far-member"],
    }
    const unrelatedGroup = {
      id: "unrelated",
      bounds: {minX: 30_000, minY: 0, maxX: 30_320, maxY: 112},
      gatewayId: "near-a",
      memberIds: ["near-b"],
    }
    const scene = {
      bounds: {minX: -56, minY: 0, maxX: 30_320, maxY: 112},
      nodes: [
        {id: "anchor", center: {x: 0, y: 56}, width: 112, height: 112, render: true},
        {id: "gateway", center: {x: 1000, y: 56}, width: 112, height: 112, groupId: "selected", render: true},
        {id: "far-member", center: {x: 20_000, y: 56}, width: 112, height: 112, groupId: "selected", render: true},
        {id: "near-a", center: {x: 30_056, y: 56}, width: 112, height: 112, groupId: "unrelated", render: true},
        {id: "near-b", center: {x: 30_264, y: 56}, width: 112, height: 112, groupId: "unrelated", render: true},
      ],
      groups: [selectedGroup, unrelatedGroup],
      routes: [{
        id: "selected-trunk",
        sourceId: "anchor",
        targetId: "gateway",
        points: [{x: 56, y: 56}, {x: 944, y: 56}],
      }],
    }
    const graph = {
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
      _layoutCacheKey: "focus-neighborhood-density",
      _topologyScene: scene,
      nodes: [
        {id: "anchor", x: 0, y: 56, details: {}},
        {id: "gateway", x: 1000, y: 56, details: {cluster_kind: "endpoint-summary"}},
        {id: "far-member", x: 20_000, y: 56, details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
        {id: "near-a", x: 30_056, y: 56, details: {}},
        {id: "near-b", x: 30_264, y: 56, details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
      ],
    }
    const state = {
      animationPhase: 0,
      deck: {setProps: vi.fn()},
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      managedTopologyCameraBaseMinZoom: -8,
      viewState: {minZoom: -8, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1000, clientHeight: 400},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 400},
    }
    const ctx = createStateBackedContext(state, {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    })
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )
    ctx.selectNodeLabels = undefined
    ctx.admitNodeLabelsForViewport = undefined

    expect(ctx.focusClusterNeighborhood(graph, selectedGroup.id)).toBe(true)

    expect(state.managedTopologyVisualDensity).toBe("detail")
    expect(2 ** state.viewState.zoom).toBeLessThan(20 / 208)
    const left = projectNode({x: scene.bounds.minX, y: 56}, state)
    const right = projectNode({x: selectedGroup.bounds.maxX, y: 56}, state)
    expect(left.x).toBeGreaterThanOrEqual(state.topologyLabelSafeRect.left - 1)
    expect(right.x).toBeLessThanOrEqual(state.topologyLabelSafeRect.right + 1)
  })

  it("focuses complete ELK neighborhood visuals using actual summary halo and admitted labels", () => {
    const selectedGroup = {
      id: "group-a",
      bounds: {minX: 300, minY: 20, maxX: 700, maxY: 300},
      anchorId: "anchor-a",
      gatewayId: "summary-a",
      memberIds: ["member-a"],
    }
    const otherGroup = {
      id: "group-b",
      bounds: {minX: 4000, minY: 20, maxX: 4300, maxY: 300},
      anchorId: "anchor-b",
      gatewayId: "summary-b",
      memberIds: ["member-b"],
    }
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 4300, maxY: 320},
      nodes: [
        {id: "anchor-a", center: {x: 0, y: 160}, width: 1, height: 1},
        {id: "summary-a", center: {x: 300, y: 160}, width: 1, height: 1, groupId: "group-a"},
        {id: "member-a", center: {x: 700, y: 160}, width: 1, height: 1, groupId: "group-a"},
        {id: "anchor-b", center: {x: 3800, y: 160}, width: 1, height: 1},
        {id: "summary-b", center: {x: 4000, y: 160}, width: 1, height: 1, groupId: "group-b"},
        {id: "member-b", center: {x: 4300, y: 160}, width: 1, height: 1, groupId: "group-b"},
      ],
      groups: [selectedGroup, otherGroup],
      routes: [
        {id: "trunk-a", sourceId: "anchor-a", targetId: "summary-a", strokeWidth: 38, points: [{x: 0, y: 160}, {x: 300, y: 160}]},
        {id: "trunk-b", sourceId: "anchor-b", targetId: "summary-b", strokeWidth: 38, points: [{x: 3800, y: 160}, {x: 4000, y: 160}]},
      ],
    }
    const nodes = [
      {id: "anchor-a", x: 0, y: 160, label: "Anchor A", details: {cluster_kind: "endpoint-anchor"}},
      {id: "summary-a", x: 300, y: 160, label: "One hundred endpoints", clusterCount: 100, details: {cluster_kind: "endpoint-summary"}},
      {id: "member-a", x: 700, y: 160, label: "Selected neighborhood member", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
      {id: "anchor-b", x: 3800, y: 160, label: "Anchor B", details: {cluster_kind: "endpoint-anchor"}},
      {id: "summary-b", x: 4000, y: 160, label: "Other summary", clusterCount: 24, details: {cluster_kind: "endpoint-summary"}},
      {id: "member-b", x: 4300, y: 160, label: "Other member", details: {cluster_kind: "endpoint-member", cluster_expanded: true}},
    ]
    const state = {
      deck: {setProps: vi.fn()},
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      layers: {mantle: true, crust: true},
      viewState: {minZoom: -4, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1400, clientHeight: 700},
      topologyLabelSafeRect: {left: 40, top: 30, right: 1300, bottom: 610},
      topologyLabelMeasureText: () => ({width: 60, height: 12}),
    }
    const deps = {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "local")}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingGraphLayerNodeMethods),
      bindApi(ctx, godViewRenderingGraphViewMethods),
    )
    const originalAdmission = ctx.admitNodeLabelsForViewport
    ctx.admitNodeLabelsForViewport = vi.fn((...args) => originalAdmission(...args))
    const originalGroups = scene.groups.map((group) => ({...group, memberIds: [...group.memberIds]}))

    const focused = ctx.focusClusterNeighborhood(
      {
        _layoutMode: "elk-scene-detail",
        _topologySemanticLevel: "detail",
        _topologyScene: scene,
        shape: "local",
        nodes,
      },
      selectedGroup.id,
    )

    expect(focused).toBe(true)
    expect(state.managedTopologyVisualDensity).toBe("detail")
    const summary = projectNode(nodes[1], state)
    const summaryRadius = ctx.nodeHaloRadiusPixels(nodes[1])
    expect(summaryRadius).toBe(65)
    expect(summary.x - summaryRadius).toBeGreaterThanOrEqual(state.topologyLabelSafeRect.left - 1)
    expect(summary.x + summaryRadius).toBeLessThanOrEqual(state.topologyLabelSafeRect.right + 1)
    expect(ctx.admitNodeLabelsForViewport).toHaveBeenCalled()
    const finalAdmission = ctx.admitNodeLabelsForViewport.mock.results.at(-1).value
    expect(finalAdmission.admitted.length).toBeGreaterThan(0)
    for (const label of finalAdmission.admitted) {
      expect(label.box.left).toBeGreaterThanOrEqual(state.topologyLabelSafeRect.left - 1)
      expect(label.box.top).toBeGreaterThanOrEqual(state.topologyLabelSafeRect.top - 1)
      expect(label.box.right).toBeLessThanOrEqual(state.topologyLabelSafeRect.right + 1)
      expect(label.box.bottom).toBeLessThanOrEqual(state.topologyLabelSafeRect.bottom + 1)
    }
    expect(scene.groups).toEqual(originalGroups)
  })
})

function expandedSceneForViewTest() {
  return {
    bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 500},
    nodes: [{id: "node", center: {x: 500, y: 250}, width: 112, height: 112}],
    groups: [],
    routes: [],
  }
}
