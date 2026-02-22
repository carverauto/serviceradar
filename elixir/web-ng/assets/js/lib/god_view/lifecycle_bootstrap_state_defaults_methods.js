export const godViewLifecycleBootstrapStateDefaultsMethods = {
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
}
