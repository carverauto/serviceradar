import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleBootstrapCleanupRuntimeMethods = {
  cleanupLifecycleRuntime() {
    this.stopAnimationLoop()
    this.stopPolling()
    if (stateRef(this).channel) {
      stateRef(this).channel.leave()
      stateRef(this).channel = null
    }
    if (stateRef(this).pendingAnimationFrame) {
      cancelAnimationFrame(stateRef(this).pendingAnimationFrame)
      stateRef(this).pendingAnimationFrame = null
    }
    if (stateRef(this).deck) {
      stateRef(this).deck.finalize()
      stateRef(this).deck = null
    }
  },
}
