/* Brand dark palette — green accents on teal-slate canvas (marketing parity) */
const DARK_VISUAL = {
  bg: [10, 17, 20, 255],                   // #0a1114 --sr-color-canvas
  mantleEdge: [38, 54, 58, 170],           // #26363a --sr-color-line
  mantleEdgeBase: [11, 130, 77],           // brand green edge base for alpha blending
  mantleEdgeAlphaBase: 128,                // base alpha for mantle edges
  mantleEdgeAlphaBoost: 32,                // alpha boost from zoom
  crustArc: [62, 207, 135, 180],           // #3ecf87 brand green (primary)
  atmosphereParticle: [91, 222, 155, 185], // #5bde9b brand green strong
  nodeRoot: [255, 42, 122, 255],           // #FF2A7A neon magenta (error)
  nodeAffected: [255, 154, 0, 255],        // #FF9A00 neon amber (warning)
  nodeHealthy: [0, 230, 118, 255],         // #00E676 neon green (success)
  nodeUnknown: [107, 127, 120, 255],       // muted teal-gray
  nodeFill: [255, 255, 255, 255],          // white center dot
  nodeOperUp: [62, 207, 135, 230],         // brand green
  nodeOperDown: [120, 113, 108, 220],      // warm gray
  nodeOperUnknown: [107, 127, 120, 220],   // muted teal-gray
  nodeStatusUp: [34, 197, 94, 230],        // green-400
  nodeStatusDown: [239, 68, 68, 230],      // red-400
  nodeStatusUnknown: [143, 163, 154, 220], // muted brand
  geoGrid: [22, 34, 38],                   // teal-slate grid lines
  crustLow: [11, 130, 77, 72],             // muted brand green (low utilization)
  crustLowVivid: [62, 207, 135, 110],      // vivid brand green
  crustHigh: [196, 122, 255, 98],          // muted purple (high utilization)
  crustHighVivid: [255, 110, 220, 142],    // vivid magenta
  particleCyan: [116, 223, 166, 255],      // bright brand particle (was cyan)
  particleMagenta: [244, 114, 255, 255],   // bright magenta particle
  particleBlend: [770, 1, 1, 1],           // additive blending for glow on dark
  label: [237, 245, 241, 240],             // #edf5f1 --sr-color-ink
  edgeLabel: [170, 184, 178, 220],         // #aab8b2 --sr-color-muted
  pulse: [255, 42, 122, 220],              // neon magenta
}

/* Brand light palette — green accents on marketing canvas */
const LIGHT_VISUAL = {
  bg: [247, 249, 248, 255],                // #f7f9f8 --sr-color-canvas
  mantleEdge: [200, 211, 206, 170],        // #c8d3ce --sr-color-line-strong
  mantleEdgeBase: [11, 130, 77],           // brand green edges
  mantleEdgeAlphaBase: 190,                // strong base alpha for light bg
  mantleEdgeAlphaBoost: 45,                // alpha boost from zoom
  crustArc: [11, 130, 77, 240],            // #0b824d brand green high alpha
  atmosphereParticle: [7, 107, 62, 245],   // brand-strong particle for light maps
  nodeRoot: [220, 38, 38, 255],            // #DC2626 red-600 (error)
  nodeAffected: [217, 119, 6, 255],        // #D97706 amber-600 (warning)
  nodeHealthy: [5, 150, 105, 255],         // #059669 emerald-600 (success)
  nodeUnknown: [93, 105, 119, 255],        // muted
  nodeFill: [11, 23, 32, 255],             // #0b1720 dark center
  nodeOperUp: [11, 130, 77, 230],          // brand green
  nodeOperDown: [120, 113, 108, 220],      // warm gray
  nodeOperUnknown: [93, 105, 119, 220],    // muted
  nodeStatusUp: [5, 150, 105, 230],        // emerald-600
  nodeStatusDown: [220, 38, 38, 230],      // red-600
  nodeStatusUnknown: [93, 105, 119, 220],  // muted
  geoGrid: [200, 211, 206],                // light brand line grid
  crustLow: [11, 130, 77, 210],            // brand green bold
  crustLowVivid: [7, 107, 62, 245],        // brand-strong near-opaque
  crustHigh: [130, 40, 220, 235],          // rich purple bold
  crustHighVivid: [147, 51, 234, 250],     // purple-600 near-opaque
  particleCyan: [7, 107, 62, 255],         // brand-strong particle on light edges
  particleMagenta: [88, 28, 135, 255],     // dark purple particle on light edges
  particleBlend: [770, 771],               // standard alpha blending for light bg
  label: [11, 23, 32, 240],                // #0b1720 --sr-color-ink
  edgeLabel: [93, 105, 119, 220],          // #5d6977 --sr-color-muted
  pulse: [220, 38, 38, 220],               // red-600
}

const DARK_HUD_STYLE = [
  "font-family: 'Avenir Next', Avenir, 'Segoe UI Variable', 'Segoe UI', ui-sans-serif, system-ui, sans-serif",
  "color: #edf5f1",
  "background: rgba(16, 25, 29, 0.92)",
  "backdrop-filter: blur(12px)",
  "-webkit-backdrop-filter: blur(12px)",
  "border: 1px solid rgba(38, 54, 58, 0.85)",
  "box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4)",
  "letter-spacing: 0.2px",
].join(";")

const LIGHT_HUD_STYLE = [
  "font-family: 'Avenir Next', Avenir, 'Segoe UI Variable', 'Segoe UI', ui-sans-serif, system-ui, sans-serif",
  "color: #0b1720",
  "background: rgba(252, 253, 253, 0.92)",
  "backdrop-filter: blur(12px)",
  "-webkit-backdrop-filter: blur(12px)",
  "border: 1px solid rgba(200, 211, 206, 0.9)",
  "box-shadow: 0 8px 32px rgba(23, 48, 38, 0.08)",
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
    this.state.mapControls = null
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
    // `endpoints` carries the attachment plane. Only 8 of 240 devices in a
    // typical fleet have a backbone adjacency, so defaulting it off filtered
    // every attachment edge out of first paint and drew infrastructure that
    // genuinely has links -- APs, gateways -- as isolated dots. Expanding a
    // cluster then flipped it on as a side effect, which read as "clicking a
    // census bubble invented new edges". Default it on so an attachment edge
    // between two visible glyphs always draws; collapsed cluster members stay
    // hidden, so this does not reintroduce the endpoint hairball.
    this.state.topologyLayers = {backbone: true, inferred: false, endpoints: true, mtr_paths: true}
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
    this.state.viewportWidth = 1280
    this.state.viewportHeight = 720
    this.state.viewportSafeInsets = {top: 0, right: 0, bottom: 0, left: 0}
    this.state.lastRevision = null
    this.state.lastTopologyStamp = null
    this.state.pendingClusterFocus = null
    this.state.managedTopologyCameraBaseMinZoom = -2
    this.state.managedTopologySceneMinZoom = null
    this.state.managedTopologySceneMinZoomKey = null
    this.state.managedTopologySceneForMinZoom = null
    this.state.managedTopologyCameraErrorActive = false
    this.state.managedTopologyCameraErrorPreviousSummary = null
    this.state.visual = visualForTheme(detectThemeMode())
    this.state.viewState = {
      target: [320, 160, 0],
      zoom: 1.4,
      minZoom: -2,
      maxZoom: 5,
    }
  },
}
