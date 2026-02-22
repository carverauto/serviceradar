import {Deck, OrthographicView} from "@deck.gl/core"

export const godViewLifecycleDomSetupMethods = {
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
  createDeckInstance(width, height) {
    return new Deck({
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
  },
  ensureDeck() {
    if (this.deck) return
    this.ensureDOM()
    const width = Math.max(320, Math.floor(this.el.clientWidth || 0))
    const height = Math.max(260, Math.floor(this.el.clientHeight || 0))
    const mode = navigator.gpu ? "webgpu" : "webgl"
    this.rendererMode = mode

    try {
      this.deck = this.createDeckInstance(width, height)
    } catch (_error) {
      this.rendererMode = "webgl-fallback"
      this.deck = this.createDeckInstance(width, height)
    }
  },
}
