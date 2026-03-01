export const godViewLifecycleDomInteractionMethods = {
  startAnimationLoop() {
    if (this.state.animationTimer) return
    const tick = () => {
      const motionScale = this.state.prefersReducedMotion ? 0.35 : 1
      this.state.animationPhase = (performance.now() / 1000) * motionScale
      if (this.state.deck && this.state.lastGraph && this.state.packetFlowEnabled) {
        try {
          this.deps.renderGraph(this.state.lastGraph)
        } catch (error) {
          if (this.state.summary) this.state.summary.textContent = `animation render error: ${String(error)}`
        }
      }
      this.state.animationTimer = window.requestAnimationFrame(tick)
    }
    this.state.animationTimer = window.requestAnimationFrame(tick)
  },
  stopAnimationLoop() {
    if (!this.state.animationTimer) return
    window.cancelAnimationFrame(this.state.animationTimer)
    this.state.animationTimer = null
  },
  syncReducedMotionPreference() {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
      this.state.prefersReducedMotion = false
      return
    }

    const mediaQuery = window.matchMedia("(prefers-reduced-motion: reduce)")
    if (this.state.reducedMotionMediaQuery !== mediaQuery && this.state.reducedMotionMediaQuery && this.state.reducedMotionListener) {
      try {
        if (typeof this.state.reducedMotionMediaQuery.removeEventListener === "function") {
          this.state.reducedMotionMediaQuery.removeEventListener("change", this.state.reducedMotionListener)
        } else if (typeof this.state.reducedMotionMediaQuery.removeListener === "function") {
          this.state.reducedMotionMediaQuery.removeListener(this.state.reducedMotionListener)
        }
      } catch (_err) {
        // Best effort cleanup for browser compatibility.
      }
    }

    this.state.reducedMotionMediaQuery = mediaQuery
    if (!this.state.reducedMotionListener) {
      this.state.reducedMotionListener = (event) => this.handleReducedMotionPreferenceChange(event)
    }

    if (typeof mediaQuery.addEventListener === "function") {
      mediaQuery.addEventListener("change", this.state.reducedMotionListener)
    } else if (typeof mediaQuery.addListener === "function") {
      mediaQuery.addListener(this.state.reducedMotionListener)
    }

    this.handleReducedMotionPreferenceChange(mediaQuery)
  },
  handleReducedMotionPreferenceChange(event) {
    const reduced = event?.matches === true
    if (this.state.prefersReducedMotion === reduced) return

    this.state.prefersReducedMotion = reduced
    if (!this.state.animationTimer) this.startAnimationLoop()
  },
  handlePanStart(event) {
    if (!this.state.deck) return
    if (event.button !== 0) return

    this.state.pendingDragState = {
      pointerId: event.pointerId,
      startX: Number(event.clientX || 0),
      startY: Number(event.clientY || 0),
    }
  },
  handlePanMove(event) {
    if (!this.state.deck) return

    if (!this.state.dragState && this.state.pendingDragState) {
      if (event.pointerId !== this.state.pendingDragState.pointerId) return
      const dx = Number(event.clientX || 0) - this.state.pendingDragState.startX
      const dy = Number(event.clientY || 0) - this.state.pendingDragState.startY
      if (Math.hypot(dx, dy) < 4) return

      this.state.dragState = {
        pointerId: this.state.pendingDragState.pointerId,
        lastX: Number(event.clientX || 0),
        lastY: Number(event.clientY || 0),
      }
      this.state.pendingDragState = null
      event.preventDefault()
      this.state.canvas.style.cursor = "grabbing"
      if (typeof this.state.canvas.setPointerCapture === "function") {
        try {
          this.state.canvas.setPointerCapture(event.pointerId)
        } catch (_err) {
          // Ignore capture failures and continue with window listeners.
        }
      }
      return
    }

    if (!this.state.dragState) return
    if (event.pointerId !== this.state.dragState.pointerId) return

    event.preventDefault()
    const clientX = Number(event.clientX || 0)
    const clientY = Number(event.clientY || 0)
    const dx = clientX - this.state.dragState.lastX
    const dy = clientY - this.state.dragState.lastY
    this.state.dragState.lastX = clientX
    this.state.dragState.lastY = clientY

    const zoom = Number(this.state.viewState.zoom || 0)
    const scale = Math.max(0.0001, 2 ** zoom)
    const [targetX = 0, targetY = 0, targetZ = 0] = this.state.viewState.target || [0, 0, 0]

    this.state.viewState = {
      ...this.state.viewState,
      target: [targetX - dx / scale, targetY - dy / scale, targetZ],
    }
    this.state.userCameraLocked = true
    this.state.isProgrammaticViewUpdate = true
    this.state.deck.setProps({viewState: this.state.viewState})
  },
  handlePanEnd(event) {
    if (this.state.pendingDragState) {
      if (!event || event.pointerId === this.state.pendingDragState.pointerId) {
        this.state.pendingDragState = null
      }
    }

    if (!this.state.dragState) return
    if (event && event.pointerId !== this.state.dragState.pointerId) return

    if (this.state.canvas && typeof this.state.canvas.releasePointerCapture === "function") {
      try {
        this.state.canvas.releasePointerCapture(this.state.dragState.pointerId)
      } catch (_err) {
        // Ignore capture release failures.
      }
    }
    this.state.dragState = null
    if (this.state.canvas) {
      const interactive = this.state.hoveredNodeIndex !== null || this.state.hoveredEdgeKey !== null
      this.state.canvas.style.cursor = interactive ? "pointer" : "grab"
    }
  },
  handleWheelZoom(event) {
    if (!this.state.deck) return
    event.preventDefault()

    const delta = Number(event.deltaY || 0)
    const direction = delta > 0 ? -1 : 1
    const zoomStep = 0.12
    const nextZoom = (this.state.viewState.zoom || 0) + direction * zoomStep
    const clamped = Math.max(this.state.viewState.minZoom, Math.min(this.state.viewState.maxZoom, nextZoom))

    this.state.viewState = {...this.state.viewState, zoom: clamped}
    this.state.userCameraLocked = true
    this.state.isProgrammaticViewUpdate = true
    this.state.deck.setProps({viewState: this.state.viewState})
    if (this.state.zoomMode === "auto") {
      this.deps.setZoomTier(this.deps.resolveZoomTier(clamped), true)
    }
  },
}
