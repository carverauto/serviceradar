import {Deck, OrthographicView} from "@deck.gl/core"

export const godViewLifecycleDomSetupMethods = {
  ensureDOM() {
    if (stateRef(this).canvas && stateRef(this).summary) return

    stateRef(this).el.innerHTML = ""
    stateRef(this).el.classList.add("relative")
    stateRef(this).canvas = document.createElement("canvas")
    stateRef(this).canvas.className = "h-full w-full rounded border border-base-300 bg-neutral"
    stateRef(this).canvas.style.cursor = "grab"

    stateRef(this).summary = document.createElement("div")
    stateRef(this).summary.className =
      "pointer-events-none absolute bottom-2 left-2 rounded bg-base-100/85 px-2 py-1 text-[11px] opacity-90"
    stateRef(this).summary.textContent = "waiting for snapshot..."

    stateRef(this).details = document.createElement("div")
    stateRef(this).details.className =
      "absolute left-2 top-2 z-30 max-w-sm whitespace-pre-line rounded border border-primary/30 bg-base-100/95 px-3 py-2 text-xs shadow-xl hidden"
    stateRef(this).details.textContent = "Select a node for details"
    stateRef(this).details.addEventListener("click", (event) => {
      const action = event.target?.closest?.("[data-node-index]")
      if (!action) return
      const nextIndex = Number(action.getAttribute("data-node-index"))
      if (!Number.isFinite(nextIndex)) return
      event.preventDefault()
      depsRef(this).focusNodeByIndex(nextIndex, true)
    })
    stateRef(this).el.addEventListener("click", (event) => {
      const action = event.target?.closest?.(".deck-tooltip [data-node-index]")
      if (!action) return
      const nextIndex = Number(action.getAttribute("data-node-index"))
      if (!Number.isFinite(nextIndex)) return
      event.preventDefault()
      event.stopPropagation()
      depsRef(this).focusNodeByIndex(nextIndex, true)
    })

    stateRef(this).el.appendChild(stateRef(this).canvas)
    stateRef(this).el.appendChild(stateRef(this).summary)
    stateRef(this).el.appendChild(stateRef(this).details)
  },
  resizeCanvas() {
    if (!stateRef(this).canvas) return
    const width = Math.max(320, Math.floor(stateRef(this).el.clientWidth || 0))
    const height = Math.max(260, Math.floor(stateRef(this).el.clientHeight || 0))
    stateRef(this).canvas.style.width = `${width}px`
    stateRef(this).canvas.style.height = `${height}px`
    if (stateRef(this).deck) {
      stateRef(this).deck.setProps({width, height})
      stateRef(this).deck.redraw(true)
    }
  },
  createDeckInstance(width, height) {
    return new Deck({
      canvas: stateRef(this).canvas,
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
      initialViewState: stateRef(this).viewState,
      parameters: {
        clearColor: stateRef(this).visual.bg,
        blend: true,
        blendFunc: [770, 771],
      },
      getTooltip: this.getNodeTooltip,
      onHover: this.handleHover,
      onClick: this.handlePick,
      onViewStateChange: ({viewState}) => {
        stateRef(this).viewState = viewState
        if (!stateRef(this).isProgrammaticViewUpdate) stateRef(this).userCameraLocked = true
        stateRef(this).isProgrammaticViewUpdate = false
        if (stateRef(this).zoomMode === "auto") {
          depsRef(this).setZoomTier(depsRef(this).resolveZoomTier(viewState.zoom || 0), false)
        }
      },
    })
  },
  ensureDeck() {
    if (stateRef(this).deck) return
    this.ensureDOM()
    const width = Math.max(320, Math.floor(stateRef(this).el.clientWidth || 0))
    const height = Math.max(260, Math.floor(stateRef(this).el.clientHeight || 0))
    const mode = navigator.gpu ? "webgpu" : "webgl"
    stateRef(this).rendererMode = mode

    try {
      stateRef(this).deck = this.createDeckInstance(width, height)
    } catch (_error) {
      stateRef(this).rendererMode = "webgl-fallback"
      stateRef(this).deck = this.createDeckInstance(width, height)
    }
  },
}
import {depsRef, stateRef} from "./runtime_refs"
