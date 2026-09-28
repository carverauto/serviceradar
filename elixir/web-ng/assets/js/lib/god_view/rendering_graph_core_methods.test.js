import {describe, expect, it, vi} from "vitest"

import {godViewRenderingGraphCoreMethods} from "./rendering_graph_core_methods"

function renderContext() {
  const scene = {
    profileKey: "landscape",
    manifest: {
      nodes: 2,
      semanticEdges: 1,
      attachmentEdges: 0,
      renderedRoutes: 1,
      renderedGlyphs: 2,
    },
    bounds: {minX: 10, minY: 20, maxX: 110, maxY: 80},
    nodes: [
      {id: "router-a", kind: "node", groupId: null, center: {x: 20, y: 40}, width: 40, height: 32},
      {id: "router-b", kind: "node", groupId: null, center: {x: 100, y: 60}, width: 40, height: 32},
    ],
    groups: [],
    routes: [{
      id: "rendered:router-a|router-b",
      sourceId: "router-a",
      targetId: "router-b",
      relationIds: ["edge-a-b"],
      points: [{x: 20, y: 40}, {x: 60, y: 40}, {x: 60, y: 60}, {x: 100, y: 60}],
    }],
  }
  const effective = {
    shape: "local",
    _layoutMode: "elk-scene",
    _layoutCacheKey: "7:fixture:landscape:scene-key",
    _topologyScene: scene,
  }
  const nodeData = scene.nodes.map((node, index) => ({
    id: node.id,
    index,
    position: [node.center.x, node.center.y, 0],
    details: {},
    pps: 999_999,
  }))
  const labelData = [{
    ...nodeData[0],
    labelAdmission: {
      box: {left: 121, top: 201, right: 177, bottom: 217},
      pixelOffset: [14, 0],
      textAnchor: "start",
      alignmentBaseline: "center",
    },
  }]
  const viewport = {
    width: 1920,
    height: 1080,
    project: ([x, y]) => [x + 100, y + 200],
  }
  const state = {
    deck: {
      getViewports: () => [viewport],
      setProps: vi.fn(),
    },
    layers: {atmosphere: true},
    lastGraphLayerFrame: null,
    topologyLabelSafeRect: {left: 80, top: 48, right: 1870, bottom: 1012},
    viewState: {target: [60, 50, 0], zoom: 1.25, minZoom: -3, maxZoom: 5},
    csrfToken: "must-never-leak",
    bearerToken: "also-must-never-leak",
  }
  const context = {
    state,
    deps: {
      ensureDeck: vi.fn(),
      reshapeGraph: () => effective,
    },
    autoFitViewState: vi.fn(),
    buildVisibleGraphData: () => ({
      edgeData: [{
        sourceId: "router-a",
        targetId: "router-b",
        flowPps: 42_000,
        protocol: "credential-looking-telemetry",
      }],
      edgeLabelData: [],
      nodeData,
      rootPulseNodes: [],
      selectedVisibleNode: null,
    }),
    renderSelectionDetails: vi.fn(),
    nodeHaloRadiusPixels: () => 20,
    topologyRouteStrokeWidth: () => 38,
    buildGraphLayers: () => [{
      id: "god-view-edges-mantle",
      props: {
        data: [{
          interactionKey: "local:rendered:router-a|router-b",
          sourceId: "router-a",
          targetId: "router-b",
          flowPps: 42_000,
        }],
        getWidth: () => 38,
        widthMinPixels: 6,
        widthUnits: "pixels",
      },
    }, {id: "god-view-node-labels", props: {data: labelData}}],
  }

  return {context, effective}
}

describe("God-View render frame observer seam", () => {
  it("notifies a neutral optional frame observer after render and view-state refresh", () => {
    const {context, effective} = renderContext()
    context.state.renderFrameObserver = vi.fn()

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)
    expect(context.state.renderFrameObserver).toHaveBeenCalledTimes(1)
    expect(context.state.renderFrameObserver).toHaveBeenLastCalledWith(expect.objectContaining({
      context,
      effective,
    }))

    context.state.viewState = {target: [72, 64, 0], zoom: 2, minZoom: -3, maxZoom: 5}
    context.state.managedTopologyVisualDensity = "overview"
    expect(godViewRenderingGraphCoreMethods.refreshGraphLayersForViewState.call(context)).toBe(true)
    expect(context.state.renderFrameObserver).toHaveBeenCalledTimes(2)
    expect(context.state.lastGraphLayerFrame.effective.shape).toBe("local")
    expect(context.state.renderFrameObserver).toHaveBeenLastCalledWith(expect.objectContaining({
      effective: expect.objectContaining({shape: "local"}),
    }))
  })

  it("renders normally without an observer", () => {
    const {context, effective} = renderContext()

    expect(() => godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)).not.toThrow()
    expect(context.state.deck.setProps).toHaveBeenCalledWith({layers: expect.any(Array)})
  })

  it("advanceAnimation re-issues only the clock-driven layers, with the same data", async () => {
    const {ScatterplotLayer, TextLayer} = await import("@deck.gl/layers")
    const {default: PacketFlowLayer} = await import("../deckgl/PacketFlowLayer")
    const {godViewRenderingGraphLayerTransportMethods} = await import("./rendering_graph_layer_transport_methods")
    const flowData = {length: 1, attributes: {instanceEndpoints: new Float32Array(4)}}
    const flow = new PacketFlowLayer({id: "god-view-atmosphere-particles", data: flowData, time: 0})
    const glyphs = new ScatterplotLayer({id: "god-view-nodes", data: [{position: [0, 0]}]})
    const labels = new TextLayer({id: "god-view-node-labels", data: []})
    const setProps = vi.fn()
    const state = {deck: {setProps}, lastGraphLayers: [glyphs, flow, labels], animationPhase: 2.5, visual: {pulse: [1, 2, 3, 4]}}
    const ctx = {state, deps: {}}
    Object.assign(ctx, godViewRenderingGraphCoreMethods, godViewRenderingGraphLayerTransportMethods)

    expect(ctx.advanceAnimation()).toBe(true)

    const [{layers}] = setProps.mock.calls[0]
    expect(layers[0]).toBe(glyphs)
    expect(layers[2]).toBe(labels)
    expect(layers[1]).not.toBe(flow)
    expect(layers[1].props.data).toBe(flowData)
    expect(layers[1].props.time).toBe(2.5)
    expect(state.lastGraphLayers).toBe(layers)
  }, 30_000)

  it("refreshDeferredLayers admits labels once deck has a viewport, and not before", () => {
    const viewport = {project: () => [0, 0]}
    let viewports = []
    const state = {deck: {getViewports: () => viewports}, labelAdmissionAwaitingViewport: true, atmosphereSuppressUntil: 0}
    const ctx = {state, refreshGraphLayersForViewState: vi.fn(() => true)}
    Object.assign(ctx, {
      refreshDeferredLayers: godViewRenderingGraphCoreMethods.refreshDeferredLayers,
      activeTopologyLabelViewport: () => viewports[0] || null,
    })

    expect(ctx.refreshDeferredLayers()).toBe(false)
    expect(ctx.refreshGraphLayersForViewState).not.toHaveBeenCalled()

    viewports = [viewport]
    expect(ctx.refreshDeferredLayers()).toBe(true)
    expect(ctx.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
  })

  it("refreshDeferredLayers brings packet flow back once its hold expires", () => {
    const state = {labelAdmissionAwaitingViewport: false, atmosphereSuppressUntil: performance.now() + 60_000}
    const ctx = {state, refreshGraphLayersForViewState: vi.fn(() => true), activeTopologyLabelViewport: () => null}
    ctx.refreshDeferredLayers = godViewRenderingGraphCoreMethods.refreshDeferredLayers

    expect(ctx.refreshDeferredLayers()).toBe(false)

    state.atmosphereSuppressUntil = performance.now() - 1
    expect(ctx.refreshDeferredLayers()).toBe(true)
    expect(state.atmosphereSuppressUntil).toBe(0)
    expect(ctx.refreshGraphLayersForViewState).toHaveBeenCalledTimes(1)
  })
})
