import {Deck, OrthographicView} from "@deck.gl/core"

export const godViewLifecycleDomMethods = {
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
  ensureDOM() {
    if (this.canvas && this.summary) return

    this.el.innerHTML = ""
    this.el.classList.add("relative")
    this.canvas = document.createElement("canvas")
    this.canvas.className = "h-full w-full rounded border border-base-300 bg-neutral"
    this.canvas.style.cursor = "grab"

    this.summary = document.createElement("div")
    this.summary.className =
      "pointer-events-none absolute bottom-2 left-2 rounded bg-base-100/85 px-2 py-1 text-[11px] opacity-90"
    this.summary.textContent = "waiting for snapshot..."

    this.details = document.createElement("div")
    this.details.className =
      "absolute left-2 top-2 z-30 max-w-sm whitespace-pre-line rounded border border-primary/30 bg-base-100/95 px-3 py-2 text-xs shadow-xl hidden"
    this.details.textContent = "Select a node for details"
    this.details.addEventListener("click", (event) => {
      const action = event.target?.closest?.("[data-node-index]")
      if (!action) return
      const nextIndex = Number(action.getAttribute("data-node-index"))
      if (!Number.isFinite(nextIndex)) return
      event.preventDefault()
      this.focusNodeByIndex(nextIndex, true)
    })
    this.el.addEventListener("click", (event) => {
      const action = event.target?.closest?.(".deck-tooltip [data-node-index]")
      if (!action) return
      const nextIndex = Number(action.getAttribute("data-node-index"))
      if (!Number.isFinite(nextIndex)) return
      event.preventDefault()
      event.stopPropagation()
      this.focusNodeByIndex(nextIndex, true)
    })

    this.el.appendChild(this.canvas)
    this.el.appendChild(this.summary)
    this.el.appendChild(this.details)
  },
  resizeCanvas() {
    if (!this.canvas) return
    const width = Math.max(320, Math.floor(this.el.clientWidth || 0))
    const height = Math.max(260, Math.floor(this.el.clientHeight || 0))
    this.canvas.style.width = `${width}px`
    this.canvas.style.height = `${height}px`
    if (this.deck) {
      this.deck.setProps({width, height})
      this.deck.redraw(true)
    }
  },
  ensureDeck() {
    if (this.deck) return
    this.ensureDOM()
    const width = Math.max(320, Math.floor(this.el.clientWidth || 0))
    const height = Math.max(260, Math.floor(this.el.clientHeight || 0))
    const mode = navigator.gpu ? "webgpu" : "webgl"
    this.rendererMode = mode

    try {
      this.deck = new Deck({
        canvas: this.canvas,
        width,
        height,
        views: new OrthographicView({id: "god-view-ortho"}),
        controller: {
          dragPan: true,
          dragRotate: false,
          scrollZoom: true,
          doubleClickZoom: false,
          touchZoom: true,
          touchRotate: false,
          keyboard: false,
        },
        useDevicePixels: true,
        initialViewState: this.viewState,
        parameters: {
          clearColor: this.visual.bg,
          blend: true,
          blendFunc: [770, 771],
        },
        getTooltip: this.getNodeTooltip,
        onHover: this.handleHover,
        onClick: this.handlePick,
        onViewStateChange: ({viewState}) => {
          this.viewState = viewState
          if (!this.isProgrammaticViewUpdate) this.userCameraLocked = true
          this.isProgrammaticViewUpdate = false
          if (this.zoomMode === "auto") {
            this.setZoomTier(this.resolveZoomTier(viewState.zoom || 0), false)
          }
        },
      })
    } catch (_error) {
      this.rendererMode = "webgl-fallback"
      this.deck = new Deck({
        canvas: this.canvas,
        width,
        height,
        views: new OrthographicView({id: "god-view-ortho"}),
        controller: {
          dragPan: true,
          dragRotate: false,
          scrollZoom: true,
          doubleClickZoom: false,
          touchZoom: true,
          touchRotate: false,
          keyboard: false,
        },
        useDevicePixels: true,
        initialViewState: this.viewState,
        parameters: {
          clearColor: this.visual.bg,
          blend: true,
          blendFunc: [770, 771],
        },
        getTooltip: this.getNodeTooltip,
        onHover: this.handleHover,
        onClick: this.handlePick,
        onViewStateChange: ({viewState}) => {
          this.viewState = viewState
          if (!this.isProgrammaticViewUpdate) this.userCameraLocked = true
          this.isProgrammaticViewUpdate = false
          if (this.zoomMode === "auto") {
            this.setZoomTier(this.resolveZoomTier(viewState.zoom || 0), false)
          }
        },
      })
    }
  },
}
