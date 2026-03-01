import {godViewLifecycleDomInteractionMethods} from "./lifecycle_dom_interaction_methods"
import {godViewLifecycleDomSetupMethods} from "./lifecycle_dom_setup_methods"

export const godViewLifecycleDomMethods = Object.assign(
  {},
  godViewLifecycleDomInteractionMethods,
  godViewLifecycleDomSetupMethods,
)
