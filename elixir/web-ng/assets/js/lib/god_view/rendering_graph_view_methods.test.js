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
    expect(state.viewState.target[1]).toBeGreaterThan(220)
    expect(state.isProgrammaticViewUpdate).toBe(true)
    expect(state.deck.setProps).toHaveBeenCalled()
    expect(deps.setZoomTier).toHaveBeenCalled()
  })
})
