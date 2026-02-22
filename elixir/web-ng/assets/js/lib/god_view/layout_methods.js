import {godViewLayoutAnimationMethods} from "./layout_animation_methods"
import {godViewLayoutClusterMethods} from "./layout_cluster_methods"
import {godViewLayoutTopologyMethods} from "./layout_topology_methods"

export const godViewLayoutMethods = Object.assign(
  {},
  godViewLayoutClusterMethods,
  godViewLayoutAnimationMethods,
  godViewLayoutTopologyMethods,
)
