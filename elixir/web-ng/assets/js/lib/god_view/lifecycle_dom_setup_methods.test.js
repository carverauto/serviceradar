import {describe, expect, it, vi} from "vitest"

vi.mock("@deck.gl/core", async (importOriginal) => ({
  ...(await importOriginal()),
  Deck: class MockDeck {
    constructor(props) {
      this.props = props
    }
  },
  OrthographicView: class MockOrthographicView {
    constructor(props) {
      this.props = props
    }
  },
}))

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLayoutClusterMethods} from "./layout_cluster_methods"
import {godViewLifecycleDomSetupMethods} from "./lifecycle_dom_setup_methods"
import {godViewRenderingGraphCoreMethods} from "./rendering_graph_core_methods"
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

describe("lifecycle_dom_setup_methods", () => {
  it("observeTopologyContainer watches the actual topology container", () => {
    const originalResizeObserver = globalThis.ResizeObserver
    const observe = vi.fn()
    const disconnect = vi.fn()
    const ResizeObserver = vi.fn(function ResizeObserver(callback) {
      this.callback = callback
      this.observe = observe
      this.disconnect = disconnect
    })
    globalThis.ResizeObserver = ResizeObserver
    const state = {el: {id: "topology-container"}, resizeObserver: null}
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    try {
      ctx.observeTopologyContainer()
      expect(ResizeObserver).toHaveBeenCalledTimes(1)
      expect(observe).toHaveBeenCalledWith(state.el)
      expect(state.resizeObserver).toBeInstanceOf(ResizeObserver)
    } finally {
      globalThis.ResizeObserver = originalResizeObserver
    }
  })

  it("observeTopologyContainer watches the production sibling safe-area controls", () => {
    const originalResizeObserver = globalThis.ResizeObserver
    const observe = vi.fn()
    const disconnect = vi.fn()
    const ResizeObserver = vi.fn(function ResizeObserver(callback) {
      this.callback = callback
      this.observe = observe
      this.disconnect = disconnect
    })
    globalThis.ResizeObserver = ResizeObserver
    const controls = {id: "god-view-controls"}
    const safeRoot = {querySelectorAll: vi.fn(() => [controls])}
    const el = {
      id: "god-view-binary-stream",
      closest: vi.fn(() => safeRoot),
    }
    const state = {el, resizeObserver: null}
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    try {
      ctx.observeTopologyContainer()
      expect(observe).toHaveBeenCalledWith(el)
      expect(observe).toHaveBeenCalledWith(controls)
      expect(observe).toHaveBeenCalledTimes(2)
    } finally {
      globalThis.ResizeObserver = originalResizeObserver
    }
  })

  it("observeTopologyContainer reconciles safe-area chrome inserted and removed after setup", () => {
    const originalResizeObserver = globalThis.ResizeObserver
    const originalMutationObserver = globalThis.MutationObserver
    const observeResize = vi.fn()
    const unobserveResize = vi.fn()
    const ResizeObserver = vi.fn(function ResizeObserver(callback) {
      this.callback = callback
      this.observe = observeResize
      this.unobserve = unobserveResize
      this.disconnect = vi.fn()
    })
    let mutationCallback = null
    const observeMutations = vi.fn()
    const MutationObserver = vi.fn(function MutationObserver(callback) {
      mutationCallback = callback
      this.observe = observeMutations
      this.disconnect = vi.fn()
    })
    globalThis.ResizeObserver = ResizeObserver
    globalThis.MutationObserver = MutationObserver

    const controls = {id: "god-view-controls"}
    const warning = {id: "god-view-backbone-empty-warning"}
    const safeElements = [controls]
    const safeRoot = {querySelectorAll: vi.fn(() => safeElements)}
    const el = {
      id: "god-view-binary-stream",
      closest: vi.fn(() => safeRoot),
    }
    const state = {el, resizeObserver: null}
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))
    ctx.resizeCanvas = vi.fn()

    try {
      ctx.observeTopologyContainer()

      expect(observeMutations).toHaveBeenCalledWith(safeRoot, {
        attributes: true,
        attributeFilter: ["data-god-view-safe-area", "class"],
        childList: true,
        subtree: true,
      })

      safeElements.push(warning)
      mutationCallback([])
      expect(observeResize).toHaveBeenCalledWith(warning)
      expect(ctx.resizeCanvas).toHaveBeenCalledTimes(1)

      safeElements.splice(safeElements.indexOf(controls), 1)
      mutationCallback([])
      expect(unobserveResize).toHaveBeenCalledWith(controls)
      expect(ctx.resizeCanvas).toHaveBeenCalledTimes(2)
    } finally {
      globalThis.ResizeObserver = originalResizeObserver
      globalThis.MutationObserver = originalMutationObserver
    }
  })

  it("ensureDOM marks the details panel as left-side safe-area chrome", () => {
    const originalDocument = globalThis.document
    const originalWindow = globalThis.window
    const makeElement = () => {
      const attributes = new Map()
      return {
        style: {},
        classList: {add: vi.fn()},
        addEventListener: vi.fn(),
        appendChild: vi.fn(),
        setAttribute: (name, value) => attributes.set(name, value),
        getAttribute: (name) => attributes.get(name),
      }
    }
    globalThis.document = {
      documentElement: {getAttribute: () => "light"},
      createElement: vi.fn(() => makeElement()),
    }
    globalThis.window = {
      addEventListener: vi.fn(),
      matchMedia: vi.fn(() => ({matches: false})),
    }
    const state = {
      el: makeElement(),
      canvas: null,
      summary: null,
      visual: {bg: [10, 17, 20, 255]},
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    try {
      ctx.ensureDOM()
      expect(state.details.getAttribute("data-god-view-safe-area")).toBe("left")
    } finally {
      globalThis.document = originalDocument
      globalThis.window = originalWindow
    }
  })

  it("ensureDOM installs browser text metrics for managed topology label fitting", () => {
    const originalDocument = globalThis.document
    const originalWindow = globalThis.window
    const measureText = vi.fn((text) => ({
      width: String(text).length * 6,
      actualBoundingBoxAscent: 8,
      actualBoundingBoxDescent: 2,
    }))
    const measurementContext = {font: "", measureText}
    let canvasCount = 0
    const makeElement = (tagName) => {
      const attributes = new Map()
      const element = {
        style: {},
        classList: {add: vi.fn()},
        addEventListener: vi.fn(),
        appendChild: vi.fn(),
        setAttribute: (name, value) => attributes.set(name, value),
        getAttribute: (name) => attributes.get(name),
      }
      if (tagName === "canvas") {
        canvasCount += 1
        element.getContext = vi.fn((kind) => (
          canvasCount > 1 && kind === "2d" ? measurementContext : null
        ))
      }
      return element
    }
    globalThis.document = {
      documentElement: {getAttribute: () => "light"},
      createElement: vi.fn((tagName) => makeElement(tagName)),
    }
    globalThis.window = {
      addEventListener: vi.fn(),
      matchMedia: vi.fn(() => ({matches: false})),
    }
    const state = {
      el: makeElement("div"),
      canvas: null,
      summary: null,
      visual: {bg: [10, 17, 20, 255]},
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    try {
      ctx.ensureDOM()
      expect(state.topologyLabelMeasureText).toBeTypeOf("function")
      expect(state.topologyLabelMeasureText("USWPro24 (192.168.1.131)", {fontSize: 10})).toMatchObject({
        width: 144,
        actualBoundingBoxAscent: 8,
        actualBoundingBoxDescent: 2,
      })
      expect(measurementContext.font).toBe("600 10px Inter, system-ui, sans-serif")
    } finally {
      globalThis.document = originalDocument
      globalThis.window = originalWindow
    }
  })

  it("same-profile container resize refits camera and labels without invalidating ELK", () => {
    const state = {
      el: {
        clientWidth: 960,
        clientHeight: 600,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 960, height: 600, right: 960, bottom: 600}),
        querySelectorAll: () => [],
      },
      canvas: {style: {}},
      deck: {setProps: vi.fn(), redraw: vi.fn()},
      lastGraph: {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene({profileKey: "landscape"})},
      viewportWidth: 900,
      viewportHeight: 600,
      viewportProfileKey: "landscape",
      lastLayoutKey: "accepted-landscape-layout",
      userCameraLocked: false,
    }
    const deps = {
      autoFitViewState: vi.fn(),
      refreshGraphLayersForViewState: vi.fn(),
      prepareGraphLayout: vi.fn(),
      renderGraph: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    ctx.resizeCanvas()

    expect(state.deck.setProps).toHaveBeenCalledWith({width: 960, height: 600})
    expect(deps.autoFitViewState).toHaveBeenCalledWith(state.lastGraph, {force: true})
    expect(deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
    expect(deps.prepareGraphLayout).not.toHaveBeenCalled()
    expect(state.lastLayoutKey).toBe("accepted-landscape-layout")
  })

  it("adopts the resized canvas into the Deck viewport before the frame is drawn", () => {
    // Mirrors @deck.gl/core 9.2: `width`/`height` are cached fields, and setProps re-sends the
    // CACHED pair to the view manager rather than the one it was handed. Only _updateCanvasSize
    // reads the new size back off the canvas, and Deck calls it from its own animation frame --
    // so every viewport handed out between a resize and the next frame, including the one
    // redraw() draws, still describes the previous size. Projecting a scene in that frame and
    // measuring it against the safe rect measured here compares two different viewports.
    const canvas = {style: {}}
    const deck = {
      width: 1920,
      height: 1080,
      viewportWidth: 1920,
      viewportHeight: 1080,
      setProps: vi.fn((props) => {
        if (props.width != null) canvas.style.width = `${props.width}px`
        if (props.height != null) canvas.style.height = `${props.height}px`
        deck.viewportWidth = deck.width
        deck.viewportHeight = deck.height
      }),
      _updateCanvasSize: vi.fn(() => {
        deck.width = Number(String(canvas.style.width).replace("px", ""))
        deck.height = Number(String(canvas.style.height).replace("px", ""))
        deck.viewportWidth = deck.width
        deck.viewportHeight = deck.height
      }),
      redraw: vi.fn(),
    }
    const state = {
      el: {
        clientWidth: 800,
        clientHeight: 1000,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 800, height: 1000, right: 800, bottom: 1000}),
      },
      canvas,
      deck,
      viewportWidth: 1920,
      viewportHeight: 1080,
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    ctx.resizeCanvas()

    expect(deck.setProps).toHaveBeenCalledWith({width: 800, height: 1000})
    expect(deck._updateCanvasSize).toHaveBeenCalledTimes(1)
    expect([deck.viewportWidth, deck.viewportHeight]).toEqual([800, 1000])
    expect(deck._updateCanvasSize.mock.invocationCallOrder[0])
      .toBeLessThan(deck.redraw.mock.invocationCallOrder[0])
  })

  it("falls back to the Deck view manager when the canvas-size refresh is unavailable", () => {
    const canvas = {style: {}}
    const viewManagerSetProps = vi.fn()
    const deck = {
      setProps: vi.fn(),
      redraw: vi.fn(),
      viewManager: {setProps: viewManagerSetProps},
    }
    const state = {
      el: {
        clientWidth: 800,
        clientHeight: 1000,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 800, height: 1000, right: 800, bottom: 1000}),
      },
      canvas,
      deck,
      viewportWidth: 1920,
      viewportHeight: 1080,
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    ctx.resizeCanvas()

    expect(viewManagerSetProps).toHaveBeenCalledWith({width: 800, height: 1000})
  })

  it("safe-chrome-only changes refit and refresh when the usable profile is unchanged", () => {
    const controls = {
      getAttribute: () => "right",
      getBoundingClientRect: () => ({left: 860, top: 12, right: 948, bottom: 240, width: 88, height: 228}),
    }
    const safeRoot = {querySelectorAll: () => [controls]}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene({profileKey: "landscape"})}
    const state = {
      el: {
        clientWidth: 960,
        clientHeight: 600,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 960, height: 600, right: 960, bottom: 600}),
        closest: () => safeRoot,
      },
      canvas: {style: {}},
      deck: {setProps: vi.fn(), redraw: vi.fn()},
      lastGraph: graph,
      viewportWidth: 960,
      viewportHeight: 600,
      viewportSafeInsets: {left: 0, top: 0, right: 0, bottom: 0},
      topologyLabelSafeRect: {left: 0, top: 0, right: 960, bottom: 600},
      viewportProfileKey: "landscape",
      userCameraLocked: false,
    }
    const deps = {
      autoFitViewState: vi.fn(),
      refreshGraphLayersForViewState: vi.fn(),
      prepareGraphLayout: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    ctx.resizeCanvas()

    expect(state.viewportSafeInsets).toEqual({left: 0, top: 0, right: 108, bottom: 0})
    expect(state.topologyLabelSafeRect).toEqual({left: 0, top: 0, right: 852, bottom: 600})
    expect(deps.autoFitViewState).toHaveBeenCalledWith(graph, {force: true})
    expect(deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
    expect(deps.prepareGraphLayout).not.toHaveBeenCalled()
  })

  it("contains an impossible unlocked safe-area refit and preserves the accepted camera", () => {
    const acceptedViewState = {zoom: 0, minZoom: -8, maxZoom: 5, target: [120, 80, 0]}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene({profileKey: "landscape"})}
    const state = {
      el: {
        clientWidth: 960,
        clientHeight: 600,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 960, height: 600, right: 960, bottom: 600}),
        querySelectorAll: () => [],
      },
      canvas: {style: {}},
      deck: {setProps: vi.fn(), redraw: vi.fn()},
      lastGraph: graph,
      viewportWidth: 900,
      viewportHeight: 600,
      viewportProfileKey: "landscape",
      userCameraLocked: false,
      hasAutoFit: true,
      isProgrammaticViewUpdate: false,
      managedTopologyVisualDensity: "detail",
      viewState: acceptedViewState,
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
    }
    const deps = {
      autoFitViewState: vi.fn(() => {
        state.viewState = {zoom: 5, target: [999, 999, 0]}
        state.managedTopologyVisualDensity = "overview"
        state.hasAutoFit = false
        state.isProgrammaticViewUpdate = true
        throw new RangeError("no feasible managed visual density")
      }),
      refreshGraphLayersForViewState: vi.fn(),
      prepareGraphLayout: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    expect(() => ctx.resizeCanvas()).not.toThrow()

    expect(state.viewState).toBe(acceptedViewState)
    expect(state.managedTopologyVisualDensity).toBe("detail")
    expect(state.hasAutoFit).toBe(true)
    expect(state.isProgrammaticViewUpdate).toBe(false)
    expect(state.summary.textContent).toBe("topology render unavailable")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "render_error",
      message: "RangeError: no feasible managed visual density",
    })
    expect(deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
  })

  it.each([
    ["unlocked", false],
    ["locked", true],
  ])("contains a failed %s managed resize refresh without rejecting its accepted camera", (_mode, userCameraLocked) => {
    const originalViewState = {zoom: 0, minZoom: -8, maxZoom: 5, target: [120, 80, 0]}
    const fittedViewState = {zoom: 1, minZoom: -8, maxZoom: 5, target: [140, 90, 0]}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene({profileKey: "landscape"})}
    const acceptedDeckLayers = ["accepted-layer"]
    const failedDeckLayers = ["failed-layer"]
    const deck = {
      props: {layers: acceptedDeckLayers},
      setProps: vi.fn(function setProps(nextProps) {
        Object.assign(this.props, nextProps)
      }),
      redraw: vi.fn(),
    }
    const state = {
      el: {
        clientWidth: 960,
        clientHeight: 600,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 960, height: 600, right: 960, bottom: 600}),
        querySelectorAll: () => [],
      },
      canvas: {style: {}},
      deck,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      lastGraph: graph,
      viewportWidth: 900,
      viewportHeight: 600,
      viewportProfileKey: "landscape",
      userCameraLocked,
      hasAutoFit: true,
      managedTopologyVisualDensity: "detail",
      viewState: originalViewState,
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
    }
    const deps = {
      autoFitViewState: vi.fn(() => {
        state.viewState = fittedViewState
        state.managedTopologyVisualDensity = "overview"
      }),
      managedViewStateForCamera: vi.fn(() => ({
        viewState: originalViewState,
        managedVisualDensity: "overview",
        constraints: null,
      })),
      refreshGraphLayersForViewState: vi.fn(() => {
        state.layers.atmosphere = false
        deck.setProps({layers: failedDeckLayers})
        throw new Error("resize layer refresh failed")
      }),
      prepareGraphLayout: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    expect(() => ctx.resizeCanvas()).not.toThrow()

    expect(state.viewState).toBe(userCameraLocked ? originalViewState : fittedViewState)
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(state.layers.atmosphere).toBe(true)
    expect(deck.props.layers).toBe(acceptedDeckLayers)
    expect(state.summary.textContent).toBe("topology render unavailable")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "render_error",
      message: "Error: resize layer refresh failed",
    })
    expect(deps.prepareGraphLayout).not.toHaveBeenCalled()
  })

  it.each([
    ["profile crossing", "landscape", null, 600, 900, true],
    ["pending profile", "portrait", "portrait", 620, 900, false],
  ])("contains a failed managed resize refresh during a %s", (
    _branch,
    viewportProfileKey,
    pendingViewportProfileKey,
    width,
    height,
    requestsLayout,
  ) => {
    const acceptedViewState = {zoom: 0, minZoom: -8, maxZoom: 5, target: [120, 80, 0]}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene({profileKey: viewportProfileKey})}
    const acceptedDeckLayers = ["accepted-layer"]
    const deck = {
      props: {layers: acceptedDeckLayers},
      setProps: vi.fn(function setProps(nextProps) {
        Object.assign(this.props, nextProps)
      }),
      redraw: vi.fn(),
    }
    const state = {
      el: {
        clientWidth: width,
        clientHeight: height,
        getBoundingClientRect: () => ({left: 0, top: 0, width, height, right: width, bottom: height}),
        querySelectorAll: () => [],
      },
      canvas: {style: {}},
      deck,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      lastGraph: graph,
      viewportWidth: width - 20,
      viewportHeight: height,
      viewportProfileKey,
      pendingViewportProfileKey,
      userCameraLocked: true,
      managedTopologyVisualDensity: "detail",
      viewState: acceptedViewState,
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
    }
    const deps = {
      refreshGraphLayersForViewState: vi.fn(() => {
        state.layers.atmosphere = false
        deck.setProps({layers: ["failed-layer"]})
        throw new Error("profile resize refresh failed")
      }),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods), {
      requestTopologyProfileLayout: vi.fn(),
    })

    expect(() => ctx.resizeCanvas()).not.toThrow()

    expect(ctx.requestTopologyProfileLayout).toHaveBeenCalledTimes(requestsLayout ? 1 : 0)
    expect(state.viewState).toBe(acceptedViewState)
    expect(state.layers.atmosphere).toBe(true)
    expect(deck.props.layers).toBe(acceptedDeckLayers)
    expect(state.summary.textContent).toBe("topology render unavailable")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "render_error",
      message: "Error: profile resize refresh failed",
    })
  })

  it.each([
    ["profile crossing", "landscape", null, 600, 900],
    ["pending profile", "portrait", "portrait", 620, 900],
  ])("does not clear a managed camera error by repainting an old scene during a %s", (
    _branch,
    viewportProfileKey,
    pendingViewportProfileKey,
    width,
    height,
  ) => {
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene({profileKey: viewportProfileKey})}
    const state = {
      el: {
        clientWidth: width,
        clientHeight: height,
        getBoundingClientRect: () => ({left: 0, top: 0, width, height, right: width, bottom: height}),
        querySelectorAll: () => [],
      },
      canvas: {style: {}},
      deck: {setProps: vi.fn(), redraw: vi.fn()},
      lastGraph: graph,
      viewportWidth: width - 20,
      viewportHeight: height,
      viewportProfileKey,
      pendingViewportProfileKey,
      userCameraLocked: true,
      viewState: {zoom: 0, minZoom: -8, maxZoom: 5, target: [120, 80, 0]},
      summary: {textContent: "topology render unavailable"},
      managedTopologyCameraErrorActive: true,
      managedTopologyCameraErrorPreviousSummary: "accepted topology",
    }
    const deps = {refreshGraphLayersForViewState: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods), {
      requestTopologyProfileLayout: vi.fn(),
    })

    ctx.resizeCanvas()

    expect(deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
    expect(state.summary.textContent).toBe("topology render unavailable")
    expect(state.managedTopologyCameraErrorActive).toBe(true)
    expect(state.managedTopologyCameraErrorPreviousSummary).toBe("accepted topology")
  })

  it("clears a locked safe-area error after semantic camera selection succeeds", () => {
    let width = 980
    const acceptedViewState = {zoom: 0, minZoom: -8, maxZoom: 5, target: [20, 30, 0]}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene({profileKey: "landscape"})}
    const state = {
      el: {
        get clientWidth() { return width },
        clientHeight: 600,
        getBoundingClientRect: () => ({left: 0, top: 0, width, height: 600, right: width, bottom: 600}),
        querySelectorAll: () => [],
      },
      canvas: {style: {}},
      deck: {setProps: vi.fn(), redraw: vi.fn()},
      lastGraph: graph,
      viewportWidth: 900,
      viewportHeight: 600,
      viewportProfileKey: "landscape",
      userCameraLocked: true,
      managedTopologyVisualDensity: "detail",
      viewState: acceptedViewState,
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
    }
    const deps = {
      managedViewStateForCamera: vi.fn()
        .mockImplementationOnce(() => {
          state.summary.textContent = "transient failed selection"
          throw new RangeError("safe rectangle is too small")
        })
        .mockReturnValueOnce({
          viewState: acceptedViewState,
          managedVisualDensity: "overview",
          constraints: null,
        }),
      refreshGraphLayersForViewState: vi.fn(),
      prepareGraphLayout: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    expect(() => ctx.resizeCanvas()).not.toThrow()
    expect(state.viewState).toBe(acceptedViewState)
    expect(state.managedTopologyVisualDensity).toBe("detail")
    expect(state.summary.textContent).toBe("topology render unavailable")
    expect(state.pushEvent).toHaveBeenCalledTimes(1)

    width = 990
    expect(() => ctx.resizeCanvas()).not.toThrow()
    expect(state.viewState).toBe(acceptedViewState)
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(state.summary.textContent).toBe("accepted topology")
    expect(state.pushEvent).toHaveBeenCalledTimes(1)
  })

  it("safe-chrome-only profile crossings request a fresh ELK layout", async () => {
    const controls = {
      getAttribute: () => "right",
      getBoundingClientRect: () => ({left: 668, top: 12, right: 948, bottom: 360, width: 280, height: 348}),
    }
    const safeRoot = {querySelectorAll: () => [controls]}
    const previousGraph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene({profileKey: "landscape"}), nodes: [], edges: []}
    const portraitGraph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "accepted-portrait-layout",
      _topologyScene: topologyScene({profileKey: "portrait"}),
      nodes: [],
      edges: [],
    }
    const state = {
      el: {
        clientWidth: 960,
        clientHeight: 600,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 960, height: 600, right: 960, bottom: 600}),
        closest: () => safeRoot,
      },
      canvas: {style: {}},
      deck: {setProps: vi.fn(), redraw: vi.fn()},
      lastGraph: previousGraph,
      lastRevision: 8,
      lastTopologyStamp: "same-graph",
      viewportWidth: 960,
      viewportHeight: 600,
      viewportSafeInsets: {left: 0, top: 0, right: 0, bottom: 0},
      topologyLabelSafeRect: {left: 0, top: 0, right: 960, bottom: 600},
      viewportProfileKey: "landscape",
      lastLayoutKey: "accepted-landscape-layout",
      userCameraLocked: false,
      layoutRequestToken: 0,
    }
    const deps = {
      autoFitViewState: vi.fn(),
      refreshGraphLayersForViewState: vi.fn(),
      prepareGraphLayout: vi.fn(async () => portraitGraph),
      renderGraph: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    ctx.resizeCanvas()
    await Promise.resolve()
    await Promise.resolve()

    expect(deps.prepareGraphLayout).toHaveBeenCalledWith(previousGraph, 8, "same-graph", {commit: false})
    expect(state.viewportProfileKey).toBe("portrait")
    expect(state.lastGraph).toBe(portraitGraph)
    expect(deps.renderGraph).toHaveBeenCalledWith(portraitGraph)
    expect(deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
  })

  it("crossing usable aspect 1.2 invalidates and requests one fresh profile layout", async () => {
    const previousGraph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene({profileKey: "landscape"}), nodes: [], edges: []}
    const portraitGraph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "accepted-portrait-layout",
      _topologyScene: topologyScene({profileKey: "portrait"}),
      nodes: [],
      edges: [],
    }
    const state = {
      el: {
        clientWidth: 660,
        clientHeight: 600,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 660, height: 600, right: 660, bottom: 600}),
        querySelectorAll: () => [],
      },
      canvas: {style: {}},
      deck: {setProps: vi.fn(), redraw: vi.fn()},
      lastGraph: previousGraph,
      lastRevision: 8,
      lastTopologyStamp: "same-graph",
      viewportWidth: 960,
      viewportHeight: 600,
      viewportProfileKey: "landscape",
      lastLayoutKey: "accepted-landscape-layout",
      userCameraLocked: false,
      layoutRequestToken: 0,
    }
    const deps = {
      autoFitViewState: vi.fn(),
      refreshGraphLayersForViewState: vi.fn(),
      prepareGraphLayout: vi.fn(async () => portraitGraph),
      renderGraph: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    ctx.resizeCanvas()
    ctx.resizeCanvas()
    await Promise.resolve()
    await Promise.resolve()

    expect(state.viewportProfileKey).toBe("portrait")
    expect(state.lastLayoutKey).toBe("accepted-portrait-layout")
    expect(deps.prepareGraphLayout).toHaveBeenCalledTimes(1)
    expect(deps.prepareGraphLayout).toHaveBeenCalledWith(previousGraph, 8, "same-graph", {commit: false})
    expect(state.lastGraph).toBe(portraitGraph)
    expect(deps.renderGraph).toHaveBeenCalledWith(portraitGraph)
  })

  it("preserves the accepted scene when a profile resize returns an ELK error sentinel", async () => {
    const previousGraph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "accepted-landscape-layout",
      _topologyScene: topologyScene({profileKey: "landscape"}),
      nodes: [{id: "positioned", x: 10, y: 20}],
      edges: [],
    }
    const failedGraph = {
      _layoutMode: "elk-scene-detail-error",
      _layoutCacheKey: "failed-portrait-layout",
      _layoutError: "portrait ELK failure",
      nodes: [{id: "unpositioned"}],
      edges: [],
    }
    const recoveredGraph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "accepted-portrait-layout",
      _topologyScene: topologyScene({profileKey: "portrait"}),
      nodes: [{id: "recovered", x: 50, y: 60}],
      edges: [],
    }
    const state = {
      lastGraph: previousGraph,
      lastRevision: 8,
      lastTopologyStamp: "same-graph",
      layoutMode: "elk-scene-detail",
      layoutRevision: 8,
      lastLayoutKey: "accepted-landscape-layout",
      viewportProfileKey: "landscape",
      pendingViewportProfileKey: "portrait",
      layoutRequestToken: 0,
      pendingSnapshotLayoutToken: null,
      userCameraLocked: false,
      hasAutoFit: true,
      pushEvent: vi.fn(),
      summary: {textContent: "accepted scene"},
    }
    const deps = {
      prepareGraphLayout: vi.fn()
        .mockResolvedValueOnce(failedGraph)
        .mockResolvedValueOnce(recoveredGraph),
      renderGraph: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    expect(await ctx.requestTopologyProfileLayout(previousGraph, "portrait")).toBe(false)

    expect(state.lastGraph).toBe(previousGraph)
    expect(state.lastRevision).toBe(8)
    expect(state.lastTopologyStamp).toBe("same-graph")
    expect(state.layoutMode).toBe("elk-scene-detail")
    expect(state.layoutRevision).toBe(8)
    expect(state.lastLayoutKey).toBe("accepted-landscape-layout")
    expect(state.viewportProfileKey).toBe("landscape")
    expect(state.pendingViewportProfileKey).toBe(null)
    expect(state.hasAutoFit).toBe(true)
    expect(state.summary.textContent).toBe("topology layout unavailable")
    expect(state.managedTopologyCameraErrorActive).toBe(true)
    expect(state.managedTopologyCameraErrorPreviousSummary).toBe("accepted scene")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "layout_error",
      message: "portrait ELK failure",
    })
    expect(deps.renderGraph).not.toHaveBeenCalled()

    state.pendingViewportProfileKey = "portrait"
    expect(await ctx.requestTopologyProfileLayout(previousGraph, "portrait")).toBe(true)

    expect(state.lastGraph).toBe(recoveredGraph)
    expect(state.summary.textContent).toBe("accepted scene")
    expect(state.managedTopologyCameraErrorActive).toBe(false)
    expect(state.managedTopologyCameraErrorPreviousSummary).toBeNull()
    expect(deps.renderGraph).toHaveBeenCalledWith(recoveredGraph)
  })

  it("clears a rejected profile-layout diagnostic after an accepted retry", async () => {
    const previousGraph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "accepted-landscape-layout",
      _topologyScene: topologyScene({profileKey: "landscape"}),
      nodes: [],
      edges: [],
    }
    const recoveredGraph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "accepted-portrait-layout",
      _topologyScene: topologyScene({profileKey: "portrait"}),
      nodes: [],
      edges: [],
    }
    const state = {
      lastGraph: previousGraph,
      lastRevision: 8,
      lastTopologyStamp: "same-graph",
      layoutMode: "elk-scene-detail",
      layoutRevision: 8,
      lastLayoutKey: "accepted-landscape-layout",
      viewportProfileKey: "landscape",
      pendingViewportProfileKey: "portrait",
      layoutRequestToken: 0,
      pendingSnapshotLayoutToken: null,
      userCameraLocked: false,
      hasAutoFit: true,
      pushEvent: vi.fn(),
      summary: {textContent: "accepted scene"},
    }
    const deps = {
      prepareGraphLayout: vi.fn()
        .mockRejectedValueOnce(new Error("ELK worker crashed"))
        .mockResolvedValueOnce(recoveredGraph),
      renderGraph: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    expect(await ctx.requestTopologyProfileLayout(previousGraph, "portrait")).toBe(false)

    expect(state.lastGraph).toBe(previousGraph)
    expect(state.summary.textContent).toBe("layout resize failed: Error: ELK worker crashed")
    expect(state.managedTopologyCameraErrorActive).toBe(true)
    expect(state.managedTopologyCameraErrorPreviousSummary).toBe("accepted scene")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "layout_error",
      message: "Error: ELK worker crashed",
    })

    state.pendingViewportProfileKey = "portrait"
    expect(await ctx.requestTopologyProfileLayout(previousGraph, "portrait")).toBe(true)

    expect(state.lastGraph).toBe(recoveredGraph)
    expect(state.summary.textContent).toBe("accepted scene")
    expect(state.managedTopologyCameraErrorActive).toBe(false)
    expect(state.managedTopologyCameraErrorPreviousSummary).toBeNull()
    expect(deps.renderGraph).toHaveBeenCalledWith(recoveredGraph)
  })

  it("rolls back a profile layout whose render throws and accepts a later retry", async () => {
    const previousGraph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "accepted-landscape-layout",
      _topologyScene: topologyScene({profileKey: "landscape"}),
      nodes: [{id: "positioned", x: 10, y: 20}],
      edges: [],
    }
    const failedGraph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "failed-portrait-layout",
      _topologyScene: topologyScene({profileKey: "portrait"}),
      nodes: [{id: "failed", x: 30, y: 40}],
      edges: [],
    }
    const recoveredGraph = {
      _layoutMode: "elk-scene-detail",
      _layoutCacheKey: "accepted-portrait-layout",
      _topologyScene: topologyScene({profileKey: "portrait"}),
      nodes: [{id: "recovered", x: 50, y: 60}],
      edges: [],
    }
    const previousViewState = {target: [10, 20, 0], zoom: 1, minZoom: -2, maxZoom: 5}
    const previousLayerFrame = {effective: previousGraph}
    const previousConstraintsCache = {graph: previousGraph, scene: previousGraph._topologyScene}
    const previousConstraintsLayoutCache = new Map([["accepted-layout", previousConstraintsCache]])
    const previousRouteDiagnostics = [{routeId: "accepted"}]
    const previousLabelFallbackIds = ["accepted-label"]
    const previousVisibilityMask = Uint8Array.from([1, 0])
    const previousTraversalMask = Uint8Array.from([1, 1])
    const previousPacketFlowCache = [{edgeIndex: 0}]
    const state = {
      lastGraph: previousGraph,
      lastRevision: 8,
      lastTopologyStamp: "same-graph",
      layoutMode: "elk-scene-detail",
      layoutRevision: 8,
      lastLayoutKey: "accepted-landscape-layout",
      viewportProfileKey: "landscape",
      pendingViewportProfileKey: "portrait",
      layoutRequestToken: 0,
      pendingSnapshotLayoutToken: null,
      userCameraLocked: false,
      hasAutoFit: true,
      isProgrammaticViewUpdate: false,
      viewState: previousViewState,
      zoomTier: "local",
      managedTopologySceneForMinZoom: previousGraph._topologyScene,
      managedTopologySceneMinZoom: -1.5,
      managedTopologySceneMinZoomKey: "layout:accepted-landscape-layout",
      managedTopologyVisualDensity: "overview",
      managedTopologyDensityConstraintsCache: previousConstraintsCache,
      managedTopologyDensityConstraintsLayoutCache: previousConstraintsLayoutCache,
      lastGraphLayerFrame: previousLayerFrame,
      lastVisibleNodeCount: 1,
      lastVisibleEdgeCount: 0,
      hoveredEdgeKey: "accepted:hovered",
      selectedEdgeKey: "accepted:selected",
      topologyRouteDiagnostics: previousRouteDiagnostics,
      topologyLabelDetailsFallbackIds: previousLabelFallbackIds,
      lastDetailsHtml: "accepted details",
      visibilityMaskBuffer: previousVisibilityMask,
      traversalMaskBuffer: previousTraversalMask,
      wasmReady: true,
      packetFlowCache: previousPacketFlowCache,
      packetFlowCacheStamp: "accepted-flow",
      layers: {atmosphere: true},
      pushEvent: vi.fn(),
      summary: {textContent: "accepted scene"},
    }
    let onscreenGraph = previousGraph
    const deps = {
      prepareGraphLayout: vi.fn()
        .mockResolvedValueOnce(failedGraph)
        .mockResolvedValueOnce(recoveredGraph),
      renderGraph: vi.fn((graph) => {
        onscreenGraph = graph
        if (graph !== failedGraph) return
        state.hasAutoFit = true
        state.isProgrammaticViewUpdate = true
        state.viewState = {target: [30, 40, 0], zoom: 3, minZoom: 2, maxZoom: 5}
        state.managedTopologyDensityConstraintsCache = {graph: failedGraph}
        state.managedTopologyDensityConstraintsLayoutCache = new Map([["failed-layout", {graph: failedGraph}]])
        state.managedTopologySceneForMinZoom = failedGraph._topologyScene
        state.managedTopologySceneMinZoom = 2
        state.managedTopologySceneMinZoomKey = "layout:failed-portrait-layout"
        state.managedTopologyVisualDensity = "detail"
        state.zoomTier = "regional"
        state.lastGraphLayerFrame = {effective: failedGraph}
        state.lastVisibleNodeCount = 9
        state.lastVisibleEdgeCount = 7
        state.hoveredEdgeKey = null
        state.selectedEdgeKey = null
        state.topologyRouteDiagnostics = [{routeId: "failed"}]
        state.topologyLabelDetailsFallbackIds = ["failed-label"]
        state.lastDetailsHtml = "failed details"
        state.visibilityMaskBuffer.fill(0)
        state.traversalMaskBuffer.fill(0)
        state.wasmReady = false
        state.packetFlowCache = [{edgeIndex: 9}]
        state.packetFlowCacheStamp = "failed-flow"
        state.layers.atmosphere = false
        throw new RangeError("portrait camera infeasible")
      }),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    expect(await ctx.requestTopologyProfileLayout(previousGraph, "portrait")).toBe(false)

    expect(onscreenGraph).toBe(previousGraph)
    expect(state.lastGraph).toBe(previousGraph)
    expect(state.layoutMode).toBe("elk-scene-detail")
    expect(state.layoutRevision).toBe(8)
    expect(state.lastLayoutKey).toBe("accepted-landscape-layout")
    expect(state.viewportProfileKey).toBe("landscape")
    expect(state.pendingViewportProfileKey).toBe(null)
    expect(state.hasAutoFit).toBe(true)
    expect(state.isProgrammaticViewUpdate).toBe(false)
    expect(state.viewState).toBe(previousViewState)
    expect(state.managedTopologyDensityConstraintsCache).toBe(previousConstraintsCache)
    expect(state.managedTopologyDensityConstraintsLayoutCache).toBe(previousConstraintsLayoutCache)
    expect(state.managedTopologySceneForMinZoom).toBe(previousGraph._topologyScene)
    expect(state.managedTopologySceneMinZoom).toBe(-1.5)
    expect(state.managedTopologySceneMinZoomKey).toBe("layout:accepted-landscape-layout")
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(state.zoomTier).toBe("local")
    expect(state.lastGraphLayerFrame).toBe(previousLayerFrame)
    expect(state.lastVisibleNodeCount).toBe(1)
    expect(state.lastVisibleEdgeCount).toBe(0)
    expect(state.hoveredEdgeKey).toBe("accepted:hovered")
    expect(state.selectedEdgeKey).toBe("accepted:selected")
    expect(state.topologyRouteDiagnostics).toBe(previousRouteDiagnostics)
    expect(state.topologyLabelDetailsFallbackIds).toBe(previousLabelFallbackIds)
    expect(state.lastDetailsHtml).toBe("accepted details")
    expect(state.visibilityMaskBuffer).toBe(previousVisibilityMask)
    expect(Array.from(state.visibilityMaskBuffer)).toEqual([1, 0])
    expect(state.traversalMaskBuffer).toBe(previousTraversalMask)
    expect(Array.from(state.traversalMaskBuffer)).toEqual([1, 1])
    expect(state.wasmReady).toBe(true)
    expect(state.packetFlowCache).toBe(previousPacketFlowCache)
    expect(state.packetFlowCacheStamp).toBe("accepted-flow")
    expect(state.layers.atmosphere).toBe(true)
    expect(state.summary.textContent).toBe("topology render unavailable")
    expect(state.managedTopologyCameraErrorActive).toBe(true)
    expect(state.managedTopologyCameraErrorPreviousSummary).toBe("accepted scene")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "render_error",
      message: "RangeError: portrait camera infeasible",
    })

    state.pendingViewportProfileKey = "portrait"
    expect(await ctx.requestTopologyProfileLayout(previousGraph, "portrait")).toBe(true)

    expect(onscreenGraph).toBe(recoveredGraph)
    expect(state.lastGraph).toBe(recoveredGraph)
    expect(state.layoutRevision).toBe(8)
    expect(state.lastLayoutKey).toBe("accepted-portrait-layout")
    expect(state.viewportProfileKey).toBe("portrait")
    expect(state.pendingViewportProfileKey).toBe(null)
    expect(state.summary.textContent).toBe("accepted scene")
    expect(state.managedTopologyCameraErrorActive).toBe(false)
    expect(state.managedTopologyCameraErrorPreviousSummary).toBeNull()
  })

  it("user-locked same-profile resize preserves the live low-scale camera through semantic density selection", () => {
    const liveContainmentScale = 0.019548
    const graph = {
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
      _topologyScene: topologyScene({profileKey: "landscape"}),
    }
    const acceptedViewState = {
      zoom: Math.log2(liveContainmentScale),
      minZoom: -12,
      maxZoom: 5,
      target: [20, 30, 0],
    }
    const state = {
      el: {
        clientWidth: 980,
        clientHeight: 600,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 980, height: 600, right: 980, bottom: 600}),
        querySelectorAll: () => [],
      },
      canvas: {style: {}},
      deck: {setProps: vi.fn(), redraw: vi.fn()},
      lastGraph: graph,
      viewportWidth: 900,
      viewportHeight: 600,
      viewportProfileKey: "landscape",
      userCameraLocked: true,
      viewState: acceptedViewState,
      managedTopologyVisualDensity: "detail",
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
    }
    const deps = {
      autoFitViewState: vi.fn(),
      managedVisualDensityForViewScale: vi.fn(() => {
        throw new RangeError(
          "no feasible managed visual density at scale=0.019548; overview requires scale=0.089285",
        )
      }),
      managedViewStateForCamera: vi.fn(() => ({
        viewState: acceptedViewState,
        managedVisualDensity: "detail",
        constraints: null,
      })),
      refreshGraphLayersForViewState: vi.fn(),
      prepareGraphLayout: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    ctx.resizeCanvas()

    expect(state.deck.setProps).toHaveBeenCalledWith({width: 980, height: 600})
    expect(deps.autoFitViewState).not.toHaveBeenCalled()
    expect(deps.managedVisualDensityForViewScale).not.toHaveBeenCalled()
    // The resize forwards the live density: without it managedViewStateForCamera falls back to
    // the semantic default and re-widens glyphs the fit had stepped down.
    expect(deps.managedViewStateForCamera).toHaveBeenCalledWith(
      graph,
      acceptedViewState,
      {
        safeRect: {left: 0, top: 0, right: 980, bottom: 600},
        fittedManagedVisualDensity: "detail",
      },
    )
    expect(state.managedTopologyVisualDensity).toBe("detail")
    expect(state.viewState).toBe(acceptedViewState)
    expect(2 ** state.viewState.zoom).toBeCloseTo(liveContainmentScale, 12)
    expect(state.summary.textContent).toBe("accepted topology")
    expect(state.pushEvent).not.toHaveBeenCalled()
    expect(deps.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
    expect(deps.prepareGraphLayout).not.toHaveBeenCalled()
  })

  it("createDeckInstance routes tooltip/hover/click through deps bridge", () => {
    const originalRaf = globalThis.requestAnimationFrame
    const raf = vi.fn((cb) => cb())
    globalThis.requestAnimationFrame = raf

    const state = {
      canvas: {},
      deck: {redraw: vi.fn()},
      visual: {bg: [10, 10, 10, 255]},
      viewState: {zoom: 1},
      isProgrammaticViewUpdate: false,
      zoomMode: "local",
    }
    const deps = {
      getNodeTooltip: vi.fn(() => ({text: "tooltip"})),
      handleHover: vi.fn(),
      handlePick: vi.fn(),
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
      refreshGraphLayersForViewState: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    try {
      const instance = ctx.createDeckInstance(800, 600)

      const tooltipResult = instance.props.getTooltip({object: {id: "n1"}, layer: {id: "god-view-nodes"}})
      instance.props.onHover({object: {id: "n1"}, layer: {id: "god-view-nodes"}})
      instance.props.onClick({object: {id: "n1"}, layer: {id: "god-view-nodes"}})

      expect(tooltipResult).toEqual({text: "tooltip"})
      expect(instance.props.pickingRadius).toEqual(8)
      expect(deps.getNodeTooltip).toHaveBeenCalledTimes(1)
      expect(deps.handleHover).toHaveBeenCalledTimes(1)
      expect(deps.handlePick).toHaveBeenCalledTimes(1)
      expect(raf).toHaveBeenCalledTimes(1)
      expect(state.deck.redraw).toHaveBeenCalledWith(true)
    } finally {
      globalThis.requestAnimationFrame = originalRaf
    }
  })

  it("createDeckInstance keeps client-radial overview in local tier after the user moves the camera", () => {
    const state = {
      canvas: {},
      deck: null,
      visual: {bg: [10, 10, 10, 255]},
      viewState: {zoom: 1.4},
      isProgrammaticViewUpdate: true,
      userCameraLocked: false,
      zoomMode: "auto",
      lastGraph: {_layoutMode: "client-radial"},
    }
    const deps = {
      getNodeTooltip: vi.fn(),
      handleHover: vi.fn(),
      handlePick: vi.fn(),
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "regional"),
      refreshGraphLayersForViewState: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    const instance = ctx.createDeckInstance(800, 600)
    instance.props.onViewStateChange({viewState: {zoom: -0.4, target: [0, 0, 0]}})
    expect(deps.setZoomTier).toHaveBeenCalledWith("local", false)
    expect(state.userCameraLocked).toBe(false)

    deps.setZoomTier.mockClear()
    state.isProgrammaticViewUpdate = false
    instance.props.onViewStateChange({viewState: {zoom: -0.4, target: [0, 0, 0]}})
    expect(deps.setZoomTier).toHaveBeenCalledWith("local", false)
    expect(deps.resolveZoomTier).not.toHaveBeenCalled()
    expect(state.userCameraLocked).toBe(true)
  })

  it("contains an infeasible managed Deck camera update and preserves accepted state", () => {
    const acceptedViewState = {zoom: 0, minZoom: -8, maxZoom: 5, target: [20, 30, 0]}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene(), nodes: []}
    const state = {
      canvas: {},
      visual: {bg: [10, 10, 10, 255]},
      layers: {atmosphere: false},
      deck: {setProps: vi.fn()},
      lastGraph: graph,
      viewState: acceptedViewState,
      managedTopologyVisualDensity: "detail",
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "local",
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
    }
    const deps = {
      getNodeTooltip: vi.fn(),
      handleHover: vi.fn(),
      handlePick: vi.fn(),
      managedViewStateForCamera: vi.fn(() => {
        throw new RangeError("no feasible managed visual density")
      }),
      refreshGraphLayersForViewState: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))
    const instance = ctx.createDeckInstance(800, 600)

    let callbackResult = null
    expect(() => {
      callbackResult = instance.props.onViewStateChange({
        viewState: {...acceptedViewState, zoom: 2},
      })
    }).not.toThrow()

    expect(state.viewState).toBe(acceptedViewState)
    expect(callbackResult).toBe(acceptedViewState)
    expect(state.managedTopologyVisualDensity).toBe("detail")
    expect(state.userCameraLocked).toBe(false)
    expect(state.summary.textContent).toBe("topology render unavailable")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "render_error",
      message: "RangeError: no feasible managed visual density",
    })
  })

  it("returns the accepted managed camera so Deck does not adopt the raw uncontrolled input", () => {
    const acceptedViewState = {zoom: 0, minZoom: -8, maxZoom: 5, target: [20, 30, 0]}
    const rawViewState = {...acceptedViewState, zoom: -10}
    const clampedViewState = {...rawViewState, zoom: -2}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene(), nodes: []}
    const state = {
      canvas: {},
      visual: {bg: [10, 10, 10, 255]},
      deck: {setProps: vi.fn()},
      lastGraph: graph,
      viewState: acceptedViewState,
      managedTopologyVisualDensity: "detail",
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "local",
    }
    const deps = {
      getNodeTooltip: vi.fn(),
      handleHover: vi.fn(),
      handlePick: vi.fn(),
      managedViewStateForCamera: vi.fn(() => ({
        viewState: clampedViewState,
        managedVisualDensity: "overview",
      })),
      refreshGraphLayersForViewState: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))
    const instance = ctx.createDeckInstance(800, 600)

    const callbackResult = instance.props.onViewStateChange({viewState: rawViewState})
    const deckAdoptedViewState = callbackResult || rawViewState

    expect(state.viewState).toBe(clampedViewState)
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(deckAdoptedViewState).toBe(clampedViewState)
  })

  it("contains a deferred managed layer-refresh failure without rejecting the accepted camera", () => {
    const originalQueueMicrotask = globalThis.queueMicrotask
    let queuedRefresh = null
    globalThis.queueMicrotask = (callback) => {
      queuedRefresh = callback
    }
    const acceptedViewState = {zoom: 0, minZoom: -8, maxZoom: 5, target: [20, 30, 0]}
    const nextViewState = {...acceptedViewState, zoom: 1}
    const graph = {_layoutMode: "elk-scene-detail", _topologyScene: topologyScene(), nodes: []}
    const state = {
      canvas: {},
      visual: {bg: [10, 10, 10, 255]},
      deck: {setProps: vi.fn()},
      lastGraph: graph,
      viewState: acceptedViewState,
      managedTopologyVisualDensity: "detail",
      userCameraLocked: false,
      isProgrammaticViewUpdate: false,
      zoomMode: "local",
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
    }
    const deps = {
      getNodeTooltip: vi.fn(),
      handleHover: vi.fn(),
      handlePick: vi.fn(),
      managedViewStateForCamera: vi.fn(() => ({
        viewState: nextViewState,
        managedVisualDensity: "detail",
      })),
      refreshGraphLayersForViewState: vi.fn(() => {
        throw new Error("projection failed")
      }),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    try {
      const instance = ctx.createDeckInstance(800, 600)
      expect(instance.props.onViewStateChange({viewState: nextViewState})).toBe(nextViewState)
      expect(typeof queuedRefresh).toBe("function")

      expect(() => queuedRefresh()).not.toThrow()

      expect(state.viewState).toBe(nextViewState)
      expect(state.managedTopologyVisualDensity).toBe("detail")
      expect(state.summary.textContent).toBe("topology render unavailable")
      expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
        reason: "render_error",
        message: "Error: projection failed",
      })
    } finally {
      globalThis.queueMicrotask = originalQueueMicrotask
    }
  })

  it("recomputes label admission for same-tier pan and zoom without reshaping or laying out", async () => {
    const scene = topologyScene()
    const effective = {shape: "local", _layoutMode: "elk-scene-detail", _topologyScene: scene}
    const nodeData = [{
      index: 0,
      id: "router",
      label: "Router",
      position: [100, 100, 0],
      state: 2,
      operUp: 1,
      clusterCount: 1,
      details: {},
    }]
    const state = {
      canvas: {},
      deck: null,
      visual: {bg: [10, 10, 10, 255], label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
      layers: {mantle: true, crust: true, atmosphere: false, security: true},
      animationPhase: 0,
      hoveredNodeIndex: null,
      viewState: {zoom: 0, target: [100, 100, 0]},
      isProgrammaticViewUpdate: false,
      userCameraLocked: false,
      zoomMode: "auto",
      zoomTier: "regional",
      lastGraph: {_layoutMode: "elk-scene-detail"},
      packetFlowEnabled: false,
      topologyLabelSafeRect: {left: 0, top: 0, right: 220, bottom: 220},
      topologyLabelMeasureText: () => ({width: 40, height: 12}),
    }
    const tierRenderGraph = vi.fn()
    const layoutContext = createStateBackedContext(state, {renderGraph: tierRenderGraph})
    Object.assign(layoutContext, bindApi(layoutContext, godViewLayoutClusterMethods))

    const reshapeGraph = vi.fn(() => effective)
    const renderingContext = createStateBackedContext(state, {ensureDeck: vi.fn(), reshapeGraph})
    Object.assign(
      renderingContext,
      bindApi(renderingContext, godViewRenderingGraphCoreMethods),
      bindApi(renderingContext, godViewRenderingGraphLayerNodeMethods),
      {
        autoFitViewState: vi.fn(),
        buildVisibleGraphData: vi.fn(() => ({
          nodeData,
          edgeData: [],
          edgeLabelData: [],
          rootPulseNodes: [],
          selectedVisibleNode: null,
        })),
        renderSelectionDetails: vi.fn(),
        buildGraphLayers: (nextEffective, nextNodeData, _edgeData, edgeLabelData) =>
          renderingContext.buildNodeAndLabelLayers(nextEffective, nextNodeData, edgeLabelData),
        nodeColor: () => [255, 0, 0, 255],
        nodeNeutralColor: () => [128, 128, 128, 255],
      },
    )
    const refreshGraphLayersForViewState = vi.fn(() => renderingContext.refreshGraphLayersForViewState())
    const deps = {
      getNodeTooltip: vi.fn(),
      handleHover: vi.fn(),
      handlePick: vi.fn(),
      setZoomTier: layoutContext.setZoomTier,
      resolveZoomTier: layoutContext.resolveZoomTier,
      managedVisualDensityForViewScale: vi.fn(() => ({managedVisualDensity: "detail"})),
      refreshGraphLayersForViewState,
    }
    const lifecycleContext = createStateBackedContext(state, deps)
    Object.assign(lifecycleContext, bindApi(lifecycleContext, godViewLifecycleDomSetupMethods))
    const deckInstance = lifecycleContext.createDeckInstance(220, 220)
    const layerSets = []
    let deckViewState = {...state.viewState}
    state.deck = {
      getViewports: () => [{
        width: 220,
        height: 220,
        project: ([x, y]) => {
          const scale = 2 ** deckViewState.zoom
          return [110 + ((x - deckViewState.target[0]) * scale), 110 + ((y - deckViewState.target[1]) * scale)]
        },
      }],
      setProps: vi.fn(({layers}) => layerSets.push(layers)),
    }
    renderingContext.renderGraph(state.lastGraph)

    const emitDeckViewStateChange = async (viewState) => {
      deckInstance.props.onViewStateChange({viewState})
      // Deck applies initialViewState after its public callback returns.
      deckViewState = viewState
      await Promise.resolve()
    }
    await emitDeckViewStateChange({zoom: 0, target: [100, 180, 0]})
    await emitDeckViewStateChange({zoom: 0.5, target: [100, 180, 0]})

    const admissions = layerSets.slice(1).map((layers) => {
      const labelLayer = layers.find((layer) => layer.id === "god-view-node-labels")
      return labelLayer.props.data.map((item) => item.labelAdmission.anchor)
    })
    expect(admissions).toEqual([["right"], ["bottom"]])
    expect(refreshGraphLayersForViewState).toHaveBeenCalledTimes(2)
    expect(reshapeGraph).toHaveBeenCalledTimes(1)
    expect(tierRenderGraph).not.toHaveBeenCalled()
    expect(state.lastGraphLayerFrame.effective.shape).toBe("local")
    expect(state.lastGraphLayerFrame.effective._topologyScene).toBe(scene)
    expect(effective._topologyScene).toBe(scene)
  })

  it.each(["auto", "local", "global", "regional"])(
    "keeps detail density in %s mode without changing local ELK semantics",
    async (zoomMode) => {
    const routePoints = Object.freeze([
      Object.freeze({x: 0, y: 0}),
      Object.freeze({x: 192, y: 0}),
    ])
    const routes = Object.freeze([
      Object.freeze({sourceId: "left", targetId: "right", points: routePoints}),
    ])
    const sceneNodes = Object.freeze([
      Object.freeze({id: "left", center: Object.freeze({x: 0, y: 0}), render: true}),
      Object.freeze({id: "right", center: Object.freeze({x: 192, y: 0}), render: true}),
    ])
    const scene = Object.freeze({
      bounds: Object.freeze({minX: 0, minY: 0, maxX: 192, maxY: 1}),
      nodes: sceneNodes,
      groups: Object.freeze([]),
      routes,
    })
    const graphNodes = Object.freeze([
      Object.freeze({id: "left", x: 0, y: 0, details: Object.freeze({cluster_kind: "endpoint-member", cluster_expanded: true})}),
      Object.freeze({id: "right", x: 192, y: 0, details: Object.freeze({cluster_kind: "endpoint-member", cluster_expanded: true})}),
    ])
    const graph = Object.freeze({
      shape: "local",
      _layoutMode: "elk-scene-detail",
      _topologySemanticLevel: "detail",
      _topologyScene: scene,
      nodes: graphNodes,
    })
    const initialEffective = {...graph}
    const state = {
      canvas: {},
      visual: {bg: [10, 10, 10, 255]},
      layers: {atmosphere: false},
      viewState: {zoom: -1, minZoom: -8, maxZoom: 5, target: [96, 0, 0]},
      isProgrammaticViewUpdate: false,
      userCameraLocked: false,
      zoomMode,
      zoomTier: "local",
      managedTopologyCameraBaseMinZoom: -8,
      managedTopologyVisualDensity: "detail",
      lastGraph: graph,
      lastGraphLayerFrame: {
        effective: initialEffective,
        nodeData: graphNodes,
        edgeData: [],
        edgeLabelData: [],
        rootPulseNodes: [],
      },
    }
    const renderingContext = createStateBackedContext(state, {})
    Object.assign(
      renderingContext,
      bindApi(renderingContext, godViewRenderingGraphCoreMethods),
      bindApi(renderingContext, godViewRenderingGraphLayerNodeMethods),
      bindApi(renderingContext, godViewRenderingGraphViewMethods),
      {buildGraphLayers: vi.fn(() => [])},
    )
    state.deck = {setProps: vi.fn()}
    const refreshGraphLayersForViewState = vi.fn(() => renderingContext.refreshGraphLayersForViewState())
    const deps = {
      getNodeTooltip: vi.fn(),
      handleHover: vi.fn(),
      handlePick: vi.fn(),
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
      managedVisualDensityForViewScale: renderingContext.managedVisualDensityForViewScale,
      managedViewStateForCamera: (...args) => renderingContext.managedViewStateForCamera(...args),
      refreshGraphLayersForViewState,
    }
    const lifecycleContext = createStateBackedContext(state, deps)
    Object.assign(lifecycleContext, bindApi(lifecycleContext, godViewLifecycleDomSetupMethods))
    const deckInstance = lifecycleContext.createDeckInstance(1000, 700)
    const originalGeometry = JSON.stringify(scene)

    deckInstance.props.onViewStateChange({
      viewState: {...state.viewState, zoom: Math.log2(0.15), target: [96, 0, 0]},
    })
    await Promise.resolve()
    expect(state.managedTopologyVisualDensity).toBe("detail")
    expect(state.lastGraphLayerFrame.effective.shape).toBe("local")
    expect(state.lastGraphLayerFrame.effective._topologyScene).toBe(scene)
    expect(state.lastGraphLayerFrame.effective.nodes).toBe(graphNodes)
    expect(state.lastGraphLayerFrame.effective._topologyScene.routes).toBe(routes)

    deckInstance.props.onViewStateChange({
      viewState: {...state.viewState, zoom: Math.log2(0.25), target: [96, 0, 0]},
    })
    await Promise.resolve()
    expect(state.managedTopologyVisualDensity).toBe("detail")
    expect(state.lastGraphLayerFrame.effective.shape).toBe("local")
    expect(state.lastGraphLayerFrame.effective._topologyScene).toBe(scene)
    expect(state.lastGraphLayerFrame.effective.nodes).toBe(graphNodes)
    expect(state.lastGraphLayerFrame.effective._topologyScene.routes).toBe(routes)
    expect(JSON.stringify(scene)).toBe(originalGeometry)
    expect(refreshGraphLayersForViewState).toHaveBeenCalledTimes(2)
  })

  it("handleDetailsPanelClick closes the details card", () => {
    const state = {}
    const deps = {focusNodeByIndex: vi.fn(), handlePick: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    const action = {getAttribute: () => null}
    const event = {
      target: {
        closest: (selector) => (selector === "[data-close-details]" ? action : null),
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleDetailsPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(deps.handlePick).toHaveBeenCalledWith({picked: false, object: null, index: -1, layer: null})
    expect(deps.focusNodeByIndex).not.toHaveBeenCalled()
  })

  it("handleDetailsPanelClick navigates device links", () => {
    const state = {}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))
    ctx.navigateToHref = vi.fn()

    const link = {getAttribute: (name) => (name === "data-device-href" ? "/devices/sr%3Atest-01" : null)}
    const event = {
      target: {
        closest: (selector) => (selector === "[data-device-href]" ? link : null),
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleDetailsPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(ctx.navigateToHref).toHaveBeenCalledWith("/devices/sr%3Atest-01")
    expect(deps.focusNodeByIndex).not.toHaveBeenCalled()
  })

  it("handleDetailsPanelClick focuses node index actions", () => {
    const state = {}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    const action = {getAttribute: (name) => (name === "data-node-index" ? "7" : null)}
    const event = {
      target: {
        closest: (selector) =>
          selector === "[data-device-href]" ? null : selector === "[data-node-index]" ? action : null,
      },
      preventDefault: vi.fn(),
    }

    ctx.handleDetailsPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(deps.focusNodeByIndex).toHaveBeenCalledWith(7, true)
  })

  it("handleDetailsPanelClick routes cluster expansion actions", () => {
    const state = {}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))
    ctx.setClusterExpanded = vi.fn()

    const action = {
      getAttribute: (name) => {
        if (name === "data-cluster-id") return "cluster:endpoints:sr:test"
        if (name === "data-cluster-expand") return "true"
        return null
      },
    }
    const event = {
      target: {
        closest: (selector) =>
          selector === "[data-device-href]"
            ? null
            : selector === "[data-cluster-id]"
              ? action
              : null,
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleDetailsPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(ctx.setClusterExpanded).toHaveBeenCalledWith("cluster:endpoints:sr:test", true)
    expect(deps.focusNodeByIndex).not.toHaveBeenCalled()
  })

  it("handleDetailsPanelClick pushes topology camera relay open events", () => {
    const pushEvent = vi.fn()
    const state = {pushEvent}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    const action = {
      getAttribute: (name) => {
        if (name === "data-camera-source-id") return "11111111-1111-1111-1111-111111111111"
        if (name === "data-stream-profile-id") return "22222222-2222-2222-2222-222222222222"
        if (name === "data-camera-device-uid") return "sr:camera-topology-01"
        if (name === "data-camera-label") return "Lobby Camera"
        if (name === "data-camera-profile-label") return "Main Stream"
        return null
      },
    }
    const event = {
      target: {
        closest: (selector) =>
          selector === "[data-device-href]"
            ? null
            : selector === "[data-camera-source-id]"
              ? action
              : null,
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleDetailsPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(pushEvent).toHaveBeenCalledWith("god_view_open_camera_relay", {
      camera_source_id: "11111111-1111-1111-1111-111111111111",
      stream_profile_id: "22222222-2222-2222-2222-222222222222",
      insecure_skip_verify: false,
      device_uid: "sr:camera-topology-01",
      camera_label: "Lobby Camera",
      profile_label: "Main Stream",
    })
    expect(deps.focusNodeByIndex).not.toHaveBeenCalled()
  })

  it("handleDetailsPanelClick pushes topology camera tile-set open events", () => {
    const pushEvent = vi.fn()
    const state = {pushEvent}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    const action = {
      getAttribute: (name) => {
        if (name === "data-camera-cluster-id") return "cluster:endpoints:sr:test"
        if (name === "data-camera-cluster-label") return "5 endpoints"
        if (name === "data-camera-cluster-tiles") {
          return JSON.stringify([
            {
              camera_source_id: "11111111-1111-1111-1111-111111111111",
              stream_profile_id: "22222222-2222-2222-2222-222222222222",
              device_uid: "sr:camera-topology-01",
              camera_label: "Lobby Camera",
              profile_label: "Main Stream",
            },
            {
              camera_source_id: "33333333-3333-3333-3333-333333333333",
              stream_profile_id: "44444444-4444-4444-4444-444444444444",
              device_uid: "sr:camera-topology-02",
              camera_label: "Loading Dock Camera",
              profile_label: "Main Stream",
            },
          ])
        }

        return null
      },
    }
    const event = {
      target: {
        closest: (selector) =>
          selector === "[data-device-href]"
            ? null
            : selector === "[data-camera-source-id]"
              ? null
              : selector === "[data-camera-cluster-tiles]"
                ? action
                : null,
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleDetailsPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(pushEvent).toHaveBeenCalledWith("god_view_open_camera_relay_cluster", {
      cluster_id: "cluster:endpoints:sr:test",
      cluster_label: "5 endpoints",
      camera_tiles: [
        {
          camera_source_id: "11111111-1111-1111-1111-111111111111",
          stream_profile_id: "22222222-2222-2222-2222-222222222222",
          device_uid: "sr:camera-topology-01",
          camera_label: "Lobby Camera",
          profile_label: "Main Stream",
        },
        {
          camera_source_id: "33333333-3333-3333-3333-333333333333",
          stream_profile_id: "44444444-4444-4444-4444-444444444444",
          device_uid: "sr:camera-topology-02",
          camera_label: "Loading Dock Camera",
          profile_label: "Main Stream",
        },
      ],
    })
    expect(deps.focusNodeByIndex).not.toHaveBeenCalled()
  })

  it("handleTooltipPanelClick navigates tooltip links", () => {
    const state = {}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))
    ctx.navigateToHref = vi.fn()

    const link = {getAttribute: (name) => (name === "href" ? "/devices/sr%3Atest-02" : null)}
    const event = {
      target: {
        closest: (selector) => (selector === ".deck-tooltip a[href]" ? link : null),
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleTooltipPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(ctx.navigateToHref).toHaveBeenCalledWith("/devices/sr%3Atest-02")
    expect(deps.focusNodeByIndex).not.toHaveBeenCalled()
  })
})
