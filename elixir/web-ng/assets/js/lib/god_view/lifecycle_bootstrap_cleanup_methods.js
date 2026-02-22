export const godViewLifecycleBootstrapCleanupMethods = {
  cleanupLifecycle() {
    window.removeEventListener("resize", this.resizeCanvas)
    if (this.canvas) this.canvas.removeEventListener("wheel", this.handleWheelZoom)
    if (this.canvas) this.canvas.removeEventListener("pointerdown", this.handlePanStart)
    window.removeEventListener("pointermove", this.handlePanMove)
    window.removeEventListener("pointerup", this.handlePanEnd)
    window.removeEventListener("pointercancel", this.handlePanEnd)
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
