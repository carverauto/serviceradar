import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
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
      bounds: {minX: -200, minY: -100, maxX: 1400, maxY: 700},
      nodes: [
        {id: "left", center: {x: -144, y: 0}, width: 112, height: 112},
        {id: "right", center: {x: 1344, y: 600}, width: 112, height: 112},
      ],
      groups: [],
      routes: [{id: "route", sourceId: "left", targetId: "right", points: [{x: -200, y: 0}, {x: 1400, y: 700}]}],
    }
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: false,
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "auto",
      viewState: {minZoom: -3, maxZoom: 5, zoom: 0, target: [0, 0, 0]},
      el: {clientWidth: 1000, clientHeight: 700},
      topologyLabelSafeRect: {left: 40, top: 30, right: 820, bottom: 610},
    }
    const deps = {setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "regional")}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    ctx.autoFitViewState({_layoutMode: "elk-scene", _topologyScene: scene, nodes: []})

    const topLeft = projectNode({x: scene.bounds.minX, y: scene.bounds.minY}, state)
    const bottomRight = projectNode({x: scene.bounds.maxX, y: scene.bounds.maxY}, state)
    expect(topLeft.x).toBeGreaterThanOrEqual(state.topologyLabelSafeRect.left - 1)
    expect(topLeft.y).toBeGreaterThanOrEqual(state.topologyLabelSafeRect.top - 1)
    expect(bottomRight.x).toBeLessThanOrEqual(state.topologyLabelSafeRect.right + 1)
    expect(bottomRight.y).toBeLessThanOrEqual(state.topologyLabelSafeRect.bottom + 1)
    expect(deps.setZoomTier).toHaveBeenCalledWith("local", true)
    expect(scene.bounds).toEqual({minX: -200, minY: -100, maxX: 1400, maxY: 700})
  })

  it("forced managed refit leaves a user-locked camera untouched", () => {
    const originalViewState = {minZoom: -3, maxZoom: 5, zoom: 2, target: [777, 555, 0]}
    const state = {
      deck: {setProps: vi.fn()},
      hasAutoFit: true,
      userCameraLocked: true,
      zoomMode: "auto",
      viewState: originalViewState,
      el: {clientWidth: 1000, clientHeight: 700},
      topologyLabelSafeRect: {left: 0, top: 0, right: 1000, bottom: 700},
    }
    const ctx = createStateBackedContext(state, {setZoomTier: vi.fn(), resolveZoomTier: vi.fn()})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphViewMethods))

    ctx.autoFitViewState({
      _layoutMode: "elk-scene",
      _topologyScene: expandedSceneForViewTest(),
      nodes: [{id: "node", x: 0, y: 0}],
    }, {force: true})

    expect(state.viewState).toBe(originalViewState)
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
})

function expandedSceneForViewTest() {
  return {
    bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 500},
    nodes: [{id: "node", center: {x: 500, y: 250}, width: 112, height: 112}],
    groups: [],
    routes: [],
  }
}
