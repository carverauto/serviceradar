import {GodViewWasmEngine} from "../../wasm/god_view_exec_runtime"

const BOUND_METHOD_NAMES = [
  "ensureDOM",
  "resizeCanvas",
  "renderGraph",
  "ensureDeck",
  "pollSnapshot",
  "startPolling",
  "stopPolling",
  "visibilityMask",
  "computeTraversalMask",
  "handlePick",
  "animateTransition",
  "parseSnapshotMessage",
  "resolveZoomTier",
  "setZoomTier",
  "reshapeGraph",
  "reclusterByState",
  "reclusterByGrid",
  "clusterEdges",
  "autoFitViewState",
  "ensureBitmapMetadata",
  "buildBitmapFallbackMetadata",
  "startAnimationLoop",
  "stopAnimationLoop",
  "buildPacketFlowInstances",
  "prepareGraphLayout",
  "shouldUseGeoLayout",
  "projectGeoLayout",
  "forceDirectedLayout",
  "renderSelectionDetails",
  "geoGridData",
  "getNodeTooltip",
  "handleHover",
  "handleWheelZoom",
  "handlePanStart",
  "handlePanMove",
  "handlePanEnd",
]

export const godViewLifecycleBootstrapStateMethods = {
  initLifecycleState() {
    this.canvas = null
    this.summary = null
    this.details = null
    this.deck = null
    this.channel = null
    this.rendererMode = "initializing"
    this.filters = {root_cause: true, affected: true, healthy: true, unknown: true}
    this.lastGraph = null
    this.wasmEngine = null
    this.wasmReady = false
    this.selectedNodeIndex = null
    this.hoveredEdgeKey = null
    this.selectedEdgeKey = null
    this.pendingAnimationFrame = null
    this.zoomMode = "local"
    this.zoomTier = "local"
    this.hasAutoFit = false
    this.userCameraLocked = false
    this.dragState = null
    this.isProgrammaticViewUpdate = false
    this.lastSnapshotAt = 0
    this.channelJoined = false
    this.lastVisibleNodeCount = 0
    this.lastVisibleEdgeCount = 0
    this.pollTimer = null
    this.animationTimer = null
    this.animationPhase = 0
    this.layers = {mantle: true, crust: true, atmosphere: true, security: true}
    this.topologyLayers = {backbone: true, inferred: false, endpoints: false}
    this.lastPipelineStats = null
    this.layoutMode = "auto"
    this.layoutRevision = null
    this.lastRevision = null
    this.lastTopologyStamp = null
    this.snapshotUrl = this.el.dataset.url || null
    this.pollIntervalMs = Number.parseInt(this.el.dataset.intervalMs || "5000", 10) || 5000
    this.visual = {
      bg: [10, 10, 10, 255],
      mantleEdge: [42, 42, 42, 170],
      crustArc: [214, 97, 255, 180],
      atmosphereParticle: [0, 224, 255, 185],
      nodeRoot: [255, 64, 64, 255],
      nodeAffected: [255, 162, 50, 255],
      nodeHealthy: [0, 224, 255, 255],
      nodeUnknown: [122, 141, 168, 255],
      label: [226, 232, 240, 230],
      edgeLabel: [148, 163, 184, 220],
      pulse: [255, 64, 64, 220],
    }
    this.viewState = {
      target: [320, 160, 0],
      zoom: 1.4,
      minZoom: -2,
      maxZoom: 5,
    }
  },
  bindLifecycleMethods() {
    for (const name of BOUND_METHOD_NAMES) {
      if (typeof this[name] === "function") this[name] = this[name].bind(this)
    }
  },
  attachLifecycleDom() {
    this.ensureDOM()
    this.resizeCanvas()
    window.addEventListener("resize", this.resizeCanvas)
    this.canvas.addEventListener("wheel", this.handleWheelZoom, {passive: false})
    this.canvas.addEventListener("pointerdown", this.handlePanStart)
    window.addEventListener("pointermove", this.handlePanMove)
    window.addEventListener("pointerup", this.handlePanEnd)
    window.addEventListener("pointercancel", this.handlePanEnd)
    this.startAnimationLoop()
  },
  initWasmEngine() {
    GodViewWasmEngine.init()
      .then((engine) => {
        this.wasmEngine = engine
        this.wasmReady = true
      })
      .catch((_err) => {
        this.wasmReady = false
        this.wasmEngine = null
      })
  },
}
