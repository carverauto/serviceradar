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
    this.state.channelReconnectTimer = null
    this.state.channelReconnectAttempt = 0
    this.state.channelReconnectBaseMs = 1000
    this.state.channelReconnectMaxMs = 10000
    this.state.lastVisibleNodeCount = 0
    this.state.lastVisibleEdgeCount = 0
    this.state.animationTimer = null
    this.state.animationPhase = 0
    this.state.lastReducedMotionFrameAt = 0
    this.state.prefersReducedMotion = false
    this.state.reducedMotionMediaQuery = null
    this.state.reducedMotionListener = null
    this.state.layers = {mantle: true, crust: true, atmosphere: true, security: true}
    this.state.topologyLayers = {backbone: true, inferred: false, endpoints: false, mtr_paths: false}
    this.state.mtrPathData = []
    this.state.lastPipelineStats = null
    this.state.packetFlowCache = null
    this.state.packetFlowCacheStamp = null
    this.state.packetFlowEnabled = true
    this.state.packetFlowShaderEnabled = true
    this.state.atmosphereSuppressUntil = 0
    this.state.visibilityMaskBuffer = null
    this.state.traversalMaskBuffer = null
    this.state.layoutMode = "auto"
    this.state.layoutRevision = null
    this.state.lastRevision = null
    this.state.lastTopologyStamp = null
    this.state.visual = {
      bg: [20, 28, 42, 255],
      mantleEdge: [42, 42, 42, 170],
      crustArc: [147, 197, 253, 180],
      atmosphereParticle: [56, 189, 248, 185],
      nodeRoot: [248, 113, 113, 255],
      nodeAffected: [251, 146, 60, 255],
      nodeHealthy: [56, 189, 248, 255],
      nodeUnknown: [100, 116, 139, 255],
      label: [241, 245, 249, 240],
      edgeLabel: [148, 163, 184, 220],
      pulse: [239, 68, 68, 220],
    }
    this.state.viewState = {
      target: [320, 160, 0],
      zoom: 1.4,
      minZoom: -2,
      maxZoom: 5,
    }
  },
}
