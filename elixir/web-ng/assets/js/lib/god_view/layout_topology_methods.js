import {godViewLayoutTopologyAlgorithmMethods} from "./layout_topology_algorithm_methods"
import {godViewLayoutTopologyStateMethods} from "./layout_topology_state_methods"

export const godViewLayoutTopologyMethods = Object.assign(
  {},
  godViewLayoutTopologyStateMethods,
  godViewLayoutTopologyAlgorithmMethods,
)
