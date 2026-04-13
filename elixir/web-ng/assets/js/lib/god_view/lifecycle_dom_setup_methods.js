import {Deck, OrthographicView} from "@deck.gl/core"
import {detectThemeMode, visualForTheme, hudStyleForTheme} from "./lifecycle_bootstrap_state_defaults_methods"

export const godViewLifecycleDomSetupMethods = {
  redrawDeckAfterClick() {
    const schedule =
      typeof globalThis !== "undefined" && typeof globalThis.requestAnimationFrame === "function"
        ? globalThis.requestAnimationFrame.bind(globalThis)
        : null

    if (schedule) {
      schedule(() => {
        if (typeof this.state?.deck?.redraw === "function") {
          this.state.deck.redraw(true)
        }
      })
      return
    }

    if (typeof this.state?.deck?.redraw === "function") {
      this.state.deck.redraw(true)
    }
  },
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
      return url
    } catch (_error) {
      return null
    }
  },
  navigateToHref(href) {
    const safeUrl = this.sanitizeNavigationHref(href)
    if (!safeUrl) return
    if (typeof window === "undefined" || !window.location) return
    if (typeof window.location.assign === "function") {
      window.location.assign(safeUrl.href)
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

    const cameraAction = event.target?.closest?.("[data-camera-source-id]")
    if (cameraAction) {
      const cameraSourceId = cameraAction.getAttribute("data-camera-source-id")
      const streamProfileId = cameraAction.getAttribute("data-stream-profile-id")

      if (cameraSourceId && streamProfileId && typeof this.state?.pushEvent === "function") {
        event.preventDefault()
        event.stopPropagation?.()

        this.state.pushEvent("god_view_open_camera_relay", {
          camera_source_id: cameraSourceId,
          stream_profile_id: streamProfileId,
          insecure_skip_verify: cameraAction.getAttribute("data-insecure-skip-verify") === "true",
          device_uid: cameraAction.getAttribute("data-camera-device-uid") || "",
          camera_label: cameraAction.getAttribute("data-camera-label") || "",
          profile_label: cameraAction.getAttribute("data-camera-profile-label") || "",
        })
      }

      return
    }

    const clusterCameraAction = event.target?.closest?.("[data-camera-cluster-tiles]")
    if (clusterCameraAction) {
      const serializedTiles = clusterCameraAction.getAttribute("data-camera-cluster-tiles")

      if (serializedTiles && typeof this.state?.pushEvent === "function") {
        let cameraTiles = []

        try {
          const parsed = JSON.parse(serializedTiles)
          cameraTiles = Array.isArray(parsed) ? parsed : []
        } catch (_error) {
          cameraTiles = []
        }

        if (cameraTiles.length > 0) {
          event.preventDefault()
          event.stopPropagation?.()

          this.state.pushEvent("god_view_open_camera_relay_cluster", {
            cluster_id: clusterCameraAction.getAttribute("data-camera-cluster-id") || "",
            cluster_label: clusterCameraAction.getAttribute("data-camera-cluster-label") || "",
            camera_tiles: cameraTiles,
          })
        }
      }

      return
    }

    const clusterAction = event.target?.closest?.("[data-cluster-id]")
    if (clusterAction) {
      const clusterId = clusterAction.getAttribute("data-cluster-id")
      const nextExpanded = clusterAction.getAttribute("data-cluster-expand") === "true"
      if (clusterId) {
        event.preventDefault()
        event.stopPropagation?.()
        this.setClusterExpanded(clusterId, nextExpanded)
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
  applyTheme() {
    const mode = detectThemeMode()
    this.state.visual = visualForTheme(mode)
    const hudStyle = hudStyleForTheme(mode)

    // Update container background
    if (this.state.el) {
      this.state.el.style.backgroundColor = `rgb(${this.state.visual.bg.slice(0, 3).join(",")})`
    }

    // Update HUD overlays
    if (this.state.summary) this.state.summary.style.cssText = hudStyle
    if (this.state.details) this.state.details.style.cssText = hudStyle

    // Update deck.gl clear color
    if (this.state.deck) {
      this.state.deck.setProps({parameters: {clearColor: this.state.visual.bg}})
    }

    // Bust the particle cache so colors rebuild with new palette
    this.state.packetFlowCache = null
    this.state.packetFlowCacheStamp = null

    // Re-render current graph with new colors
    if (this.state.lastGraph) this.deps.renderGraph(this.state.lastGraph)
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

    const hudStyle = hudStyleForTheme(detectThemeMode())

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
      onClick: (...args) => {
        this.deps.handlePick(...args)
        this.redrawDeckAfterClick()
      },
      onViewStateChange: ({viewState}) => {
        this.state.viewState = viewState
        if (!this.state.isProgrammaticViewUpdate) this.state.userCameraLocked = true
        this.state.isProgrammaticViewUpdate = false
        if (this.state.zoomMode === "auto") {
          const radialOverviewAutoFit = this.state.lastGraph?._layoutMode === "client-radial" && !this.state.userCameraLocked
          const nextTier = radialOverviewAutoFit ? "local" : this.deps.resolveZoomTier(viewState.zoom || 0)
          this.deps.setZoomTier(nextTier, false)
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
