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
  "syncReducedMotionPreference",
  "handleReducedMotionPreferenceChange",
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
    this.startAnimationLoop()
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
