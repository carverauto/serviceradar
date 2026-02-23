import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleBootstrapStateDefaultsMethods = {
  initLifecycleState() {
    stateRef(this).canvas = null
    stateRef(this).summary = null
    stateRef(this).details = null
    stateRef(this).deck = null
    stateRef(this).channel = null
    stateRef(this).rendererMode = "initializing"
    stateRef(this).filters = {root_cause: true, affected: true, healthy: true, unknown: true}
    stateRef(this).lastGraph = null
    stateRef(this).wasmEngine = null
    stateRef(this).wasmReady = false
    stateRef(this).selectedNodeIndex = null
    stateRef(this).hoveredEdgeKey = null
    stateRef(this).selectedEdgeKey = null
    stateRef(this).pendingAnimationFrame = null
    stateRef(this).zoomMode = "local"
    stateRef(this).zoomTier = "local"
    stateRef(this).hasAutoFit = false
    stateRef(this).userCameraLocked = false
    stateRef(this).dragState = null
    stateRef(this).isProgrammaticViewUpdate = false
    stateRef(this).lastSnapshotAt = 0
    stateRef(this).channelJoined = false
    stateRef(this).lastVisibleNodeCount = 0
    stateRef(this).lastVisibleEdgeCount = 0
    stateRef(this).pollTimer = null
    stateRef(this).animationTimer = null
    stateRef(this).animationPhase = 0
    stateRef(this).layers = {mantle: true, crust: true, atmosphere: true, security: true}
    stateRef(this).topologyLayers = {backbone: true, inferred: false, endpoints: false}
    stateRef(this).lastPipelineStats = null
    stateRef(this).layoutMode = "auto"
    stateRef(this).layoutRevision = null
    stateRef(this).lastRevision = null
    stateRef(this).lastTopologyStamp = null
    stateRef(this).snapshotUrl = stateRef(this).el.dataset.url || null
    stateRef(this).pollIntervalMs = Number.parseInt(stateRef(this).el.dataset.intervalMs || "5000", 10) || 5000
    stateRef(this).visual = {
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
    stateRef(this).viewState = {
      target: [320, 160, 0],
      zoom: 1.4,
      minZoom: -2,
      maxZoom: 5,
    }
  },
}
