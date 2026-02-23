import {GodViewWasmEngine} from "../../wasm/god_view_exec_runtime"

const BOUND_METHOD_NAMES = [
  "ensureDOM",
  "resizeCanvas",
  "renderGraph",
  "ensureDeck",
  "pollSnapshot",
  "startPolling",
  "stopPolling",
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
    stateRef(this).canvas.addEventListener("wheel", this.handleWheelZoom, {passive: false})
    stateRef(this).canvas.addEventListener("pointerdown", this.handlePanStart)
    window.addEventListener("pointermove", this.handlePanMove)
    window.addEventListener("pointerup", this.handlePanEnd)
    window.addEventListener("pointercancel", this.handlePanEnd)
    this.startAnimationLoop()
  },
  initWasmEngine() {
    GodViewWasmEngine.init()
      .then((engine) => {
        stateRef(this).wasmEngine = engine
        stateRef(this).wasmReady = true
      })
      .catch((_err) => {
        stateRef(this).wasmReady = false
        stateRef(this).wasmEngine = null
      })
  },
}
import {depsRef, stateRef} from "./runtime_refs"
