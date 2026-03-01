export const godViewLifecycleBootstrapCleanupDomMethods = {
  cleanupLifecycleDomListeners() {
    window.removeEventListener("resize", this.resizeCanvas)
    if (this.state.canvas) this.state.canvas.removeEventListener("wheel", this.handleWheelZoom)
    if (this.state.canvas) this.state.canvas.removeEventListener("pointerdown", this.handlePanStart)
    window.removeEventListener("pointermove", this.handlePanMove)
    window.removeEventListener("pointerup", this.handlePanEnd)
    window.removeEventListener("pointercancel", this.handlePanEnd)
  },
}
