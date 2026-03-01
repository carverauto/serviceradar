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
    setZoomTier: vi.fn(),
    resolveZoomTier: vi.fn(() => "local"),
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
})
