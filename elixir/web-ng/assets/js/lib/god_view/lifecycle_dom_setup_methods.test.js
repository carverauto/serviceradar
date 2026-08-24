import {describe, expect, it, vi} from "vitest"

vi.mock("@deck.gl/core", () => ({
  COORDINATE_SYSTEM: {CARTESIAN: "cartesian"},
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
      lastGraph: {_layoutMode: "elk-scene", _topologyScene: {profileKey: "landscape"}},
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

  it("crossing usable aspect 1.2 invalidates and requests one fresh profile layout", async () => {
    const previousGraph = {_layoutMode: "elk-scene", _topologyScene: {profileKey: "landscape"}, nodes: [], edges: []}
    const portraitGraph = {_layoutMode: "elk-scene", _topologyScene: {profileKey: "portrait"}, nodes: [], edges: []}
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
      resizeLayoutRequestToken: 0,
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
    expect(state.lastLayoutKey).toBe(null)
    expect(deps.prepareGraphLayout).toHaveBeenCalledTimes(1)
    expect(deps.prepareGraphLayout).toHaveBeenCalledWith(previousGraph, 8, "same-graph")
    expect(state.lastGraph).toBe(portraitGraph)
    expect(deps.renderGraph).toHaveBeenCalledWith(portraitGraph)
  })

  it("user-locked resize updates Deck and label projection without auto-refitting", () => {
    const state = {
      el: {
        clientWidth: 980,
        clientHeight: 600,
        getBoundingClientRect: () => ({left: 0, top: 0, width: 980, height: 600, right: 980, bottom: 600}),
        querySelectorAll: () => [],
      },
      canvas: {style: {}},
      deck: {setProps: vi.fn(), redraw: vi.fn()},
      lastGraph: {_layoutMode: "elk-scene", _topologyScene: {profileKey: "landscape"}},
      viewportWidth: 900,
      viewportHeight: 600,
      viewportProfileKey: "landscape",
      userCameraLocked: true,
    }
    const deps = {
      autoFitViewState: vi.fn(),
      refreshGraphLayersForViewState: vi.fn(),
      prepareGraphLayout: vi.fn(),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    ctx.resizeCanvas()

    expect(state.deck.setProps).toHaveBeenCalledWith({width: 980, height: 600})
    expect(deps.autoFitViewState).not.toHaveBeenCalled()
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

  it("recomputes label admission for same-tier pan and zoom without reshaping or laying out", async () => {
    const scene = {routes: []}
    const effective = {shape: "regional", _layoutMode: "elk-scene", _topologyScene: scene}
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
      lastGraph: {_layoutMode: "elk-scene"},
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
    expect(state.lastGraphLayerFrame.effective).toBe(effective)
    expect(effective._topologyScene).toBe(scene)
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
