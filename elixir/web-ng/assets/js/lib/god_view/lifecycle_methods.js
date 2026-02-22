import {Socket} from "phoenix"

import {GodViewWasmEngine} from "../../wasm/god_view_exec_runtime"

import {godViewLifecycleDomMethods} from "./lifecycle_dom_methods"
import {godViewLifecycleStreamMethods} from "./lifecycle_stream_methods"

const godViewLifecycleCoreMethods = {
  mounted() {
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

    this.ensureDOM = this.ensureDOM.bind(this)
    this.resizeCanvas = this.resizeCanvas.bind(this)
    this.renderGraph = this.renderGraph.bind(this)
    this.ensureDeck = this.ensureDeck.bind(this)
    this.pollSnapshot = this.pollSnapshot.bind(this)
    this.startPolling = this.startPolling.bind(this)
    this.stopPolling = this.stopPolling.bind(this)
    this.visibilityMask = this.visibilityMask.bind(this)
    this.computeTraversalMask = this.computeTraversalMask.bind(this)
    this.handlePick = this.handlePick.bind(this)
    this.animateTransition = this.animateTransition.bind(this)
    this.parseSnapshotMessage = this.parseSnapshotMessage.bind(this)
    this.resolveZoomTier = this.resolveZoomTier.bind(this)
    this.setZoomTier = this.setZoomTier.bind(this)
    this.reshapeGraph = this.reshapeGraph.bind(this)
    this.reclusterByState = this.reclusterByState.bind(this)
    this.reclusterByGrid = this.reclusterByGrid.bind(this)
    this.clusterEdges = this.clusterEdges.bind(this)
    this.autoFitViewState = this.autoFitViewState.bind(this)
    this.ensureBitmapMetadata = this.ensureBitmapMetadata.bind(this)
    this.buildBitmapFallbackMetadata = this.buildBitmapFallbackMetadata.bind(this)
    this.startAnimationLoop = this.startAnimationLoop.bind(this)
    this.stopAnimationLoop = this.stopAnimationLoop.bind(this)
    this.buildPacketFlowInstances = this.buildPacketFlowInstances.bind(this)
    this.prepareGraphLayout = this.prepareGraphLayout.bind(this)
    this.shouldUseGeoLayout = this.shouldUseGeoLayout.bind(this)
    this.projectGeoLayout = this.projectGeoLayout.bind(this)
    this.forceDirectedLayout = this.forceDirectedLayout.bind(this)
    this.renderSelectionDetails = this.renderSelectionDetails.bind(this)
    this.geoGridData = this.geoGridData.bind(this)
    this.getNodeTooltip = this.getNodeTooltip.bind(this)
    this.handleHover = this.handleHover.bind(this)
    this.handleWheelZoom = this.handleWheelZoom.bind(this)
    this.handlePanStart = this.handlePanStart.bind(this)
    this.handlePanMove = this.handlePanMove.bind(this)
    this.handlePanEnd = this.handlePanEnd.bind(this)

    this.ensureDOM()
    this.resizeCanvas()
    window.addEventListener("resize", this.resizeCanvas)
    this.canvas.addEventListener("wheel", this.handleWheelZoom, {passive: false})
    this.canvas.addEventListener("pointerdown", this.handlePanStart)
    window.addEventListener("pointermove", this.handlePanMove)
    window.addEventListener("pointerup", this.handlePanEnd)
    window.addEventListener("pointercancel", this.handlePanEnd)
    this.startAnimationLoop()

    GodViewWasmEngine.init()
      .then((engine) => {
        this.wasmEngine = engine
        this.wasmReady = true
      })
      .catch((_err) => {
        this.wasmReady = false
        this.wasmEngine = null
      })

    this.handleEvent("god_view:set_filters", ({filters}) => {
      if (filters && typeof filters === "object") {
        this.filters = {
          root_cause: filters.root_cause !== false,
          affected: filters.affected !== false,
          healthy: filters.healthy !== false,
          unknown: filters.unknown !== false,
        }
        if (this.lastGraph) this.renderGraph(this.lastGraph)
      }
    })

    this.handleEvent("god_view:set_zoom_mode", ({mode}) => {
      const normalized = mode === "global" || mode === "regional" || mode === "local" ? mode : "auto"
      this.zoomMode = normalized

      if (!this.deck) return

      if (normalized === "auto") {
        this.setZoomTier(this.resolveZoomTier(this.viewState.zoom || 0), true)
        return
      }

      const zoomByTier = {global: -0.9, regional: 0.35, local: 1.65}
      this.viewState = {
        ...this.viewState,
        zoom: zoomByTier[normalized] || this.viewState.zoom,
      }
      this.userCameraLocked = true
      this.isProgrammaticViewUpdate = true
      this.deck.setProps({viewState: this.viewState})
      this.setZoomTier(normalized, true)
    })

    this.handleEvent("god_view:set_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        this.layers = {
          mantle: layers.mantle !== false,
          crust: layers.crust !== false,
          atmosphere: layers.atmosphere !== false,
          security: layers.security !== false,
        }
        if (this.lastGraph) this.renderGraph(this.lastGraph)
      }
    })

    this.handleEvent("god_view:set_topology_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        this.topologyLayers = {
          backbone: layers.backbone !== false,
          inferred: layers.inferred === true,
          endpoints: layers.endpoints === true,
        }
        if (this.lastGraph) this.renderGraph(this.lastGraph)
      }
    })

    if (!window.godViewSocket) {
      window.godViewSocket = new Socket("/socket", {params: {_csrf_token: this.csrfToken}})
      window.godViewSocket.connect()
    }

    this.channel = window.godViewSocket.channel("topology:god_view", {})
    this.channel.on("snapshot_meta", (msg) => {
      const stats = msg?.pipeline_stats || msg?.pipelineStats
      if (stats && typeof stats === "object") this.lastPipelineStats = stats
    })
    this.channel.on("snapshot", (msg) => this.handleSnapshot(msg))
    this.channel.on("snapshot_error", (msg) => {
      this.summary.textContent = "snapshot stream error"
      this.pushEvent("god_view_stream_error", {reason: msg?.reason || "snapshot_error"})
      this.pollSnapshot()
    })
    this.channel
      .join()
      .receive("ok", () => {
        this.channelJoined = true
        this.summary.textContent = "topology channel connected"
        this.startPolling()
      })
      .receive("error", (reason) => {
        this.channelJoined = false
        this.summary.textContent = "topology channel failed"
        this.pushEvent("god_view_stream_error", {reason: reason?.reason || "join_failed"})
        this.startPolling(true)
      })
  },

  destroyed() {
    window.removeEventListener("resize", this.resizeCanvas)
    if (this.canvas) this.canvas.removeEventListener("wheel", this.handleWheelZoom)
    if (this.canvas) this.canvas.removeEventListener("pointerdown", this.handlePanStart)
    window.removeEventListener("pointermove", this.handlePanMove)
    window.removeEventListener("pointerup", this.handlePanEnd)
    window.removeEventListener("pointercancel", this.handlePanEnd)
    this.stopAnimationLoop()
    this.stopPolling()
    if (this.channel) {
      this.channel.leave()
      this.channel = null
    }
    if (this.pendingAnimationFrame) {
      cancelAnimationFrame(this.pendingAnimationFrame)
      this.pendingAnimationFrame = null
    }
    if (this.deck) {
      this.deck.finalize()
      this.deck = null
    }
  },
}

export const godViewLifecycleMethods = Object.assign(
  {},
  godViewLifecycleCoreMethods,
  godViewLifecycleDomMethods,
  godViewLifecycleStreamMethods,
)
