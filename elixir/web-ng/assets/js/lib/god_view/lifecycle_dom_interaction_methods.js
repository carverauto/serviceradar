import {canvasPoint, focalZoomViewState, panViewState, wheelZoomDelta} from "./deck_camera_controls"
import {runRecoverableManagedCameraUpdate} from "./lifecycle_managed_camera_recovery"
import {hasManagedTopologyScene} from "./topology_layout_mode"

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
  applyDeckViewState(
    viewState,
    {userLocked = true, syncZoomTier = true, recoverManaged = true} = {},
  ) {
    if (!this.state.deck || !viewState) return false

    const layoutMode = this.state.lastGraph?._layoutMode
    const managedScene = hasManagedTopologyScene(this.state.lastGraph)
    const applyViewState = () => {
      let nextViewState = viewState
      if (managedScene) {
        // Same graph, camera-only move: carry the density the fit selected, or a stepped-down
        // selection is discarded here and the glyphs snap back to overview extents.
        const selection = this.deps.managedViewStateForCamera(
          this.state.lastGraph,
          {...this.state.viewState, ...viewState},
          {fittedManagedVisualDensity: this.state.managedTopologyVisualDensity},
        )
        nextViewState = selection.viewState
        this.state.managedTopologyVisualDensity = selection.managedVisualDensity
      }

      this.state.viewState = nextViewState
      this.state.userCameraLocked = userLocked
      this.state.isProgrammaticViewUpdate = true
      this.state.deck.setProps({viewState: this.state.viewState})

      if (syncZoomTier && this.state.zoomMode === "auto") {
        if (managedScene) {
          this.state.zoomTier = "local"
        } else {
          const nextTier = layoutMode === "client-radial" ? "local" : this.deps.resolveZoomTier(this.state.viewState.zoom || 0)
          this.deps.setZoomTier(nextTier, false)
        }
      }

      this.deps.refreshGraphLayersForViewState()
      return nextViewState
    }

    if (managedScene && recoverManaged) {
      return runRecoverableManagedCameraUpdate(this, applyViewState).ok
    }
    applyViewState()
    return true
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

    this.applyDeckViewState(panViewState(this.state.viewState, dx, dy))
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
    event.stopPropagation?.()

    const point = canvasPoint(event, this.state.canvas)
    const nextZoom = (this.state.viewState.zoom || 0) + wheelZoomDelta(event)
    this.applyDeckViewState(focalZoomViewState(this.state.viewState, point, nextZoom))
  },
  zoomDeckCamera(delta, event = null) {
    if (!this.state.deck) return

    const rect = this.state.canvas?.getBoundingClientRect?.()
    const centerEvent = rect
      ? {clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2}
      : null
    const point = canvasPoint(event || centerEvent, this.state.canvas)
    const nextZoom = (this.state.viewState.zoom || 0) + delta
    this.applyDeckViewState(focalZoomViewState(this.state.viewState, point, nextZoom))
  },
  resetViewCamera({collapseExpanded = true} = {}) {
    if (!this.state.deck) return false

    const resetCamera = () => {
      this.state.userCameraLocked = false
      this.state.hasAutoFit = false

      const hasExpandedClusters = Array.isArray(this.state.lastGraph?.nodes)
        && this.state.lastGraph.nodes.some((node) => node?.details?.cluster_expanded === true)

      if (collapseExpanded && hasExpandedClusters && typeof this.collapseAllClusters === "function") {
        this.collapseAllClusters()
        return
      }

      this.deps.autoFitViewState(this.state.lastGraph)
    }

    const managedScene = hasManagedTopologyScene(this.state.lastGraph)
    if (managedScene) return runRecoverableManagedCameraUpdate(this, resetCamera).ok
    resetCamera()
    return true
  },
  handleMapControlClick(event) {
    const action = event.target?.closest?.("[data-god-view-map-action]")?.getAttribute("data-god-view-map-action")
    if (!action) return

    event.preventDefault()
    event.stopPropagation?.()

    if (action === "zoom-in") this.zoomDeckCamera(0.35)
    if (action === "zoom-out") this.zoomDeckCamera(-0.35)
    if (action === "fit") this.resetViewCamera({collapseExpanded: false})
    if (action === "reset") this.resetViewCamera({collapseExpanded: true})
  },
}
