import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleMethods} from "./lifecycle_methods"

const LIFECYCLE_STATE_KEYS = [
  "el",
  "pushEvent",
  "handleEvent",
  "csrfToken",
  "animationPhase",
  "animationTimer",
  "canvas",
  "channel",
  "channelJoined",
  "deck",
  "details",
  "dragState",
  "filters",
  "hasAutoFit",
  "hoveredEdgeKey",
  "isProgrammaticViewUpdate",
  "lastGraph",
  "lastPipelineStats",
  "lastRevision",
  "lastSnapshotAt",
  "lastTopologyStamp",
  "lastVisibleEdgeCount",
  "lastVisibleNodeCount",
  "layers",
  "layoutMode",
  "layoutRevision",
  "pendingAnimationFrame",
  "pollIntervalMs",
  "pollTimer",
  "rendererMode",
  "selectedEdgeKey",
  "selectedNodeIndex",
  "snapshotUrl",
  "summary",
  "topologyLayers",
  "userCameraLocked",
  "viewState",
  "visual",
  "wasmEngine",
  "wasmReady",
  "zoomMode",
  "zoomTier",
]

export default class GodViewLifecycleController {
  constructor({state, deps}) {
    this.runtimeContext = createStateBackedContext(state, deps, LIFECYCLE_STATE_KEYS)
    this.contextApi = bindApi(this.runtimeContext, godViewLifecycleMethods)
    Object.assign(this.runtimeContext, this.contextApi)
  }

  getContextApi() {
    return this.contextApi
  }

  mount() {
    if (typeof this.contextApi.mounted === "function") this.contextApi.mounted()
  }

  destroy() {
    if (typeof this.contextApi.destroyed === "function") this.contextApi.destroyed()
  }
}
