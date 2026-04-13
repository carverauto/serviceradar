import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphViewMethods} from "./rendering_graph_view_methods"

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
