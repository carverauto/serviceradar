import {godViewLifecycleBootstrapCleanupDomMethods} from "./lifecycle_bootstrap_cleanup_dom_methods"
import {godViewLifecycleBootstrapCleanupRuntimeMethods} from "./lifecycle_bootstrap_cleanup_runtime_methods"

const godViewLifecycleBootstrapCleanupCoreMethods = {
  cleanupLifecycle() {
    this.cleanupLifecycleDomListeners()
    this.cleanupLifecycleRuntime()
  },
}

export const godViewLifecycleBootstrapCleanupMethods = Object.assign(
  {},
  godViewLifecycleBootstrapCleanupCoreMethods,
  godViewLifecycleBootstrapCleanupDomMethods,
  godViewLifecycleBootstrapCleanupRuntimeMethods,
)
