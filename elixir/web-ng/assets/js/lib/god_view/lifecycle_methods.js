import {godViewLifecycleBootstrapMethods} from "./lifecycle_bootstrap_methods"
import {godViewLifecycleDomMethods} from "./lifecycle_dom_methods"
import {godViewLifecycleStreamMethods} from "./lifecycle_stream_methods"

const godViewLifecycleCoreMethods = {
  mounted() {
    this.initLifecycleState()
    this.bindLifecycleMethods()
    this.attachLifecycleDom()
    this.initWasmEngine()
    // A bounded detail scene is supplied by its owning world view. It has no
    // whole-graph bootstrap, channel, or independent LiveView event handlers.
    if (this.state.sceneOnly) return
    this.registerLifecycleEvents()
    this.bootstrapLatestSnapshot()
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
