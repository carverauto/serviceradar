export const godViewLifecycleBootstrapCleanupRuntimeMethods = {
  cleanupLifecycleRuntime() {
    this.stopAnimationLoop()
    this.stopPolling()
    if (this.channel) {
      this.channel.leave()
      this.channel = null
    }
    if (this.pendingAnimationFrame) {
      cancelAnimationFrame(this.pendingAnimationFrame)
      this.pendingAnimationFrame = null
    }
    if (this.deck) {
      this.deck.finalize()
      this.deck = null
    }
  },
}
