export const godViewLifecycleBootstrapCleanupRuntimeMethods = {
  cleanupLifecycleRuntime() {
    this.stopAnimationLoop()
    this.clearChannelReconnectTimer?.()
    const layoutTokens = [
      this.state.layoutRequestToken,
      this.state.latestSnapshotLayoutToken,
      this.state.pendingSnapshotLayoutToken,
    ]
      .map((token) => Number(token))
      .filter(Number.isFinite)
    const invalidationToken = Math.max(0, ...layoutTokens) + 1
    this.state.layoutRequestToken = invalidationToken
    this.state.latestSnapshotLayoutToken = invalidationToken
    this.state.pendingSnapshotLayoutToken = null
    this.state.pendingViewportProfileKey = null
    if (this.state.reducedMotionMediaQuery && this.state.reducedMotionListener) {
      try {
        if (typeof this.state.reducedMotionMediaQuery.removeEventListener === "function") {
          this.state.reducedMotionMediaQuery.removeEventListener("change", this.state.reducedMotionListener)
        } else if (typeof this.state.reducedMotionMediaQuery.removeListener === "function") {
          this.state.reducedMotionMediaQuery.removeListener(this.state.reducedMotionListener)
        }
      } catch (_err) {
        // Best effort cleanup for older browser media query implementations.
      }
      this.state.reducedMotionListener = null
      this.state.reducedMotionMediaQuery = null
    }
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
