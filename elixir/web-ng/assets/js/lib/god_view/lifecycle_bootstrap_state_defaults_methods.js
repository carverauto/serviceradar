/* Nocturne dark palette — neon accents on slate backgrounds */
const DARK_VISUAL = {
  bg: [15, 23, 42, 255],                   // slate-900 (base-200)
  mantleEdge: [51, 65, 85, 170],           // slate-700
  mantleEdgeBase: [30, 80, 140],           // blue-tinted edge base for alpha blending
  mantleEdgeAlphaBase: 128,                // base alpha for mantle edges
  mantleEdgeAlphaBoost: 32,                // alpha boost from zoom
  crustArc: [0, 216, 255, 180],            // #00D8FF electric cyan (primary)
  atmosphereParticle: [34, 211, 238, 185],  // #22D3EE cyan-400 (accent)
  nodeRoot: [255, 42, 122, 255],           // #FF2A7A neon magenta (error)
  nodeAffected: [255, 154, 0, 255],        // #FF9A00 neon amber (warning)
  nodeHealthy: [0, 230, 118, 255],         // #00E676 neon green (success)
  nodeUnknown: [100, 116, 139, 255],       // slate-500
  nodeFill: [255, 255, 255, 255],          // white center dot
  nodeOperUp: [56, 189, 248, 230],         // sky-400 (cyan)
  nodeOperDown: [120, 113, 108, 220],      // warm gray
  nodeOperUnknown: [100, 116, 139, 220],   // slate-500
  nodeStatusUp: [34, 197, 94, 230],        // green-400
  nodeStatusDown: [239, 68, 68, 230],      // red-400
  nodeStatusUnknown: [148, 163, 184, 220], // slate-400
  geoGrid: [32, 62, 88],                   // dark blue-gray grid lines
  crustLow: [48, 158, 226, 58],           // muted cyan (low utilization)
  crustLowVivid: [56, 210, 255, 88],      // vivid cyan
  crustHigh: [196, 122, 255, 98],         // muted purple (high utilization)
  crustHighVivid: [255, 110, 220, 142],   // vivid magenta
  particleCyan: [73, 231, 255, 255],      // bright cyan particle
  particleMagenta: [244, 114, 255, 255],  // bright magenta particle
  particleBlend: [770, 1, 1, 1],          // additive blending for glow on dark
  label: [244, 244, 245, 240],             // #F4F4F5 zinc-100
  edgeLabel: [148, 163, 184, 220],         // slate-400
  pulse: [255, 42, 122, 220],              // neon magenta
}

/* Nocturne light palette — bold accents on white backgrounds */
const LIGHT_VISUAL = {
  bg: [248, 250, 252, 255],                // #F8FAFC slate-50 (base-200)
  mantleEdge: [203, 213, 225, 170],        // slate-300
  mantleEdgeBase: [56, 152, 220],          // vivid sky-blue edges (clearly visible)
  mantleEdgeAlphaBase: 190,                // strong base alpha for light bg
  mantleEdgeAlphaBoost: 45,                // alpha boost from zoom
  crustArc: [3, 105, 161, 240],            // #0369A1 sky-800 (primary) high alpha
  atmosphereParticle: [2, 132, 165, 240],   // bold cyan-600 near-opaque
  nodeRoot: [220, 38, 38, 255],            // #DC2626 red-600 (error)
  nodeAffected: [217, 119, 6, 255],        // #D97706 amber-600 (warning)
  nodeHealthy: [5, 150, 105, 255],         // #059669 emerald-600 (success)
  nodeUnknown: [100, 116, 139, 255],       // slate-500
  nodeFill: [15, 23, 42, 255],             // dark center dot
  nodeOperUp: [3, 105, 161, 230],          // sky-800 (primary)
  nodeOperDown: [120, 113, 108, 220],      // warm gray
  nodeOperUnknown: [100, 116, 139, 220],   // slate-500
  nodeStatusUp: [5, 150, 105, 230],        // emerald-600
  nodeStatusDown: [220, 38, 38, 230],      // red-600
  nodeStatusUnknown: [100, 116, 139, 220], // slate-500
  geoGrid: [180, 200, 220],               // light blue-gray grid lines
  crustLow: [14, 130, 195, 210],          // sky-700 bold (clearly visible on light)
  crustLowVivid: [3, 115, 185, 245],      // sky-800 near-opaque
  crustHigh: [130, 40, 220, 235],         // rich purple bold
  crustHighVivid: [147, 51, 234, 250],    // purple-600 near-opaque
  particleCyan: [0, 150, 220, 255],       // bold sky-blue at full alpha
  particleMagenta: [147, 30, 210, 255],   // bold purple at full alpha
  particleBlend: [770, 771],              // standard alpha blending for light bg
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
  const hasDocument = typeof document !== "undefined" && document?.documentElement
  if (hasDocument) {
    const explicit = document.documentElement.getAttribute("data-theme")
    if (explicit === "dark") return "dark"
    if (explicit === "light") return "light"
  }

  const prefersDark =
    typeof window !== "undefined" &&
    window?.matchMedia?.("(prefers-color-scheme: dark)")?.matches

  return prefersDark ? "dark" : "light"
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
    this.state.snapshotBootstrapPromise = null
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
    this.state.layoutCache = new Map()
    this.state.lastLayoutKey = null
    this.state.layoutRequestToken = 0
    this.state.lastRevision = null
    this.state.lastTopologyStamp = null
    this.state.pendingClusterFocus = null
    this.state.visual = visualForTheme(detectThemeMode())
    this.state.viewState = {
      target: [320, 160, 0],
      zoom: 1.4,
      minZoom: -2,
      maxZoom: 5,
    }
  },
}
