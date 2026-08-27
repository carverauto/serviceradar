import {Deck, OrthographicView} from "@deck.gl/core"
import {viewportProfileForSize} from "./layout_elk_scene"
import {detectThemeMode, visualForTheme, hudStyleForTheme} from "./lifecycle_bootstrap_state_defaults_methods"
import {
  godViewSafeAreaElements,
  godViewSafeAreaRoot,
  measureGodViewSafeRect,
} from "./rendering_scene_view"
import {
  runRecoverableManagedCameraUpdate,
  surfaceRecoverableManagedTopologyError,
} from "./lifecycle_managed_camera_recovery"
import {hasManagedTopologyScene} from "./topology_layout_mode"

/**
 * Adopts a resized canvas into Deck's own viewport before anything reads it back.
 *
 * Deck caches the canvas size that every viewport it hands out is built from, and refreshes
 * that cache only from its own animation frame. `setProps({width, height})` rewrites the
 * canvas CSS and then re-sends the PREVIOUS cached size to the view manager, so between a
 * resize and the next frame `deck.getViewports()` -- and the frame `redraw(true)` draws --
 * still describe the old viewport. Everything downstream of a resize projects through that
 * viewport: the label admission that decides which labels fit, the layer refresh, and the
 * acceptance geometry observer. Comparing projections taken in the old frame against the safe
 * rect measured in the new one is how a scene that fits exactly reports glyphs 560px outside
 * it -- half the width difference between the two frames.
 *
 * Deck's refresh is idempotent and reads the size straight off the canvas we just sized, so
 * pulling it forward costs nothing and leaves no frame drawn at the wrong size. It is internal
 * API, so a Deck that no longer exposes it degrades to the old behaviour (one stale frame)
 * rather than failing: the fallback still corrects the view manager, even though Deck's next
 * `setProps` re-asserts its own cached size over it.
 */
function adoptDeckViewportSize(deck, width, height) {
  if (typeof deck?._updateCanvasSize === "function") {
    deck._updateCanvasSize()
    if (Number(deck.width) === width && Number(deck.height) === height) return true
  }
  if (typeof deck?.viewManager?.setProps === "function") {
    deck.viewManager.setProps({width, height})
    return true
  }
  return false
}

function safeInsetsChanged(previous, current) {
  if (!previous) return true
  return ["left", "top", "right", "bottom"].some((edge) => {
    const previousValue = Number(previous?.[edge])
    return !Number.isFinite(previousValue) || Math.abs(previousValue - current[edge]) > 0.5
  })
}

function reconcileSafeAreaResizeTargets(state) {
  const previousTargets = state.safeAreaResizeTargets instanceof Set
    ? state.safeAreaResizeTargets
    : new Set()
  const nextTargets = new Set(
    godViewSafeAreaElements(state.el).filter((element) => element && element !== state.el),
  )

  for (const element of previousTargets) {
    if (!nextTargets.has(element)) state.resizeObserver?.unobserve?.(element)
  }
  for (const element of nextTargets) {
    if (!previousTargets.has(element)) state.resizeObserver?.observe?.(element)
  }

  const changed =
    previousTargets.size !== nextTargets.size ||
    [...previousTargets].some((element) => !nextTargets.has(element))
  state.safeAreaResizeTargets = nextTargets
  return changed
}

function refreshLayersAfterResize(context, {clearErrorOnSuccess = true} = {}) {
  const refresh = () => context.deps.refreshGraphLayersForViewState?.()
  const managedScene = hasManagedTopologyScene(context.state.lastGraph)
  if (managedScene) {
    return runRecoverableManagedCameraUpdate(context, refresh, {clearErrorOnSuccess})
  }
  return {ok: true, value: refresh()}
}

function captureTopologyRenderState(state) {
  return {
    values: {
      hasAutoFit: state.hasAutoFit,
      hoveredEdgeKey: state.hoveredEdgeKey,
      isProgrammaticViewUpdate: state.isProgrammaticViewUpdate,
      lastDetailsHtml: state.lastDetailsHtml,
      lastGraph: state.lastGraph,
      lastGraphLayerFrame: state.lastGraphLayerFrame,
      lastLayoutKey: state.lastLayoutKey,
      lastVisibleEdgeCount: state.lastVisibleEdgeCount,
      lastVisibleNodeCount: state.lastVisibleNodeCount,
      layoutMode: state.layoutMode,
      layoutRevision: state.layoutRevision,
      managedTopologyDensityConstraintsCache: state.managedTopologyDensityConstraintsCache,
      managedTopologyDensityConstraintsLayoutCache: state.managedTopologyDensityConstraintsLayoutCache,
      managedTopologySceneForMinZoom: state.managedTopologySceneForMinZoom,
      managedTopologySceneMinZoom: state.managedTopologySceneMinZoom,
      managedTopologySceneMinZoomKey: state.managedTopologySceneMinZoomKey,
      managedTopologyVisualDensity: state.managedTopologyVisualDensity,
      packetFlowCache: state.packetFlowCache,
      packetFlowCacheStamp: state.packetFlowCacheStamp,
      pendingClusterFocus: state.pendingClusterFocus,
      pendingViewportProfileKey: state.pendingViewportProfileKey,
      selectedEdgeKey: state.selectedEdgeKey,
      topologyLabelDetailsFallbackIds: state.topologyLabelDetailsFallbackIds,
      topologyRouteDiagnostics: state.topologyRouteDiagnostics,
      viewState: state.viewState,
      viewportProfileKey: state.viewportProfileKey,
      wasmReady: state.wasmReady,
      zoomTier: state.zoomTier,
    },
    layersAtmosphere: state.layers?.atmosphere,
    traversalMaskBuffer: state.traversalMaskBuffer,
    traversalMaskContents: state.traversalMaskBuffer?.slice?.(),
    visibilityMaskBuffer: state.visibilityMaskBuffer,
    visibilityMaskContents: state.visibilityMaskBuffer?.slice?.(),
  }
}

function restoreTopologyRenderState(state, captured) {
  Object.assign(state, captured.values)
  if (state.layers && captured.layersAtmosphere !== undefined) {
    state.layers.atmosphere = captured.layersAtmosphere
  }
  if (captured.traversalMaskBuffer && captured.traversalMaskContents) {
    captured.traversalMaskBuffer.set(captured.traversalMaskContents)
  }
  if (captured.visibilityMaskBuffer && captured.visibilityMaskContents) {
    captured.visibilityMaskBuffer.set(captured.visibilityMaskContents)
  }
  state.traversalMaskBuffer = captured.traversalMaskBuffer
  state.visibilityMaskBuffer = captured.visibilityMaskBuffer
}

function restoreLastGoodRender(context, captured) {
  restoreTopologyRenderState(context.state, captured)
  try {
    if (captured.values.lastGraph) context.deps.renderGraph?.(captured.values.lastGraph)
  } catch (_restoreError) {
    // Preserve the original render failure; the accepted state is restored below.
  }
  restoreTopologyRenderState(context.state, captured)
  try {
    if (captured.values.viewState) {
      context.state.deck?.setProps?.({viewState: captured.values.viewState})
    }
  } catch (_restoreError) {
    // A failed best-effort camera restore must not replace the original error.
  }
  restoreTopologyRenderState(context.state, captured)
}

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
    const closeAction = event.target?.closest?.("[data-close-details]")
    if (closeAction) {
      event.preventDefault()
      event.stopPropagation?.()
      if (typeof this.deps?.handlePick === "function") {
        this.deps.handlePick({picked: false, object: null, index: -1, layer: null})
      }
      return
    }

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

    const labelMeasurementCanvas = document.createElement("canvas")
    const labelMeasurementContext = labelMeasurementCanvas.getContext?.("2d")
    this.state.topologyLabelMeasureText = labelMeasurementContext
      ? (text, candidate = {}) => {
          const requestedFontSize = Number(candidate?.fontSize)
          const fontSize = Number.isFinite(requestedFontSize) && requestedFontSize > 0
            ? requestedFontSize
            : 12
          labelMeasurementContext.font = `600 ${fontSize}px Inter, system-ui, sans-serif`
          return labelMeasurementContext.measureText(String(text || ""))
        }
      : null

    this.state.atmosphereOverlay = document.createElement("div")
    this.state.atmosphereOverlay.className = "pointer-events-none absolute inset-0 z-10 rounded"
    this.state.atmosphereOverlay.style.background = "transparent"

    const hudStyle = hudStyleForTheme(detectThemeMode())

    this.state.summary = document.createElement("div")
    this.state.summary.className =
      "pointer-events-none absolute bottom-3 left-3 z-20 rounded-lg px-3 py-2 text-[11px] font-medium"
    this.state.summary.style.cssText = hudStyle
    this.state.summary.setAttribute("data-god-view-safe-area", "status")
    this.state.summary.textContent = "Waiting for snapshot..."

    this.state.details = document.createElement("div")
    this.state.details.className =
      "pointer-events-auto absolute left-3 top-3 z-30 max-w-sm whitespace-pre-line rounded-lg px-4 py-3 text-xs hidden shadow-xl"
    this.state.details.setAttribute("data-god-view-safe-area", "left")
    this.state.details.style.cssText = hudStyle
    this.state.details.style.pointerEvents = "auto"
    this.state.details.addEventListener("pointerdown", (event) => {
      event.stopPropagation?.()
    })
    this.state.details.textContent = "Select a node for details"
    this.state.details.addEventListener("click", (event) => this.handleDetailsPanelClick(event))
    this.state.el.addEventListener("click", (event) => this.handleTooltipPanelClick(event))

    this.state.mapControls = document.createElement("div")
    this.state.mapControls.className = "sr-god-view-map-controls"
    this.state.mapControls.setAttribute("data-god-view-safe-area", "controls")
    this.state.mapControls.innerHTML = `
      <button type="button" class="sr-ops-map-control-button" data-god-view-map-action="zoom-in" aria-label="Zoom in">+</button>
      <button type="button" class="sr-ops-map-control-button" data-god-view-map-action="zoom-out" aria-label="Zoom out">-</button>
      <button type="button" class="sr-ops-map-control-button" data-god-view-map-action="fit" aria-label="Fit topology">Fit</button>
      <button type="button" class="sr-ops-map-control-button" data-god-view-map-action="reset" aria-label="Reset topology view">Reset</button>
    `
    this.state.mapControls.addEventListener("click", this.handleMapControlClick)
    this.state.mapControls.addEventListener("pointerdown", (event) => event.stopPropagation?.())

    this.state.el.style.backgroundColor = `rgb(${this.state.visual.bg.slice(0, 3).join(",")})`
    this.state.el.appendChild(this.state.canvas)
    this.state.el.appendChild(this.state.summary)
    this.state.el.appendChild(this.state.details)
    this.state.el.appendChild(this.state.mapControls)

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
    const previousWidth = Number(this.state.viewportWidth)
    const previousHeight = Number(this.state.viewportHeight)
    const previousSafeInsets = this.state.viewportSafeInsets
    const previousProfileKey = this.state.pendingViewportProfileKey || this.state.viewportProfileKey
    const safeRect = measureGodViewSafeRect(this.state.el)
    const safeInsets = {
      left: safeRect.left,
      top: safeRect.top,
      right: Math.max(0, width - safeRect.right),
      bottom: Math.max(0, height - safeRect.bottom),
    }
    const profile = viewportProfileForSize(width, height, safeInsets)
    const sizeChanged = width !== previousWidth || height !== previousHeight
    const safeAreaChanged = safeInsetsChanged(previousSafeInsets, safeInsets)

    if (!previousProfileKey) this.state.viewportProfileKey = profile.key

    this.state.viewportWidth = width
    this.state.viewportHeight = height
    this.state.viewportSafeInsets = safeInsets
    this.state.topologyLabelSafeRect = safeRect
    this.state.canvas.style.width = `${width}px`
    this.state.canvas.style.height = `${height}px`
    if (this.state.deck) {
      this.state.deck.setProps({width, height})
      adoptDeckViewportSize(this.state.deck, width, height)
      this.state.deck.redraw(true)
    }

    if ((!sizeChanged && !safeAreaChanged) || !this.state.lastGraph) return
    if (previousProfileKey && previousProfileKey !== profile.key) {
      this.state.pendingViewportProfileKey = profile.key
      void this.requestTopologyProfileLayout(this.state.lastGraph, profile.key)
      refreshLayersAfterResize(this, {clearErrorOnSuccess: false})
      return
    }

    if (this.state.pendingViewportProfileKey === profile.key) {
      refreshLayersAfterResize(this, {clearErrorOnSuccess: false})
      return
    }

    let cameraUpdateAccepted = true
    if (!this.state.userCameraLocked) {
      const result = runRecoverableManagedCameraUpdate(this, () => {
        this.deps.autoFitViewState?.(this.state.lastGraph, {force: true})
      })
      cameraUpdateAccepted = result.ok
    } else if (hasManagedTopologyScene(this.state.lastGraph)) {
      const result = runRecoverableManagedCameraUpdate(this, () => {
        const selection = this.deps.managedViewStateForCamera?.(
          this.state.lastGraph,
          this.state.viewState,
          {safeRect, fittedManagedVisualDensity: this.state.managedTopologyVisualDensity},
        )
        if (selection?.managedVisualDensity) {
          this.state.managedTopologyVisualDensity = selection.managedVisualDensity
        }
      })
      cameraUpdateAccepted = result.ok
    }
    refreshLayersAfterResize(this, {clearErrorOnSuccess: cameraUpdateAccepted})
  },
  async requestTopologyProfileLayout(graph, profileKey = null) {
    if (typeof this.deps.prepareGraphLayout !== "function") return false
    const requestToken = Number(this.state.layoutRequestToken || 0) + 1
    this.state.layoutRequestToken = requestToken
    const snapshotToken = this.state.latestSnapshotLayoutToken
    const revision = this.state.lastRevision
    const topologyStamp = this.state.lastTopologyStamp
    try {
      const laidOut = await this.deps.prepareGraphLayout(
        graph,
        revision,
        topologyStamp,
        {commit: false},
      )
      const current =
        requestToken === this.state.layoutRequestToken &&
        snapshotToken === this.state.latestSnapshotLayoutToken &&
        !this.state.pendingSnapshotLayoutToken &&
        this.state.lastGraph === graph
      if (!current || !laidOut) return false
      const unrecoverableLayoutError =
        laidOut?._layoutMode === "elk-scene-error" ||
        (laidOut?._layoutError && !laidOut?._topologyScene)
      if (unrecoverableLayoutError) {
        const message = `${laidOut?._layoutError || "ELK layout unavailable"}`
        this.state.pendingViewportProfileKey = null
        surfaceRecoverableManagedTopologyError(this, message, {
          errorReason: "layout_error",
          errorSummary: "topology layout unavailable",
        })
        return false
      }
      const previousAcceptanceState = captureTopologyRenderState(this.state)
      const renderResult = runRecoverableManagedCameraUpdate(this, () => {
        this.state.layoutMode = laidOut._layoutMode
        this.state.layoutRevision = revision
        this.state.lastLayoutKey = laidOut._layoutCacheKey ?? null
        this.state.viewportProfileKey = profileKey || laidOut._topologyScene?.profileKey || this.state.viewportProfileKey
        this.state.pendingViewportProfileKey = null
        this.state.lastGraph = laidOut
        if (!this.state.userCameraLocked) this.state.hasAutoFit = false
        this.deps.renderGraph?.(laidOut)
      })
      if (!renderResult.ok) {
        restoreLastGoodRender(this, previousAcceptanceState)
        this.state.pendingViewportProfileKey = null
        return false
      }
      return true
    } catch (error) {
      if (
        requestToken !== this.state.layoutRequestToken ||
        snapshotToken !== this.state.latestSnapshotLayoutToken ||
        this.state.pendingSnapshotLayoutToken ||
        this.state.lastGraph !== graph
      ) return false
      this.state.pendingViewportProfileKey = null
      surfaceRecoverableManagedTopologyError(this, error, {
        errorReason: "layout_error",
        errorSummary: `layout resize failed: ${String(error)}`,
      })
      return false
    }
  },
  observeTopologyContainer() {
    if (!this.state.el) return

    this.state.resizeObserver?.disconnect?.()
    this.state.safeAreaMutationObserver?.disconnect?.()
    this.state.resizeObserver = null
    this.state.safeAreaMutationObserver = null
    this.state.safeAreaResizeTargets = null

    if (typeof globalThis.ResizeObserver === "function") {
      this.state.resizeObserver = new globalThis.ResizeObserver(() => this.resizeCanvas())
      this.state.resizeObserver.observe(this.state.el)
    } else {
      window.addEventListener("resize", this.resizeCanvas)
    }

    reconcileSafeAreaResizeTargets(this.state)

    if (typeof globalThis.MutationObserver === "function") {
      this.state.safeAreaMutationObserver = new globalThis.MutationObserver((records) => {
        const targetsChanged = reconcileSafeAreaResizeTargets(this.state)
        const safeAreaAttributeChanged = (records || []).some((record) =>
          record?.type === "attributes" && this.state.safeAreaResizeTargets?.has(record.target),
        )
        if (targetsChanged || safeAreaAttributeChanged) this.resizeCanvas()
      })
      this.state.safeAreaMutationObserver.observe(godViewSafeAreaRoot(this.state.el), {
        attributes: true,
        attributeFilter: ["data-god-view-safe-area", "class"],
        childList: true,
        subtree: true,
      })
    }
  },
  createDeckInstance(width, height) {
    return new Deck({
      canvas: this.state.canvas,
      width,
      height,
      views: new OrthographicView({id: "god-view-ortho"}),
      // Managed scenes own geometry, not the camera. Gestures are allowed
      // and then clamped by onViewStateChange via managedViewStateForCamera,
      // so trackpad pinch / two-finger zoom and drag-pan work without letting
      // the user desync the accepted ELK scene. Rotation stays off: the scene
      // is authored in an OrthographicView with a fixed up-axis.
      controller: {
        scrollZoom: {smooth: true},
        dragPan: true,
        touchZoom: true,
        dragRotate: false,
        touchRotate: false,
        doubleClickZoom: false,
        keyboard: false,
      },
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
        const programmaticUpdate = this.state.isProgrammaticViewUpdate === true
        const layoutMode = this.state.lastGraph?._layoutMode
        const managedScene = hasManagedTopologyScene(this.state.lastGraph)
        const applyViewState = () => {
          let nextViewState = {...this.state.viewState, ...viewState}
          if (managedScene && !programmaticUpdate) {
            // A user pan or zoom must not re-widen the glyphs the fit stepped down.
            const selection = this.deps.managedViewStateForCamera(
              this.state.lastGraph,
              nextViewState,
              {fittedManagedVisualDensity: this.state.managedTopologyVisualDensity},
            )
            nextViewState = selection.viewState
            this.state.managedTopologyVisualDensity = selection.managedVisualDensity
          }
          this.state.viewState = nextViewState
          if (!programmaticUpdate) this.state.userCameraLocked = true
          this.state.isProgrammaticViewUpdate = false
          if (this.state.zoomMode === "auto") {
            // client-radial already authored the overview. Switching to
            // regional/global reclustering after the first pan/click moves the
            // nodes out from under the camera and the canvas looks empty.
            if (managedScene) {
              // The accepted ELK scene already owns geometry. Manual camera
              // changes may switch only its renderer density policy.
              this.state.zoomTier = "local"
            } else {
              const nextTier = layoutMode === "client-radial" ? "local" : this.deps.resolveZoomTier(nextViewState.zoom || 0)
              this.deps.setZoomTier(nextTier, false)
            }
          }
          return nextViewState
        }
        let acceptedViewState
        let cameraAccepted = true
        if (managedScene) {
          const result = runRecoverableManagedCameraUpdate(this, applyViewState)
          cameraAccepted = result.ok
          acceptedViewState = result.ok ? result.value : this.state.viewState
        } else {
          acceptedViewState = applyViewState()
        }
        if (!cameraAccepted) return acceptedViewState

        // Deck applies initialViewState after this callback returns. Defer the
        // layer-only refresh so projection reads the newly rebuilt viewport.
        globalThis.queueMicrotask(() => {
          if (managedScene) {
            runRecoverableManagedCameraUpdate(this, () => this.deps.refreshGraphLayersForViewState())
          } else {
            this.deps.refreshGraphLayersForViewState()
          }
        })
        return acceptedViewState
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
