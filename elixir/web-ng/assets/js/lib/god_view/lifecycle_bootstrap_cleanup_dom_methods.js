export const godViewLifecycleBootstrapCleanupDomMethods = {
  cleanupLifecycleDomListeners() {
    window.removeEventListener("resize", this.resizeCanvas)
    try { this.state.resizeObserver?.disconnect() } catch (_e) {}
    this.state.resizeObserver = null
    try { this.state.safeAreaMutationObserver?.disconnect() } catch (_e) {}
    this.state.safeAreaMutationObserver = null
    this.state.safeAreaResizeTargets = null
    if (this.state.canvas) this.state.canvas.removeEventListener("wheel", this.handleWheelZoom)
    if (this.state.canvas) this.state.canvas.removeEventListener("pointerdown", this.handlePanStart)
    if (this.state.mapControls) this.state.mapControls.removeEventListener("click", this.handleMapControlClick)
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
