import {Deck, OrthographicView} from "@deck.gl/core"

export const godViewLifecycleDomSetupMethods = {
  sanitizeNavigationHref(rawHref) {
    if (typeof rawHref !== "string") return null
    const href = rawHref.trim()
    if (href === "") return null
    if (typeof window === "undefined" || !window.location) return null

    try {
      const url = new window.URL(href, window.location.origin)
      const isHttp = url.protocol === "http:" || url.protocol === "https:"
      if (!isHttp) return null
      if (url.origin !== window.location.origin) return null
      return url.pathname + url.search + url.hash
    } catch (_error) {
      return null
    }
  },
  navigateToHref(href) {
    const safeHref = this.sanitizeNavigationHref(href)
    if (!safeHref) return
    if (typeof window !== "undefined" && window.location && typeof window.location.assign === "function") {
      window.location.assign(safeHref)
    }
  },
  handleDetailsPanelClick(event) {
    const deviceLink = event.target?.closest?.("[data-device-href]")
    if (deviceLink) {
      const href = deviceLink.getAttribute("data-device-href")
      if (href) {
        event.preventDefault()
        event.stopPropagation?.()
        this.navigateToHref(href)
      }
      return
    }

    const action = event.target?.closest?.("[data-node-index]")
    if (!action) return
    const nextIndex = Number(action.getAttribute("data-node-index"))
    if (!Number.isFinite(nextIndex)) return
    event.preventDefault()
    this.deps.focusNodeByIndex(nextIndex, true)
  },
  handleTooltipPanelClick(event) {
    const link = event.target?.closest?.(".deck-tooltip a[href]")
    if (link) {
      const href = link.getAttribute("href")
      if (href) {
        event.preventDefault()
        event.stopPropagation?.()
        this.navigateToHref(href)
        return
      }
    }

    const action = event.target?.closest?.(".deck-tooltip [data-node-index]")
    if (!action) return
    const nextIndex = Number(action.getAttribute("data-node-index"))
    if (!Number.isFinite(nextIndex)) return
    event.preventDefault()
    event.stopPropagation()
    this.deps.focusNodeByIndex(nextIndex, true)
  },
  ensureDOM() {
    if (this.state.canvas && this.state.summary) return

    this.state.el.innerHTML = ""
    this.state.el.classList.add("relative", "overflow-hidden")
    this.state.canvas = document.createElement("canvas")
    this.state.canvas.className = "h-full w-full rounded bg-transparent"
    this.state.canvas.style.cursor = "grab"

    this.state.atmosphereOverlay = document.createElement("div")
    this.state.atmosphereOverlay.className = "pointer-events-none absolute inset-0 z-10 rounded"
    this.state.atmosphereOverlay.style.background = "transparent"

    const hudStyle = [
      "font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Inter', sans-serif",
      "color: #e2e8f0",
      "background: rgba(15, 23, 42, 0.75)",
      "backdrop-filter: blur(12px)",
      "-webkit-backdrop-filter: blur(12px)",
      "border: 1px solid rgba(148, 163, 184, 0.15)",
      "box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4)",
      "letter-spacing: 0.2px",
    ].join(";")

    this.state.summary = document.createElement("div")
    this.state.summary.className =
      "pointer-events-none absolute bottom-3 left-3 z-20 rounded-lg px-3 py-2 text-[11px] font-medium"
    this.state.summary.style.cssText = hudStyle
    this.state.summary.textContent = "Waiting for snapshot..."

    this.state.details = document.createElement("div")
    this.state.details.className =
      "pointer-events-auto absolute left-3 top-3 z-30 max-w-sm whitespace-pre-line rounded-lg px-4 py-3 text-xs hidden shadow-xl"
    this.state.details.style.cssText = hudStyle
    this.state.details.style.pointerEvents = "auto"
    this.state.details.addEventListener("pointerdown", (event) => {
      event.stopPropagation?.()
    })
    this.state.details.textContent = "Select a node for details"
    this.state.details.addEventListener("click", (event) => this.handleDetailsPanelClick(event))
    this.state.el.addEventListener("click", (event) => this.handleTooltipPanelClick(event))

    this.state.el.style.backgroundColor = `rgb(${this.state.visual.bg.slice(0, 3).join(",")})`
    this.state.el.appendChild(this.state.canvas)
    this.state.el.appendChild(this.state.summary)
    this.state.el.appendChild(this.state.details)

    this.state.canvas.addEventListener("wheel", this.handleWheelZoom, {passive: false})
    this.state.canvas.addEventListener("pointerdown", this.handlePanStart)
    window.addEventListener("pointermove", this.handlePanMove)
    window.addEventListener("pointerup", this.handlePanEnd)
    window.addEventListener("pointercancel", this.handlePanEnd)
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
      controller: false,
      pickingRadius: 8,
      useDevicePixels: true,
      initialViewState: this.state.viewState,
      parameters: {
        clearColor: this.state.visual.bg,
        blend: true,
        blendFunc: [770, 771],
        depthTest: false,
        depthWrite: false,
      },
      getTooltip: (...args) => this.deps.getNodeTooltip(...args),
      onHover: (...args) => this.deps.handleHover(...args),
      onClick: (...args) => this.deps.handlePick(...args),
      onViewStateChange: ({viewState}) => {
        this.state.viewState = viewState
        if (!this.state.isProgrammaticViewUpdate) this.state.userCameraLocked = true
        this.state.isProgrammaticViewUpdate = false
        if (this.state.zoomMode === "auto") {
          this.deps.setZoomTier(this.deps.resolveZoomTier(viewState.zoom || 0), false)
        }
      },
      onError: (error, layer) => {
        const layerId = String(layer?.id || "")
        if (layerId.includes("god-view-atmosphere-particles")) {
          const now = typeof performance !== "undefined" ? performance.now() : Date.now()
          this.state.atmosphereSuppressUntil = now + 1200
          if (this.state.summary) this.state.summary.textContent = `atmosphere shader fallback: ${String(error)}`
          if (this.state.lastGraph) this.deps.renderGraph(this.state.lastGraph)
          return
        }
        if (this.state.summary) this.state.summary.textContent = `render error: ${String(error)}`
        if (this.state.lastGraph) {
          const now = typeof performance !== "undefined" ? performance.now() : Date.now()
          this.state.atmosphereSuppressUntil = now + 1200
          this.deps.renderGraph(this.state.lastGraph)
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
