import {godViewLifecycleBootstrapMethods} from "./lifecycle_bootstrap_methods"
import {godViewLifecycleDomMethods} from "./lifecycle_dom_methods"
import {godViewLifecycleStreamMethods} from "./lifecycle_stream_methods"

const godViewLifecycleCoreMethods = {
  mounted() {
    this.initLifecycleState()
    this.bindLifecycleMethods()
    this.attachLifecycleDom()
    this.initWasmEngine()
    this.registerLifecycleEvents()
    this.setupSnapshotChannel()
  },
  destroyed() {
    this.cleanupLifecycle()
  },
}

export const godViewLifecycleMethods = Object.assign(
  {},
  godViewLifecycleCoreMethods,
  godViewLifecycleBootstrapMethods,
  godViewLifecycleDomMethods,
  godViewLifecycleStreamMethods,
)
import {depsRef, stateRef} from "./runtime_refs"
