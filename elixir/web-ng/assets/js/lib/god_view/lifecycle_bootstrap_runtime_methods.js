import {GodViewWasmEngine} from "../../wasm/god_view_exec_runtime"

const BOUND_METHOD_NAMES = [
  "ensureDOM",
  "resizeCanvas",
  "renderGraph",
  "ensureDeck",
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
  "bootstrapLatestSnapshot",
  "renderSelectionDetails",
  "geoGridData",
  "getNodeTooltip",
  "handleHover",
  "handleWheelZoom",
  "handlePanStart",
  "handlePanMove",
  "handlePanEnd",
  "syncReducedMotionPreference",
  "handleReducedMotionPreferenceChange",
  "applyTheme",
]

export const godViewLifecycleBootstrapRuntimeMethods = {
  bindLifecycleMethods() {
    for (const name of BOUND_METHOD_NAMES) {
      if (typeof this[name] === "function") this[name] = this[name].bind(this)
    }
  },
  attachLifecycleDom() {
    this.ensureDOM()
    this.resizeCanvas()
    window.addEventListener("resize", this.resizeCanvas)
    this.syncReducedMotionPreference()
    this.setupThemeWatcher()
    this.startAnimationLoop()
  },
  setupThemeWatcher() {
    // Watch data-theme attribute changes (user toggles theme)
    this.state.themeObserver = new MutationObserver(() => this.applyTheme())
    this.state.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })

    // Watch system color-scheme preference changes
    this.state.themeMediaQuery = window.matchMedia?.("(prefers-color-scheme: dark)") || null
    this.state.themeMediaListener = () => this.applyTheme()
    if (this.state.themeMediaQuery?.addEventListener) {
      this.state.themeMediaQuery.addEventListener("change", this.state.themeMediaListener)
    }
  },
  initWasmEngine() {
    GodViewWasmEngine.init()
      .then((engine) => {
        this.state.wasmEngine = engine
        this.state.wasmReady = true
      })
      .catch((_err) => {
        this.state.wasmReady = false
        this.state.wasmEngine = null
      })
  },
}
