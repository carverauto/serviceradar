import {Deck, OrthographicView} from "@deck.gl/core"

export const godViewLifecycleDomSetupMethods = {
  ensureDOM() {
    if (this.state.canvas && this.state.summary) return

    this.state.el.innerHTML = ""
    this.state.el.classList.add("relative")
    this.state.canvas = document.createElement("canvas")
    this.state.canvas.className = "h-full w-full rounded border border-base-300 bg-neutral"
    this.state.canvas.style.cursor = "grab"

    this.state.summary = document.createElement("div")
    this.state.summary.className =
      "pointer-events-none absolute bottom-2 left-2 rounded bg-base-100/85 px-2 py-1 text-[11px] opacity-90"
    this.state.summary.textContent = "waiting for snapshot..."

    this.state.details = document.createElement("div")
    this.state.details.className =
      "absolute left-2 top-2 z-30 max-w-sm whitespace-pre-line rounded border border-primary/30 bg-base-100/95 px-3 py-2 text-xs shadow-xl hidden"
    this.state.details.textContent = "Select a node for details"
    this.state.details.addEventListener("click", (event) => {
      const action = event.target?.closest?.("[data-node-index]")
      if (!action) return
      const nextIndex = Number(action.getAttribute("data-node-index"))
      if (!Number.isFinite(nextIndex)) return
      event.preventDefault()
      this.deps.focusNodeByIndex(nextIndex, true)
    })
    this.state.el.addEventListener("click", (event) => {
      const action = event.target?.closest?.(".deck-tooltip [data-node-index]")
      if (!action) return
      const nextIndex = Number(action.getAttribute("data-node-index"))
      if (!Number.isFinite(nextIndex)) return
      event.preventDefault()
      event.stopPropagation()
      this.deps.focusNodeByIndex(nextIndex, true)
    })

    this.state.el.appendChild(this.state.canvas)
    this.state.el.appendChild(this.state.summary)
    this.state.el.appendChild(this.state.details)
  },
  resizeCanvas() {
    if (!this.state.canvas) return
    const width = Math.max(320, Math.floor(this.state.el.clientWidth || 0))
    const height = Math.max(260, Math.floor(this.state.el.clientHeight || 0))
    this.state.canvas.style.width = `${width}px`
    this.state.canvas.style.height = `${height}px`
    if (this.state.deck) {
      this.state.deck.setProps({width, height})
      this.state.deck.redraw(true)
    }
  },
  createDeckInstance(width, height) {
    return new Deck({
      canvas: this.state.canvas,
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
      initialViewState: this.state.viewState,
      parameters: {
        clearColor: this.state.visual.bg,
        blend: true,
        blendFunc: [770, 771],
      },
      getTooltip: this.getNodeTooltip,
      onHover: this.handleHover,
      onClick: this.handlePick,
      onViewStateChange: ({viewState}) => {
        this.state.viewState = viewState
        if (!this.state.isProgrammaticViewUpdate) this.state.userCameraLocked = true
        this.state.isProgrammaticViewUpdate = false
        if (this.state.zoomMode === "auto") {
          this.deps.setZoomTier(this.deps.resolveZoomTier(viewState.zoom || 0), false)
        }
      },
    })
  },
  ensureDeck() {
    if (this.state.deck) return
    this.ensureDOM()
    const width = Math.max(320, Math.floor(this.state.el.clientWidth || 0))
    const height = Math.max(260, Math.floor(this.state.el.clientHeight || 0))
    const mode = navigator.gpu ? "webgpu" : "webgl"
    this.state.rendererMode = mode

    try {
      this.state.deck = this.createDeckInstance(width, height)
    } catch (_error) {
      this.state.rendererMode = "webgl-fallback"
      this.state.deck = this.createDeckInstance(width, height)
    }
  },
}
