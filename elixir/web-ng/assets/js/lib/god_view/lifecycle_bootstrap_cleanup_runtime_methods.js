export const godViewLifecycleBootstrapCleanupRuntimeMethods = {
  cleanupLifecycleRuntime() {
    this.stopAnimationLoop()
    this.stopPolling()
    if (this.state.channel) {
      this.state.channel.leave()
      this.state.channel = null
    }
    if (this.state.pendingAnimationFrame) {
      cancelAnimationFrame(this.state.pendingAnimationFrame)
      this.state.pendingAnimationFrame = null
    }
    if (this.state.deck) {
      this.state.deck.finalize()
      this.state.deck = null
    }
  },
}
