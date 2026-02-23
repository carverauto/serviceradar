export const godViewLifecycleBootstrapStateDefaultsMethods = {
  initLifecycleState() {
    this.state.canvas = null
    this.state.summary = null
    this.state.details = null
    this.state.deck = null
    this.state.channel = null
    this.state.rendererMode = "initializing"
    this.state.filters = {root_cause: true, affected: true, healthy: true, unknown: true}
    this.state.lastGraph = null
    this.state.wasmEngine = null
    this.state.wasmReady = false
    this.state.selectedNodeIndex = null
    this.state.hoveredEdgeKey = null
    this.state.selectedEdgeKey = null
    this.state.pendingAnimationFrame = null
    this.state.zoomMode = "local"
    this.state.zoomTier = "local"
    this.state.hasAutoFit = false
    this.state.userCameraLocked = false
    this.state.dragState = null
    this.state.isProgrammaticViewUpdate = false
    this.state.lastSnapshotAt = 0
    this.state.channelJoined = false
    this.state.lastVisibleNodeCount = 0
    this.state.lastVisibleEdgeCount = 0
    this.state.pollTimer = null
    this.state.animationTimer = null
    this.state.animationPhase = 0
    this.state.layers = {mantle: true, crust: true, atmosphere: true, security: true}
    this.state.topologyLayers = {backbone: true, inferred: false, endpoints: false}
    this.state.lastPipelineStats = null
    this.state.layoutMode = "auto"
    this.state.layoutRevision = null
    this.state.lastRevision = null
    this.state.lastTopologyStamp = null
    this.state.snapshotUrl = this.state.el.dataset.url || null
    this.state.pollIntervalMs = Number.parseInt(this.state.el.dataset.intervalMs || "5000", 10) || 5000
    this.state.visual = {
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
    this.state.viewState = {
      target: [320, 160, 0],
      zoom: 1.4,
      minZoom: -2,
      maxZoom: 5,
    }
  },
}
