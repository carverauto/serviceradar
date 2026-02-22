export const godViewLifecycleDomInteractionMethods = {
  startAnimationLoop() {
    if (this.animationTimer) return
    const tick = () => {
      this.animationPhase = performance.now() / 1000
      if (this.deck && this.lastGraph) {
        try {
          this.renderGraph(this.lastGraph)
        } catch (error) {
          if (this.summary) this.summary.textContent = `animation render error: ${String(error)}`
        }
      }
      this.animationTimer = window.requestAnimationFrame(tick)
    }
    this.animationTimer = window.requestAnimationFrame(tick)
  },
  stopAnimationLoop() {
    if (!this.animationTimer) return
    window.cancelAnimationFrame(this.animationTimer)
    this.animationTimer = null
  },
  handlePanStart(event) {
    if (!this.deck) return
    if (event.button !== 0) return

    event.preventDefault()
    this.dragState = {
      pointerId: event.pointerId,
      lastX: Number(event.clientX || 0),
      lastY: Number(event.clientY || 0),
    }
    this.canvas.style.cursor = "grabbing"
    if (typeof this.canvas.setPointerCapture === "function") {
      try {
        this.canvas.setPointerCapture(event.pointerId)
      } catch (_err) {
        // Ignore capture failures and continue with window listeners.
      }
    }
  },
  handlePanMove(event) {
    if (!this.deck || !this.dragState) return
    if (event.pointerId !== this.dragState.pointerId) return

    event.preventDefault()
    const clientX = Number(event.clientX || 0)
    const clientY = Number(event.clientY || 0)
    const dx = clientX - this.dragState.lastX
    const dy = clientY - this.dragState.lastY
    this.dragState.lastX = clientX
    this.dragState.lastY = clientY

    const zoom = Number(this.viewState.zoom || 0)
    const scale = Math.max(0.0001, 2 ** zoom)
    const [targetX = 0, targetY = 0, targetZ = 0] = this.viewState.target || [0, 0, 0]

    this.viewState = {
      ...this.viewState,
      target: [targetX - dx / scale, targetY - dy / scale, targetZ],
    }
    this.userCameraLocked = true
    this.isProgrammaticViewUpdate = true
    this.deck.setProps({viewState: this.viewState})
  },
  handlePanEnd(event) {
    if (!this.dragState) return
    if (event && event.pointerId !== this.dragState.pointerId) return

    if (this.canvas && typeof this.canvas.releasePointerCapture === "function") {
      try {
        this.canvas.releasePointerCapture(this.dragState.pointerId)
      } catch (_err) {
        // Ignore capture release failures.
      }
    }
    this.dragState = null
    if (this.canvas) this.canvas.style.cursor = "grab"
  },
  handleWheelZoom(event) {
    if (!this.deck) return
    event.preventDefault()

    const delta = Number(event.deltaY || 0)
    const direction = delta > 0 ? -1 : 1
    const zoomStep = 0.12
    const nextZoom = (this.viewState.zoom || 0) + direction * zoomStep
    const clamped = Math.max(this.viewState.minZoom, Math.min(this.viewState.maxZoom, nextZoom))

    this.viewState = {...this.viewState, zoom: clamped}
    this.userCameraLocked = true
    this.isProgrammaticViewUpdate = true
    this.deck.setProps({viewState: this.viewState})
    if (this.zoomMode === "auto") {
      this.setZoomTier(this.resolveZoomTier(clamped), true)
    }
  },
}
