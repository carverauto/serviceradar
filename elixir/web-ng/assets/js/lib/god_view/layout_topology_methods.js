import {godViewLayoutTopologyStateMethods} from "./layout_topology_state_methods"
import {godViewLayoutTopologyAlgorithmMethods} from "./layout_topology_algorithm_methods"

export const godViewLayoutTopologyMethods = Object.assign(
  {},
  godViewLayoutTopologyStateMethods,
  godViewLayoutTopologyAlgorithmMethods,
)
