export const godViewLifecycleBootstrapCleanupDomMethods = {
  cleanupLifecycleDomListeners() {
    window.removeEventListener("resize", this.resizeCanvas)
    if (this.state.canvas) this.state.canvas.removeEventListener("wheel", this.handleWheelZoom)
    if (this.state.canvas) this.state.canvas.removeEventListener("pointerdown", this.handlePanStart)
    window.removeEventListener("pointermove", this.handlePanMove)
    window.removeEventListener("pointerup", this.handlePanEnd)
    window.removeEventListener("pointercancel", this.handlePanEnd)

    // Theme watchers
    try { this.state.themeObserver?.disconnect() } catch (_e) {}
    try {
      if (this.state.themeMediaQuery?.removeEventListener && this.state.themeMediaListener) {
        this.state.themeMediaQuery.removeEventListener("change", this.state.themeMediaListener)
      }
    } catch (_e) {}
    this.state.themeObserver = null
    this.state.themeMediaQuery = null
    this.state.themeMediaListener = null
  },
}
