import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleDomSetupMethods} from "./lifecycle_dom_setup_methods"
import {godViewLifecycleStreamSnapshotMethods} from "./lifecycle_stream_snapshot_methods"

function deferred() {
  let resolve
  const promise = new Promise((next) => { resolve = next })
  return {promise, resolve}
}

function buildFrame(payloadBytes) {
  const payload = Uint8Array.from(payloadBytes)
  const out = new Uint8Array(53 + payload.length)
  out[0] = "G".charCodeAt(0)
  out[1] = "V".charCodeAt(0)
  out[2] = "B".charCodeAt(0)
  out[3] = "1".charCodeAt(0)

  const view = new DataView(out.buffer)
  view.setUint8(4, 2)
  view.setBigUint64(5, 42n, false)
  view.setBigInt64(13, 1_700_000_000_000n, false)
  view.setUint32(21, 11, false)
  view.setUint32(25, 12, false)
  view.setUint32(29, 13, false)
  view.setUint32(33, 14, false)
  view.setUint32(37, 3, false)
  view.setUint32(41, 4, false)
  view.setUint32(45, 5, false)
  view.setUint32(49, 6, false)
  out.set(payload, 53)

  return out.buffer
}

describe("lifecycle_stream_snapshot_methods", () => {
  it("parseBinarySnapshotFrame decodes header and payload", () => {
    const frame = buildFrame([7, 8, 9])
    const parsed = godViewLifecycleStreamSnapshotMethods.parseBinarySnapshotFrame(frame)

    expect(parsed.schemaVersion).toEqual(2)
    expect(parsed.revision).toEqual(42)
    expect(parsed.bitmapMetadata.root_cause.bytes).toEqual(11)
    expect(parsed.bitmapMetadata.unknown.count).toEqual(6)
    expect(Array.from(parsed.payload)).toEqual([7, 8, 9])
  })

  it("parseSnapshotMessage supports binary tuple payload", () => {
    const state = {}
    const methods = createStateBackedContext(state, {})
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))
    const frame = buildFrame([1, 2])
    const encoded = Buffer.from(new Uint8Array(frame)).toString("base64")

    const parsed = methods.parseSnapshotMessage(["binary", encoded])
    expect(Array.from(parsed.payload)).toEqual([1, 2])
  })

  it("parseBinarySnapshotFrame rejects invalid magic", () => {
    const frame = new Uint8Array(buildFrame([1]))
    frame[0] = "X".charCodeAt(0)

    expect(() => godViewLifecycleStreamSnapshotMethods.parseBinarySnapshotFrame(frame.buffer)).toThrow(
      /unexpected binary snapshot magic/,
    )
  })

  it("handleSnapshot still decodes and renders when revision is unchanged but the snapshot graph changes", async () => {
    const state = {
      lastRevision: 42,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: {nodes: [{id: "before"}], edges: [], _layoutMode: "client-radial"},
      lastVisibleNodeCount: 0,
      lastVisibleEdgeCount: 0,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      pushEvent: () => {},
      summary: {textContent: ""},
    }
    const previousGraph = state.lastGraph
    const graph = {nodes: [{id: "after", x: 10, y: 20}], edges: [], _layoutMode: "client-radial"}
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "after"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "next-stamp"),
      prepareGraphLayout: vi.fn(async () => graph),
      ensureBitmapMetadata: () => ({}),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      normalizePipelineStats: () => ({}),
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(state.lastSnapshotAt).toBeGreaterThan(0)
    expect(deps.decodeArrowGraph).toHaveBeenCalledTimes(1)
    expect(deps.prepareGraphLayout).toHaveBeenCalledTimes(1)
    expect(deps.animateTransition).toHaveBeenCalledWith(previousGraph, graph)
  })

  it("handleSnapshot awaits async layout preparation before rendering", async () => {
    const state = {
      lastRevision: null,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: null,
      lastVisibleNodeCount: 1,
      lastVisibleEdgeCount: 3,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "local",
      lastPipelineStats: null,
      pushEvent: vi.fn(),
      summary: {textContent: ""},
    }

    const graph = {nodes: [{id: "a", x: 10, y: 20}], edges: [], _layoutMode: "elk-client"}
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "a"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "stamp"),
      prepareGraphLayout: vi.fn(async () => graph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }

    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(deps.prepareGraphLayout).toHaveBeenCalledTimes(1)
    expect(deps.animateTransition).toHaveBeenCalledWith(null, graph)
    expect(state.lastGraph).toBe(graph)
    expect(state.summary.textContent).toContain("layout=elk-client")
    expect(state.summary.textContent).toContain("rendered_edges=3")
    expect(state.pushEvent).toHaveBeenCalledWith(
      "god_view_stream_stats",
      expect.objectContaining({
        edge_count: 0,
        rendered_node_count: 1,
        rendered_edge_count: 3,
      }),
    )
  })

  it("renders a compatible last-good ELK scene and reports its non-fatal layout diagnostic", async () => {
    const previousGraph = {
      nodes: [{id: "a", x: 10, y: 20}],
      edges: [],
      _layoutMode: "elk-scene",
      _layoutCacheKey: "stable-layout",
      _topologyScene: {profileKey: "landscape"},
    }
    const recoveredGraph = {
      nodes: [{id: "a", x: 30, y: 40}],
      edges: [],
      _layoutMode: "elk-scene",
      _layoutCacheKey: "stable-layout",
      _topologyScene: {profileKey: "landscape"},
      _layoutError: "transient ELK failure",
    }
    const state = {
      lastRevision: 41,
      lastTopologyStamp: "previous-stamp",
      lastSnapshotAt: 100,
      layoutRequestToken: 0,
      lastGraph: previousGraph,
      layoutMode: "elk-scene",
      layoutRevision: 41,
      lastLayoutKey: "stable-layout",
      viewportProfileKey: "landscape",
      lastVisibleNodeCount: 1,
      lastVisibleEdgeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      pushEvent: vi.fn(),
      summary: {textContent: "accepted scene"},
    }
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "a"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "current-stamp"),
      prepareGraphLayout: vi.fn(async () => recoveredGraph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(state.lastGraph).toBe(recoveredGraph)
    expect(state.lastRevision).toBe(42)
    expect(state.lastTopologyStamp).toBe("current-stamp")
    expect(deps.animateTransition).toHaveBeenCalledWith(previousGraph, recoveredGraph)
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "layout_error",
      message: "transient ELK failure",
      reused_last_good: true,
    })
    expect(state.pushEvent).toHaveBeenCalledWith(
      "god_view_stream_stats",
      expect.objectContaining({revision: 42, node_count: 1}),
    )
  })

  it("reports an initial ELK layout failure without installing unpositioned nodes", async () => {
    const state = {
      lastRevision: null,
      lastTopologyStamp: null,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: null,
      layoutMode: null,
      layoutRevision: null,
      lastLayoutKey: null,
      lastVisibleNodeCount: 0,
      lastVisibleEdgeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      pushEvent: vi.fn(),
      summary: {textContent: "waiting"},
    }
    const failedGraph = {
      nodes: [{id: "unpositioned"}],
      edges: [],
      _layoutMode: "elk-scene-error",
      _layoutError: "ELK unavailable",
    }
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "unpositioned"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "failed-stamp"),
      prepareGraphLayout: vi.fn(async () => failedGraph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(state.lastGraph).toBe(null)
    expect(state.lastRevision).toBe(null)
    expect(state.lastTopologyStamp).toBe(null)
    expect(state.layoutMode).toBe(null)
    expect(state.layoutRevision).toBe(null)
    expect(state.lastLayoutKey).toBe(null)
    expect(state.summary.textContent).toBe("topology layout unavailable")
    expect(deps.renderGraph).not.toHaveBeenCalled()
    expect(deps.animateTransition).not.toHaveBeenCalled()
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "layout_error",
      message: "ELK unavailable",
    })
    expect(state.pushEvent).not.toHaveBeenCalledWith(
      "god_view_stream_error",
      expect.objectContaining({reason: "decode_error"}),
    )
  })

  it("preserves the last good scene after an incompatible layout failure and accepts a later snapshot", async () => {
    const previousGraph = {
      nodes: [{id: "old", x: 10, y: 20}],
      edges: [],
      _layoutMode: "elk-scene",
      _layoutCacheKey: "old-layout",
      _topologyScene: {profileKey: "landscape"},
    }
    const failedGraph = {
      nodes: [{id: "changed"}],
      edges: [],
      _layoutMode: "elk-scene-error",
      _layoutError: "incompatible ELK failure",
    }
    const recoveredGraph = {
      nodes: [{id: "recovered", x: 30, y: 40}],
      edges: [],
      _layoutMode: "elk-scene",
      _layoutCacheKey: "recovered-layout",
      _topologyScene: {profileKey: "landscape"},
    }
    const state = {
      lastRevision: 41,
      lastTopologyStamp: "old-stamp",
      lastSnapshotAt: 100,
      layoutRequestToken: 0,
      lastGraph: previousGraph,
      layoutMode: "elk-scene",
      layoutRevision: 41,
      lastLayoutKey: "old-layout",
      viewportProfileKey: "landscape",
      lastVisibleNodeCount: 1,
      lastVisibleEdgeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      userCameraLocked: false,
      pushEvent: vi.fn(),
      summary: {textContent: "old summary"},
    }
    const rawFailed = {nodes: [{id: "changed"}], edges: []}
    const rawRecovered = {nodes: [{id: "recovered"}], edges: []}
    const deps = {
      decodeArrowGraph: vi.fn()
        .mockReturnValueOnce(rawFailed)
        .mockReturnValueOnce(rawRecovered),
      graphTopologyStamp: vi.fn((graph) => graph === rawFailed ? "failed-stamp" : "recovered-stamp"),
      prepareGraphLayout: vi.fn()
        .mockResolvedValueOnce(failedGraph)
        .mockResolvedValueOnce(recoveredGraph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1]))

    expect(state.lastGraph).toBe(previousGraph)
    expect(state.lastRevision).toBe(41)
    expect(state.lastTopologyStamp).toBe("old-stamp")
    expect(state.layoutRevision).toBe(41)
    expect(state.lastLayoutKey).toBe("old-layout")
    expect(deps.renderGraph).not.toHaveBeenCalled()
    expect(deps.animateTransition).not.toHaveBeenCalled()

    await methods.handleSnapshot(buildFrame([2]))

    expect(state.lastGraph).toBe(recoveredGraph)
    expect(state.lastRevision).toBe(42)
    expect(state.lastTopologyStamp).toBe("recovered-stamp")
    expect(state.layoutRevision).toBe(42)
    expect(state.lastLayoutKey).toBe("recovered-layout")
    expect(deps.animateTransition).toHaveBeenCalledTimes(1)
    expect(deps.animateTransition).toHaveBeenCalledWith(previousGraph, recoveredGraph)
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "layout_error",
      message: "incompatible ELK failure",
    })
    expect(state.pushEvent).not.toHaveBeenCalledWith(
      "god_view_stream_error",
      expect.objectContaining({reason: "decode_error"}),
    )
  })

  it("rolls back snapshot acceptance when rendering throws and recovers on the next snapshot", async () => {
    const previousGraph = {
      nodes: [{id: "old", x: 10, y: 20}],
      edges: [],
      _layoutMode: "elk-scene",
      _layoutCacheKey: "old-layout",
      _topologyScene: {profileKey: "landscape"},
    }
    const failedGraph = {
      nodes: [{id: "failed", x: 30, y: 40}],
      edges: [],
      _layoutMode: "elk-scene",
      _layoutCacheKey: "failed-layout",
      _topologyScene: {profileKey: "portrait"},
    }
    const recoveredGraph = {
      nodes: [{id: "recovered", x: 50, y: 60}],
      edges: [],
      _layoutMode: "elk-scene",
      _layoutCacheKey: "recovered-layout",
      _topologyScene: {profileKey: "portrait"},
    }
    const state = {
      lastRevision: 41,
      lastTopologyStamp: "old-stamp",
      lastSnapshotAt: 100,
      layoutRequestToken: 0,
      lastGraph: previousGraph,
      layoutMode: "elk-scene",
      layoutRevision: 41,
      lastLayoutKey: "old-layout",
      viewportProfileKey: "landscape",
      pendingViewportProfileKey: "portrait",
      lastVisibleNodeCount: 1,
      lastVisibleEdgeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      userCameraLocked: false,
      hasAutoFit: true,
      pushEvent: vi.fn(),
      summary: {textContent: "old summary"},
    }
    const rawFailed = {nodes: [{id: "failed"}], edges: []}
    const rawRecovered = {nodes: [{id: "recovered"}], edges: []}
    const previousScene = previousGraph._topologyScene
    const previousViewState = {target: [10, 20, 0], zoom: 1, minZoom: -2, maxZoom: 5}
    const previousLayerFrame = {effective: previousGraph}
    const previousConstraintsCache = {graph: previousGraph, scene: previousScene}
    const previousConstraintsLayoutCache = new Map([["accepted-layout", previousConstraintsCache]])
    const previousRouteDiagnostics = [{routeId: "accepted"}]
    const previousLabelFallbackIds = ["accepted-label"]
    const previousVisibilityMask = Uint8Array.from([1, 0])
    const previousTraversalMask = Uint8Array.from([1, 1])
    const previousPacketFlowCache = [{edgeIndex: 0}]
    Object.assign(state, {
      hoveredEdgeKey: "accepted:hovered",
      isProgrammaticViewUpdate: false,
      lastDetailsHtml: "accepted details",
      lastGraphLayerFrame: previousLayerFrame,
      managedTopologyDensityConstraintsCache: previousConstraintsCache,
      managedTopologyDensityConstraintsLayoutCache: previousConstraintsLayoutCache,
      managedTopologySceneForMinZoom: previousScene,
      managedTopologySceneMinZoom: -1.5,
      managedTopologySceneMinZoomKey: "layout:old-layout",
      managedTopologyVisualDensity: "overview",
      packetFlowCache: previousPacketFlowCache,
      packetFlowCacheStamp: "accepted-flow",
      selectedEdgeKey: "accepted:selected",
      topologyLabelDetailsFallbackIds: previousLabelFallbackIds,
      topologyRouteDiagnostics: previousRouteDiagnostics,
      traversalMaskBuffer: previousTraversalMask,
      viewState: previousViewState,
      visibilityMaskBuffer: previousVisibilityMask,
      wasmReady: true,
      layers: {atmosphere: true},
    })
    let onscreenGraph = previousGraph
    let onscreenViewState = previousViewState
    state.deck = {
      setProps: vi.fn(({viewState}) => {
        if (viewState) onscreenViewState = viewState
      }),
    }
    const deps = {
      decodeArrowGraph: vi.fn()
        .mockReturnValueOnce(rawFailed)
        .mockReturnValueOnce(rawRecovered),
      graphTopologyStamp: vi.fn((graph) => graph === rawFailed ? "failed-stamp" : "recovered-stamp"),
      prepareGraphLayout: vi.fn()
        .mockResolvedValueOnce(failedGraph)
        .mockResolvedValueOnce(recoveredGraph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn((graph) => {
        onscreenGraph = graph
        if (graph === previousGraph) throw new Error("rollback render failed")
      }),
      animateTransition: vi.fn()
        .mockImplementationOnce(() => {
          onscreenGraph = failedGraph
          state.hoveredEdgeKey = null
          state.isProgrammaticViewUpdate = true
          state.lastDetailsHtml = "failed details"
          state.lastGraphLayerFrame = {effective: failedGraph}
          state.lastVisibleEdgeCount = 7
          state.lastVisibleNodeCount = 9
          state.managedTopologyDensityConstraintsCache = {graph: failedGraph}
          state.managedTopologyDensityConstraintsLayoutCache = new Map([["failed-layout", {graph: failedGraph}]])
          state.managedTopologySceneForMinZoom = failedGraph._topologyScene
          state.managedTopologySceneMinZoom = 2.5
          state.managedTopologySceneMinZoomKey = "layout:failed-layout"
          state.managedTopologyVisualDensity = "detail"
          state.packetFlowCache = [{edgeIndex: 9}]
          state.packetFlowCacheStamp = "failed-flow"
          state.selectedEdgeKey = null
          state.topologyLabelDetailsFallbackIds = ["failed-label"]
          state.topologyRouteDiagnostics = [{routeId: "failed"}]
          state.traversalMaskBuffer.fill(0)
          state.viewState = {target: [30, 40, 0], zoom: 3, minZoom: 2.5, maxZoom: 5}
          onscreenViewState = state.viewState
          state.visibilityMaskBuffer.fill(0)
          state.wasmReady = false
          state.layers.atmosphere = false
          throw new RangeError("camera infeasible")
        })
        .mockImplementationOnce(() => { onscreenGraph = recoveredGraph }),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1]))

    expect(onscreenGraph).toBe(previousGraph)
    expect(onscreenViewState).toBe(previousViewState)
    expect(state.lastGraph).toBe(previousGraph)
    expect(state.lastRevision).toBe(41)
    expect(state.lastTopologyStamp).toBe("old-stamp")
    expect(state.lastSnapshotAt).toBe(100)
    expect(state.layoutMode).toBe("elk-scene")
    expect(state.layoutRevision).toBe(41)
    expect(state.lastLayoutKey).toBe("old-layout")
    expect(state.viewportProfileKey).toBe("landscape")
    expect(state.pendingViewportProfileKey).toBe("portrait")
    expect(state.hasAutoFit).toBe(true)
    expect(state.hoveredEdgeKey).toBe("accepted:hovered")
    expect(state.isProgrammaticViewUpdate).toBe(false)
    expect(state.lastDetailsHtml).toBe("accepted details")
    expect(state.lastGraphLayerFrame).toBe(previousLayerFrame)
    expect(state.lastVisibleEdgeCount).toBe(0)
    expect(state.lastVisibleNodeCount).toBe(1)
    expect(state.managedTopologySceneForMinZoom).toBe(previousScene)
    expect(state.managedTopologySceneMinZoom).toBe(-1.5)
    expect(state.managedTopologySceneMinZoomKey).toBe("layout:old-layout")
    expect(state.managedTopologyVisualDensity).toBe("overview")
    expect(state.managedTopologyDensityConstraintsCache).toBe(previousConstraintsCache)
    expect(state.managedTopologyDensityConstraintsLayoutCache).toBe(previousConstraintsLayoutCache)
    expect(state.packetFlowCache).toBe(previousPacketFlowCache)
    expect(state.packetFlowCacheStamp).toBe("accepted-flow")
    expect(state.selectedEdgeKey).toBe("accepted:selected")
    expect(state.topologyLabelDetailsFallbackIds).toBe(previousLabelFallbackIds)
    expect(state.topologyRouteDiagnostics).toBe(previousRouteDiagnostics)
    expect(state.traversalMaskBuffer).toBe(previousTraversalMask)
    expect(Array.from(state.traversalMaskBuffer)).toEqual([1, 1])
    expect(state.viewState).toBe(previousViewState)
    expect(state.visibilityMaskBuffer).toBe(previousVisibilityMask)
    expect(Array.from(state.visibilityMaskBuffer)).toEqual([1, 0])
    expect(state.wasmReady).toBe(true)
    expect(state.layers.atmosphere).toBe(true)
    expect(state.summary.textContent).toBe("topology render unavailable")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {
      reason: "render_error",
      message: "RangeError: camera infeasible",
      // A production deck.gl build strips assertion text, so the message alone can name
      // nothing. The stack is the only thing that identifies the layer that threw.
      stack: expect.any(String),
    })
    expect(state.pushEvent).not.toHaveBeenCalledWith(
      "god_view_stream_error",
      expect.objectContaining({reason: "decode_error"}),
    )
    expect(state.pushEvent).not.toHaveBeenCalledWith("god_view_stream_stats", expect.anything())

    await methods.handleSnapshot(buildFrame([2]))

    expect(onscreenGraph).toBe(recoveredGraph)
    expect(state.lastGraph).toBe(recoveredGraph)
    expect(state.lastRevision).toBe(42)
    expect(state.lastTopologyStamp).toBe("recovered-stamp")
    expect(state.lastSnapshotAt).toBeGreaterThan(100)
    expect(state.layoutRevision).toBe(42)
    expect(state.lastLayoutKey).toBe("recovered-layout")
    expect(state.viewportProfileKey).toBe("portrait")
    expect(state.pendingViewportProfileKey).toBe(null)
    expect(deps.animateTransition).toHaveBeenCalledTimes(2)
    expect(state.pushEvent).toHaveBeenCalledWith(
      "god_view_stream_stats",
      expect.objectContaining({revision: 42, node_count: 1}),
    )
  })

  it("a newer snapshot cancels an older resize layout before graph or metadata acceptance", async () => {
    const resizeLayout = deferred()
    const snapshotLayout = deferred()
    const oldGraph = {
      nodes: [{id: "old"}],
      edges: [],
      _layoutMode: "elk-scene",
      _layoutCacheKey: "old-landscape-layout",
      _topologyScene: {profileKey: "landscape"},
    }
    const resizedOldGraph = {
      ...oldGraph,
      _layoutCacheKey: "old-portrait-layout",
      _topologyScene: {profileKey: "portrait"},
    }
    const rawNewGraph = {nodes: [{id: "new"}], edges: []}
    const newGraph = {
      ...rawNewGraph,
      _layoutMode: "elk-scene",
      _layoutRevision: 42,
      _layoutCacheKey: "new-portrait-layout",
      _topologyScene: {profileKey: "portrait"},
    }
    const state = {
      lastRevision: 41,
      lastTopologyStamp: "old-stamp",
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: oldGraph,
      layoutMode: "elk-scene",
      layoutRevision: 41,
      lastLayoutKey: "old-landscape-layout",
      viewportProfileKey: "landscape",
      pendingViewportProfileKey: "portrait",
      lastVisibleNodeCount: 0,
      lastVisibleEdgeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      userCameraLocked: false,
      pushEvent: vi.fn(),
      summary: {textContent: ""},
    }
    const deps = {
      decodeArrowGraph: vi.fn(() => rawNewGraph),
      graphTopologyStamp: vi.fn(() => "new-stamp"),
      prepareGraphLayout: vi.fn((graph) => graph === oldGraph ? resizeLayout.promise : snapshotLayout.promise),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(
      methods,
      bindApi(methods, godViewLifecycleDomSetupMethods),
      bindApi(methods, godViewLifecycleStreamSnapshotMethods),
    )

    const resizeRequest = methods.requestTopologyProfileLayout(oldGraph, "portrait")
    const snapshotRequest = methods.handleSnapshot(buildFrame([1, 2, 3]))
    snapshotLayout.resolve(newGraph)
    await snapshotRequest

    expect(state.lastGraph).toBe(newGraph)
    expect(state.lastRevision).toBe(42)
    expect(state.lastTopologyStamp).toBe("new-stamp")
    expect(state.lastLayoutKey).toBe("new-portrait-layout")
    expect(state.viewportProfileKey).toBe("portrait")

    resizeLayout.resolve(resizedOldGraph)
    expect(await resizeRequest).toBe(false)

    expect(state.lastGraph).toBe(newGraph)
    expect(state.lastRevision).toBe(42)
    expect(state.lastTopologyStamp).toBe("new-stamp")
    expect(state.lastLayoutKey).toBe("new-portrait-layout")
    expect(state.viewportProfileKey).toBe("portrait")
    expect(deps.renderGraph).not.toHaveBeenCalledWith(resizedOldGraph)
    expect(deps.animateTransition).toHaveBeenCalledTimes(1)
    expect(deps.animateTransition).toHaveBeenCalledWith(oldGraph, newGraph)
  })

  it("a resize of the old graph cannot supersede an in-flight snapshot", async () => {
    const snapshotLayout = deferred()
    const resizeLayout = deferred()
    const oldGraph = {
      nodes: [{id: "old"}],
      edges: [],
      _layoutMode: "elk-scene",
      _layoutCacheKey: "old-layout",
      _topologyScene: {profileKey: "landscape"},
    }
    const rawNewGraph = {nodes: [{id: "new"}], edges: []}
    const newGraph = {
      ...rawNewGraph,
      _layoutMode: "elk-scene",
      _layoutRevision: 42,
      _layoutCacheKey: "new-layout",
      _topologyScene: {profileKey: "landscape"},
    }
    const resizedOldGraph = {...oldGraph, _layoutCacheKey: "resized-old-layout"}
    const state = {
      lastRevision: 41,
      lastTopologyStamp: "old-stamp",
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: oldGraph,
      lastVisibleNodeCount: 0,
      lastVisibleEdgeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      userCameraLocked: false,
      pushEvent: vi.fn(),
      summary: {textContent: ""},
    }
    const deps = {
      decodeArrowGraph: vi.fn(() => rawNewGraph),
      graphTopologyStamp: vi.fn(() => "new-stamp"),
      prepareGraphLayout: vi.fn((graph) => graph === rawNewGraph ? snapshotLayout.promise : resizeLayout.promise),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(
      methods,
      bindApi(methods, godViewLifecycleDomSetupMethods),
      bindApi(methods, godViewLifecycleStreamSnapshotMethods),
    )

    const snapshotRequest = methods.handleSnapshot(buildFrame([1, 2, 3]))
    const resizeRequest = methods.requestTopologyProfileLayout(oldGraph, "portrait")
    resizeLayout.resolve(resizedOldGraph)
    expect(await resizeRequest).toBe(false)
    expect(state.lastGraph).toBe(oldGraph)

    snapshotLayout.resolve(newGraph)
    await snapshotRequest

    expect(state.lastGraph).toBe(newGraph)
    expect(state.lastLayoutKey).toBe("new-layout")
    expect(deps.renderGraph).not.toHaveBeenCalledWith(resizedOldGraph)
    expect(deps.animateTransition).toHaveBeenCalledWith(oldGraph, newGraph)
  })

  it("handleSnapshot re-arms autoFit on topology changes when the user has not locked the camera", async () => {
    const state = {
      lastRevision: null,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: {nodes: [{id: "old"}], edges: []},
      lastVisibleNodeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      lastTopologyStamp: "old-stamp",
      userCameraLocked: false,
      hasAutoFit: true,
      pushEvent: vi.fn(),
      summary: {textContent: ""},
    }

    const graph = {nodes: [{id: "a", x: 10, y: 20}], edges: [], _layoutMode: "elk-client"}
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "a"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "new-stamp"),
      prepareGraphLayout: vi.fn(async () => graph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }

    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(state.hasAutoFit).toBe(false)
    expect(deps.animateTransition).toHaveBeenCalledWith({nodes: [{id: "old"}], edges: []}, graph)
  })

  it("handleSnapshot preserves camera lock on topology changes after user interaction", async () => {
    const state = {
      lastRevision: null,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: {nodes: [{id: "old"}], edges: []},
      lastVisibleNodeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      lastTopologyStamp: "old-stamp",
      userCameraLocked: true,
      hasAutoFit: true,
      pushEvent: vi.fn(),
      summary: {textContent: ""},
    }

    const graph = {nodes: [{id: "a", x: 10, y: 20}], edges: [], _layoutMode: "elk-client"}
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "a"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "new-stamp"),
      prepareGraphLayout: vi.fn(async () => graph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }

    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(state.hasAutoFit).toBe(true)
  })

  it("handleSnapshot focuses a pending expanded cluster after the new graph renders", async () => {
    const state = {
      lastRevision: null,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: null,
      lastVisibleNodeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "auto",
      lastPipelineStats: null,
      lastTopologyStamp: null,
      userCameraLocked: false,
      hasAutoFit: false,
      pendingClusterFocus: {clusterId: "cluster:endpoints:sr:test", expanded: true},
      pushEvent: vi.fn(),
      summary: {textContent: ""},
    }

    const graph = {
      nodes: [{id: "cluster:endpoints:sr:test", x: 10, y: 20, details: {cluster_id: "cluster:endpoints:sr:test"}}],
      edges: [],
      _layoutMode: "elk-client",
    }
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "a"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "stamp"),
      prepareGraphLayout: vi.fn(async () => graph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => true),
      normalizePipelineStats: vi.fn(() => ({})),
    }

    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(deps.focusClusterNeighborhood).toHaveBeenCalledWith(graph, "cluster:endpoints:sr:test")
    expect(state.pendingClusterFocus).toBe(null)
  })

  it("handleSnapshot appends per-class edge counts and the backbone-empty marker to the status line", async () => {
    const state = {
      lastRevision: null,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: null,
      lastVisibleNodeCount: 0,
      lastVisibleEdgeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "local",
      lastPipelineStats: {
        backbone_edge_count: 0,
        edge_class_backbone: 0,
        edge_class_attachment: 57,
        edge_class_inferred: 12,
        edge_class_hosted: 3,
        edge_class_observed: 0,
      },
      pushEvent: vi.fn(),
      summary: {textContent: ""},
    }

    const graph = {nodes: [{id: "a", x: 10, y: 20}], edges: [], _layoutMode: "elk-client"}
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "a"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "stamp"),
      prepareGraphLayout: vi.fn(async () => graph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn((stats) => stats),
    }

    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(state.summary.textContent).toContain("classes=bb:0/att:57/inf:12/host:3/obs:0")
    expect(state.summary.textContent).toContain("backbone=EMPTY")
    expect(state.pushEvent).toHaveBeenCalledWith(
      "god_view_stream_stats",
      expect.objectContaining({
        pipeline_stats: expect.objectContaining({backbone_edge_count: 0, edge_class_attachment: 57}),
      }),
    )
  })

  it("handleSnapshot omits the class fragment when per-class counts are unavailable", async () => {
    const state = {
      lastRevision: null,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: null,
      lastVisibleNodeCount: 0,
      lastVisibleEdgeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "local",
      lastPipelineStats: null,
      pushEvent: vi.fn(),
      summary: {textContent: ""},
    }

    const graph = {nodes: [{id: "a", x: 10, y: 20}], edges: [], _layoutMode: "elk-client"}
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "a"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "stamp"),
      prepareGraphLayout: vi.fn(async () => graph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      focusClusterNeighborhood: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => ({})),
    }

    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(state.summary.textContent).not.toContain("classes=")
    expect(state.summary.textContent).not.toContain("backbone=EMPTY")
  })
})
