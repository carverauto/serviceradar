import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingMethods} from "./rendering_methods"

const RENDERING_STATE_KEYS = [
  "animationPhase",
  "deck",
  "details",
  "el",
  "filters",
  "hasAutoFit",
  "hoveredEdgeKey",
  "isProgrammaticViewUpdate",
  "lastGraph",
  "lastVisibleEdgeCount",
  "lastVisibleNodeCount",
  "layers",
  "selectedEdgeKey",
  "selectedNodeIndex",
  "topologyLayers",
  "userCameraLocked",
  "viewState",
  "visual",
  "wasmEngine",
  "wasmReady",
  "zoomMode",
  "zoomTier",
]

export default class GodViewRenderingEngine {
  constructor({state, deps}) {
    this.runtimeContext = createStateBackedContext(state, deps, RENDERING_STATE_KEYS)
    this.contextApi = bindApi(this.runtimeContext, godViewRenderingMethods)
    Object.assign(this.runtimeContext, this.contextApi)
  }

  getContextApi() {
    return this.contextApi
  }
}
