import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleDomInteractionMethods} from "./lifecycle_dom_interaction_methods"

afterEach(() => {
  vi.restoreAllMocks()
})

let originalWindow

beforeEach(() => {
  originalWindow = globalThis.window
  globalThis.window = {
    requestAnimationFrame: vi.fn(() => 101),
    cancelAnimationFrame: vi.fn(),
    matchMedia: vi.fn(() => ({
      matches: false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })),
  }
})

afterEach(() => {
  globalThis.window = originalWindow
})

function makeContext({state = {}, deps = {}, overrides = {}} = {}) {
  const initialState = {
    prefersReducedMotion: false,
    animationTimer: null,
    reducedMotionMediaQuery: null,
    reducedMotionListener: null,
    deck: {setProps: vi.fn()},
    lastGraph: {nodes: []},
    summary: {textContent: ""},
    viewState: {zoom: 1, minZoom: -2, maxZoom: 5, target: [0, 0, 0]},
    zoomMode: "local",
    ...state,
  }
  const initialDeps = {
    renderGraph: vi.fn(),
    refreshGraphLayersForViewState: vi.fn(),
    setZoomTier: vi.fn(),
    resolveZoomTier: vi.fn(() => "local"),
    managedVisualDensityForViewScale: vi.fn(() => ({managedVisualDensity: "detail"})),
    ...deps,
  }

  const ctx = createStateBackedContext(initialState, initialDeps)
  Object.assign(ctx, bindApi(ctx, godViewLifecycleDomInteractionMethods), overrides)
  return ctx
}

describe("lifecycle_dom_interaction_methods", () => {
  it("startAnimationLoop still schedules RAF when reduced motion is enabled", () => {
    const rafSpy = vi.spyOn(globalThis.window, "requestAnimationFrame")
    const ctx = makeContext({state: {prefersReducedMotion: true}})

    ctx.startAnimationLoop()

    expect(rafSpy).toHaveBeenCalledTimes(1)
    expect(ctx.state.animationTimer).toEqual(101)
  })

  it("startAnimationLoop schedules RAF when reduced motion is disabled", () => {
    const rafSpy = vi.spyOn(globalThis.window, "requestAnimationFrame").mockImplementation(() => 123)
    const cancelSpy = vi.spyOn(globalThis.window, "cancelAnimationFrame").mockImplementation(() => {})
    const ctx = makeContext()

    ctx.startAnimationLoop()
    expect(rafSpy).toHaveBeenCalledTimes(1)
    expect(ctx.state.animationTimer).toEqual(123)

    ctx.stopAnimationLoop()
    expect(cancelSpy).toHaveBeenCalledWith(123)
    expect(ctx.state.animationTimer).toEqual(null)
  })

  it("handleReducedMotionPreferenceChange toggles preference without stopping active RAF", () => {
    const cancelSpy = vi.spyOn(globalThis.window, "cancelAnimationFrame").mockImplementation(() => {})
    const ctx = makeContext({state: {animationTimer: 44, prefersReducedMotion: false}})

    ctx.handleReducedMotionPreferenceChange({matches: true})

    expect(ctx.state.prefersReducedMotion).toEqual(true)
    expect(cancelSpy).not.toHaveBeenCalled()
    expect(ctx.deps.renderGraph).not.toHaveBeenCalled()
  })

  it("syncReducedMotionPreference subscribes to media query changes and applies initial state", () => {
    const addEventListener = vi.fn()
    const mediaQuery = {matches: true, addEventListener}
    const matchMediaSpy = vi.spyOn(globalThis.window, "matchMedia").mockImplementation(() => mediaQuery)
    const ctx = makeContext()
    const handleSpy = vi.spyOn(ctx, "handleReducedMotionPreferenceChange")

    ctx.syncReducedMotionPreference()

    expect(matchMediaSpy).toHaveBeenCalledWith("(prefers-reduced-motion: reduce)")
    expect(ctx.state.reducedMotionMediaQuery).toEqual(mediaQuery)
    expect(typeof ctx.state.reducedMotionListener).toEqual("function")
    expect(addEventListener).toHaveBeenCalledWith("change", ctx.state.reducedMotionListener)
    expect(handleSpy).toHaveBeenCalledWith(mediaQuery)
  })

  it("handlePanStart/Move uses threshold so click does not instantly become drag", () => {
    const preventDefault = vi.fn()
    const setPointerCapture = vi.fn()
    const ctx = makeContext({
      state: {
        canvas: {style: {cursor: "grab"}, setPointerCapture},
      },
    })

    ctx.handlePanStart({button: 0, pointerId: 11, clientX: 100, clientY: 100})
    expect(ctx.state.pendingDragState.pointerId).toEqual(11)
    expect(ctx.state.dragState).toBeUndefined()

    ctx.handlePanMove({pointerId: 11, clientX: 102, clientY: 101, preventDefault})
    expect(ctx.state.dragState).toBeUndefined()
    expect(preventDefault).not.toHaveBeenCalled()

    ctx.handlePanMove({pointerId: 11, clientX: 110, clientY: 110, preventDefault})
    expect(ctx.state.dragState.pointerId).toEqual(11)
    expect(preventDefault).toHaveBeenCalled()
    expect(setPointerCapture).toHaveBeenCalledWith(11)
  })

  it("handleWheelZoom preserves the world point under the pointer", () => {
    const rect = {left: 0, top: 0, width: 1000, height: 500}
    const canvas = {getBoundingClientRect: vi.fn(() => rect)}
    const state = {
      canvas,
      deck: {setProps: vi.fn()},
      viewState: {zoom: 1, minZoom: -2, maxZoom: 5, target: [100, 50, 0]},
      zoomMode: "auto",
    }
    const deps = {
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "regional"),
    }
    const ctx = makeContext({state, deps})
    const event = {
      clientX: 700,
      clientY: 350,
      deltaY: -120,
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }
    const worldBefore = {
      x: state.viewState.target[0] + (event.clientX - rect.width / 2) / (2 ** state.viewState.zoom),
      y: state.viewState.target[1] + (event.clientY - rect.height / 2) / (2 ** state.viewState.zoom),
    }

    ctx.handleWheelZoom(event)

    const next = ctx.state.viewState
    const worldAfter = {
      x: next.target[0] + (event.clientX - rect.width / 2) / (2 ** next.zoom),
      y: next.target[1] + (event.clientY - rect.height / 2) / (2 ** next.zoom),
    }

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(next.zoom).toBeGreaterThan(1)
    expect(worldAfter.x).toBeCloseTo(worldBefore.x, 5)
    expect(worldAfter.y).toBeCloseTo(worldBefore.y, 5)
    expect(ctx.state.userCameraLocked).toEqual(true)
    expect(ctx.state.deck.setProps).toHaveBeenCalledWith({viewState: ctx.state.viewState})
    expect(deps.setZoomTier).toHaveBeenCalledWith("regional", false)
    expect(ctx.deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
  })

  it("custom wheel zoom keeps an accepted ELK scene local across legacy tier thresholds", () => {
    const scene = {id: "authoritative-scene"}
    const graph = {_layoutMode: "elk-scene", _topologyScene: scene, nodes: [], edges: []}
    const canvas = {getBoundingClientRect: () => ({left: 0, top: 0, width: 1000, height: 600})}
    const ctx = makeContext({
      state: {
        canvas,
        lastGraph: graph,
        zoomMode: "auto",
        zoomTier: "local",
        viewState: {zoom: 0, minZoom: -5, maxZoom: 5, target: [0, 0, 0]},
      },
      deps: {resolveZoomTier: vi.fn(() => "global")},
    })

    ctx.handleWheelZoom({
      clientX: 500,
      clientY: 300,
      deltaY: 1000,
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    })

    expect(ctx.state.viewState.zoom).toBeLessThan(0)
    expect(ctx.state.zoomTier).toBe("local")
    expect(ctx.state.lastGraph).toBe(graph)
    expect(ctx.state.lastGraph._topologyScene).toBe(scene)
    expect(ctx.deps.resolveZoomTier).not.toHaveBeenCalled()
    expect(ctx.deps.setZoomTier).not.toHaveBeenCalled()
    expect(ctx.deps.renderGraph).not.toHaveBeenCalled()
    expect(ctx.deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
  })

  it("button zoom synchronizes managed density before refreshing immutable ELK layers", () => {
    const routes = Object.freeze([
      Object.freeze({sourceId: "left", targetId: "right", points: Object.freeze([{x: 0, y: 0}, {x: 192, y: 0}])}),
    ])
    const scene = Object.freeze({routes})
    const graphNodes = Object.freeze([
      Object.freeze({id: "left", x: 0, y: 0}),
      Object.freeze({id: "right", x: 192, y: 0}),
    ])
    const graph = Object.freeze({_layoutMode: "elk-scene", _topologyScene: scene, nodes: graphNodes, edges: Object.freeze([])})
    const densitiesAtRefresh = []
    const managedVisualDensityForViewScale = vi.fn((_graph, scale) => ({
      managedVisualDensity: scale < 0.2 ? "overview" : "detail",
    }))
    const ctx = makeContext({
      state: {
        canvas: {getBoundingClientRect: () => ({left: 0, top: 0, width: 1000, height: 600})},
        lastGraph: graph,
        zoomMode: "auto",
        zoomTier: "local",
        managedTopologyVisualDensity: "detail",
        viewState: {zoom: Math.log2(0.25), minZoom: -5, maxZoom: 5, target: [96, 0, 0]},
      },
      deps: {
        managedVisualDensityForViewScale,
        refreshGraphLayersForViewState: vi.fn(() => {
          densitiesAtRefresh.push(ctx.state.managedTopologyVisualDensity)
        }),
      },
    })
    const originalGeometry = JSON.stringify(scene)

    ctx.zoomDeckCamera(Math.log2(0.15) - Math.log2(0.25))
    expect(ctx.state.managedTopologyVisualDensity).toBe("overview")
    ctx.zoomDeckCamera(Math.log2(0.25) - Math.log2(0.15))
    expect(ctx.state.managedTopologyVisualDensity).toBe("detail")

    expect(densitiesAtRefresh).toEqual(["overview", "detail"])
    expect(managedVisualDensityForViewScale.mock.calls[0][0]).toBe(graph)
    expect(managedVisualDensityForViewScale.mock.calls[0][1]).toBeCloseTo(0.15, 12)
    expect(managedVisualDensityForViewScale.mock.calls[1][0]).toBe(graph)
    expect(managedVisualDensityForViewScale.mock.calls[1][1]).toBeCloseTo(0.25, 12)
    expect(ctx.state.lastGraph).toBe(graph)
    expect(ctx.state.lastGraph.nodes).toBe(graphNodes)
    expect(ctx.state.lastGraph._topologyScene).toBe(scene)
    expect(ctx.state.lastGraph._topologyScene.routes).toBe(routes)
    expect(JSON.stringify(scene)).toBe(originalGeometry)
  })

  it("custom pan keeps an accepted ELK scene identity and only refreshes layers", () => {
    const scene = {id: "authoritative-scene"}
    const graph = {_layoutMode: "elk-scene", _topologyScene: scene, nodes: [], edges: []}
    const ctx = makeContext({
      state: {
        canvas: {style: {cursor: "grabbing"}},
        lastGraph: graph,
        zoomMode: "auto",
        zoomTier: "local",
        viewState: {zoom: -1, minZoom: -5, maxZoom: 5, target: [0, 0, 0]},
        dragState: {pointerId: 7, lastX: 100, lastY: 100},
      },
      deps: {resolveZoomTier: vi.fn(() => "regional")},
    })

    ctx.handlePanMove({pointerId: 7, clientX: 140, clientY: 120, preventDefault: vi.fn()})

    expect(ctx.state.viewState.target).not.toEqual([0, 0, 0])
    expect(ctx.state.zoomTier).toBe("local")
    expect(ctx.state.lastGraph).toBe(graph)
    expect(ctx.state.lastGraph._topologyScene).toBe(scene)
    expect(ctx.deps.resolveZoomTier).not.toHaveBeenCalled()
    expect(ctx.deps.setZoomTier).not.toHaveBeenCalled()
    expect(ctx.deps.renderGraph).not.toHaveBeenCalled()
    expect(ctx.deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
  })

  it("applyDeckViewState refreshes layers without layout in a fixed zoom tier", () => {
    const ctx = makeContext({state: {zoomMode: "regional"}})
    const nextViewState = {zoom: 0.5, minZoom: -2, maxZoom: 5, target: [120, 80, 0]}

    ctx.applyDeckViewState(nextViewState)

    expect(ctx.state.deck.setProps).toHaveBeenCalledWith({viewState: nextViewState})
    expect(ctx.deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
    expect(ctx.deps.setZoomTier).not.toHaveBeenCalled()
    expect(ctx.deps.renderGraph).not.toHaveBeenCalled()
  })

  it("handleMapControlClick triggers fit without collapsing expanded clusters", () => {
    const graph = {nodes: [{details: {cluster_expanded: true}}]}
    const ctx = makeContext({
      state: {
        deck: {setProps: vi.fn()},
        lastGraph: graph,
        userCameraLocked: true,
        hasAutoFit: true,
      },
      deps: {autoFitViewState: vi.fn(), setZoomTier: vi.fn(), resolveZoomTier: vi.fn(() => "local")},
      overrides: {collapseAllClusters: vi.fn()},
    })
    const event = {
      target: {
        closest: vi.fn(() => ({getAttribute: () => "fit"})),
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleMapControlClick(event)

    expect(ctx.collapseAllClusters).not.toHaveBeenCalled()
    expect(ctx.deps.autoFitViewState).toHaveBeenCalledWith(graph)
    expect(ctx.state.userCameraLocked).toEqual(false)
    expect(ctx.state.hasAutoFit).toEqual(false)
  })
})
