import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleDomInteractionMethods = {
  startAnimationLoop() {
    if (stateRef(this).animationTimer) return
    const tick = () => {
      stateRef(this).animationPhase = performance.now() / 1000
      if (stateRef(this).deck && stateRef(this).lastGraph) {
        try {
          depsRef(this).renderGraph(stateRef(this).lastGraph)
        } catch (error) {
          if (stateRef(this).summary) stateRef(this).summary.textContent = `animation render error: ${String(error)}`
        }
      }
      stateRef(this).animationTimer = window.requestAnimationFrame(tick)
    }
    stateRef(this).animationTimer = window.requestAnimationFrame(tick)
  },
  stopAnimationLoop() {
    if (!stateRef(this).animationTimer) return
    window.cancelAnimationFrame(stateRef(this).animationTimer)
    stateRef(this).animationTimer = null
  },
  handlePanStart(event) {
    if (!stateRef(this).deck) return
    if (event.button !== 0) return

    event.preventDefault()
    stateRef(this).dragState = {
      pointerId: event.pointerId,
      lastX: Number(event.clientX || 0),
      lastY: Number(event.clientY || 0),
    }
    stateRef(this).canvas.style.cursor = "grabbing"
    if (typeof stateRef(this).canvas.setPointerCapture === "function") {
      try {
        stateRef(this).canvas.setPointerCapture(event.pointerId)
      } catch (_err) {
        // Ignore capture failures and continue with window listeners.
      }
    }
  },
  handlePanMove(event) {
    if (!stateRef(this).deck || !stateRef(this).dragState) return
    if (event.pointerId !== stateRef(this).dragState.pointerId) return

    event.preventDefault()
    const clientX = Number(event.clientX || 0)
    const clientY = Number(event.clientY || 0)
    const dx = clientX - stateRef(this).dragState.lastX
    const dy = clientY - stateRef(this).dragState.lastY
    stateRef(this).dragState.lastX = clientX
    stateRef(this).dragState.lastY = clientY

    const zoom = Number(stateRef(this).viewState.zoom || 0)
    const scale = Math.max(0.0001, 2 ** zoom)
    const [targetX = 0, targetY = 0, targetZ = 0] = stateRef(this).viewState.target || [0, 0, 0]

    stateRef(this).viewState = {
      ...stateRef(this).viewState,
      target: [targetX - dx / scale, targetY - dy / scale, targetZ],
    }
    stateRef(this).userCameraLocked = true
    stateRef(this).isProgrammaticViewUpdate = true
    stateRef(this).deck.setProps({viewState: stateRef(this).viewState})
  },
  handlePanEnd(event) {
    if (!stateRef(this).dragState) return
    if (event && event.pointerId !== stateRef(this).dragState.pointerId) return

    if (stateRef(this).canvas && typeof stateRef(this).canvas.releasePointerCapture === "function") {
      try {
        stateRef(this).canvas.releasePointerCapture(stateRef(this).dragState.pointerId)
      } catch (_err) {
        // Ignore capture release failures.
      }
    }
    stateRef(this).dragState = null
    if (stateRef(this).canvas) stateRef(this).canvas.style.cursor = "grab"
  },
  handleWheelZoom(event) {
    if (!stateRef(this).deck) return
    event.preventDefault()

    const delta = Number(event.deltaY || 0)
    const direction = delta > 0 ? -1 : 1
    const zoomStep = 0.12
    const nextZoom = (stateRef(this).viewState.zoom || 0) + direction * zoomStep
    const clamped = Math.max(stateRef(this).viewState.minZoom, Math.min(stateRef(this).viewState.maxZoom, nextZoom))

    stateRef(this).viewState = {...stateRef(this).viewState, zoom: clamped}
    stateRef(this).userCameraLocked = true
    stateRef(this).isProgrammaticViewUpdate = true
    stateRef(this).deck.setProps({viewState: stateRef(this).viewState})
    if (stateRef(this).zoomMode === "auto") {
      depsRef(this).setZoomTier(depsRef(this).resolveZoomTier(clamped), true)
    }
  },
}
