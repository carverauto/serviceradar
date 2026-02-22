export const godViewLifecycleBootstrapCleanupDomMethods = {
  cleanupLifecycleDomListeners() {
    window.removeEventListener("resize", this.resizeCanvas)
    if (this.canvas) this.canvas.removeEventListener("wheel", this.handleWheelZoom)
    if (this.canvas) this.canvas.removeEventListener("pointerdown", this.handlePanStart)
    window.removeEventListener("pointermove", this.handlePanMove)
    window.removeEventListener("pointerup", this.handlePanEnd)
    window.removeEventListener("pointercancel", this.handlePanEnd)
  },
}
