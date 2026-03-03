/* Nocturne dark palette — neon accents on slate backgrounds */
const DARK_VISUAL = {
  bg: [15, 23, 42, 255],                   // slate-900 (base-200)
  mantleEdge: [51, 65, 85, 170],           // slate-700
  crustArc: [0, 216, 255, 180],            // #00D8FF electric cyan (primary)
  atmosphereParticle: [34, 211, 238, 185],  // #22D3EE cyan-400 (accent)
  nodeRoot: [255, 42, 122, 255],           // #FF2A7A neon magenta (error)
  nodeAffected: [255, 154, 0, 255],        // #FF9A00 neon amber (warning)
  nodeHealthy: [0, 230, 118, 255],         // #00E676 neon green (success)
  nodeUnknown: [100, 116, 139, 255],       // slate-500
  label: [244, 244, 245, 240],             // #F4F4F5 zinc-100
  edgeLabel: [148, 163, 184, 220],         // slate-400
  pulse: [255, 42, 122, 220],              // neon magenta
}

/* Nocturne light palette — muted accents on white backgrounds */
const LIGHT_VISUAL = {
  bg: [248, 250, 252, 255],                // #F8FAFC slate-50 (base-200)
  mantleEdge: [203, 213, 225, 170],        // slate-300
  crustArc: [3, 105, 161, 180],            // #0369A1 sky-800 (primary)
  atmosphereParticle: [8, 145, 178, 160],   // #0891B2 cyan-600 (accent)
  nodeRoot: [220, 38, 38, 255],            // #DC2626 red-600 (error)
  nodeAffected: [217, 119, 6, 255],        // #D97706 amber-600 (warning)
  nodeHealthy: [5, 150, 105, 255],         // #059669 emerald-600 (success)
  nodeUnknown: [100, 116, 139, 255],       // slate-500
  label: [15, 23, 42, 240],               // #0F172A slate-900 (base-content)
  edgeLabel: [71, 85, 105, 220],           // slate-600
  pulse: [220, 38, 38, 220],              // red-600
}

const DARK_HUD_STYLE = [
  "font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Inter', sans-serif",
  "color: #F4F4F5",
  "background: rgba(19, 19, 22, 0.85)",
  "backdrop-filter: blur(12px)",
  "-webkit-backdrop-filter: blur(12px)",
  "border: 1px solid rgba(39, 39, 42, 0.4)",
  "box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4)",
  "letter-spacing: 0.2px",
].join(";")

const LIGHT_HUD_STYLE = [
  "font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Inter', sans-serif",
  "color: #0F172A",
  "background: rgba(255, 255, 255, 0.85)",
  "backdrop-filter: blur(12px)",
  "-webkit-backdrop-filter: blur(12px)",
  "border: 1px solid rgba(226, 232, 240, 0.6)",
  "box-shadow: 0 8px 32px rgba(0, 0, 0, 0.08)",
  "letter-spacing: 0.2px",
].join(";")

export function detectThemeMode() {
  const explicit = document.documentElement.getAttribute("data-theme")
  if (explicit === "dark") return "dark"
  if (explicit === "light") return "light"
  return window.matchMedia?.("(prefers-color-scheme: dark)")?.matches ? "dark" : "light"
}

export function visualForTheme(mode) {
  return mode === "dark" ? {...DARK_VISUAL} : {...LIGHT_VISUAL}
}

export function hudStyleForTheme(mode) {
  return mode === "dark" ? DARK_HUD_STYLE : LIGHT_HUD_STYLE
}

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
    this.state.themeObserver = null
    this.state.themeMediaQuery = null
    this.state.themeMediaListener = null
    this.state.layers = {mantle: true, crust: true, atmosphere: true, security: true}
    this.state.topologyLayers = {backbone: true, inferred: false, endpoints: false, mtr_paths: true}
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
    this.state.visual = visualForTheme(detectThemeMode())
    this.state.viewState = {
      target: [320, 160, 0],
      zoom: 1.4,
      minZoom: -2,
      maxZoom: 5,
    }
  },
}
