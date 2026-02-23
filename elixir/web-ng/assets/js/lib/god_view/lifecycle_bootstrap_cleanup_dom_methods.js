import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleBootstrapCleanupDomMethods = {
  cleanupLifecycleDomListeners() {
    window.removeEventListener("resize", this.resizeCanvas)
    if (stateRef(this).canvas) stateRef(this).canvas.removeEventListener("wheel", this.handleWheelZoom)
    if (stateRef(this).canvas) stateRef(this).canvas.removeEventListener("pointerdown", this.handlePanStart)
    window.removeEventListener("pointermove", this.handlePanMove)
    window.removeEventListener("pointerup", this.handlePanEnd)
    window.removeEventListener("pointercancel", this.handlePanEnd)
  },
}
