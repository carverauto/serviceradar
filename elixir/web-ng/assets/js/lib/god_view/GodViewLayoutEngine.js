import {bindApi} from "./api_helpers"
import {godViewLayoutAnimationMethods} from "./layout_animation_methods"
import {godViewLayoutClusterMethods} from "./layout_cluster_methods"
import {godViewLayoutTopologyMethods} from "./layout_topology_methods"

const GOD_VIEW_LAYOUT_CONTEXT_METHODS = Object.assign(
  {},
  godViewLayoutClusterMethods,
  godViewLayoutAnimationMethods,
  godViewLayoutTopologyMethods,
)

export default class GodViewLayoutEngine {
  constructor(context) {
    this.contextApi = bindApi(context, GOD_VIEW_LAYOUT_CONTEXT_METHODS)
  }

  getContextApi() {
    return this.contextApi
  }
}
