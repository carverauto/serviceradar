import {godViewLifecycleBootstrapRuntimeMethods} from "./lifecycle_bootstrap_runtime_methods"
import {godViewLifecycleBootstrapStateDefaultsMethods} from "./lifecycle_bootstrap_state_defaults_methods"

export const godViewLifecycleBootstrapStateMethods = Object.assign(
  {},
  godViewLifecycleBootstrapStateDefaultsMethods,
  godViewLifecycleBootstrapRuntimeMethods,
)
