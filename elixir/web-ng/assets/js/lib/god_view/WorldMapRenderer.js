import {LinearInterpolator, OrthographicView} from "@deck.gl/core"
import {TopologyDeck} from "./topology_deck"
import {Socket} from "phoenix"
import GodViewRenderer from "../GodViewRenderer"
import {GOD_VIEW_DEVICE_PROPS, createTopologyLabelMeasureText} from "./lifecycle_dom_setup_methods"
import {GOD_VIEW_ALPHA_BLEND} from "./gpu_parameters"
import {adoptDeckViewportSize, syncCanvasContextSize} from "./deck_canvas_size"
import {WorldTileCache} from "./world_tile_cache"
import {WorldOverlays} from "./world_overlays"
import {WorldMembership} from "./world_membership"
import {WorldFilterPanel} from "./world_filter_panel"
import {capabilityIdentity} from "./bitmap_capability"
import WorldTileLayer from "./world_tile_layer"
import {WORLD_EXTENT, WORLD_TILE_SIZE, MAX_TILE_BYTES} from "./world_tile_decode"
import {readBoundedBody, topologyTarget, worldExchange, worldJson, worldJsonParams} from "./world_http"
import {clearPlanLocation, readPlanLocation, planLocationURL} from "../spatial_location"

const QUERY_GENERATION = Symbol("topology query generation")

const MAP_BUTTON_CLASS = "inline-flex min-h-9 shrink-0 items-center justify-center whitespace-nowrap rounded-sr-control border border-sr-line bg-sr-subtle px-3 text-sm font-semibold text-sr-brand shadow-sr-control outline-none hover:border-sr-line-hover hover:bg-sr-control focus-visible:ring-2 focus-visible:ring-sr-focus"

function element(tag, className, text) {
  const node = document.createElement(tag)
  node.className = className
  if (text) node.textContent = text
  return node
}

function selectionTitle(object) {
  const title = object.label || `${object.count.toLocaleString()} relations`
  const seen = typeof object.lastSeen === "string" && object.lastSeen !== "" ? object.lastSeen : ""
  const parts = [title]
  if (object.stale) parts.push("last known")
  if (seen) parts.push(seen)
  return parts.join(" · ")
}

function worldZoomTier(zoom) {
  if (zoom < 2) return "global"
  if (zoom < 7) return "regional"
  return "local"
}

function storedObservation(details) {
  const values = [details?.bundle?.last_seen, details?.relation?.last_seen]
  for (const value of values) {
    if (typeof value === "string" && value !== "") return value
  }
  return ""
}

/** The persistent world camera owns bounded ELK scenes and returns to its retained tiles. */
export default class WorldMapRenderer {
  constructor(el, pushEvent, handleEvent, {csrfToken = ""} = {}) {
    Object.assign(this, {el, pushEvent, handleEvent, csrfToken})
    this.geometryRevision = 0
    this.overlayRevision = 0
    this.membershipRevision = 0
    this.bitmapQuery = null
    this.membershipEnabled = false
    this.packetFlow = true
    this.links = true
    this.inferred = false
    this.zoomMode = "auto"
    this.filters = {}
    this.destroyed = false
    this.sceneCache = new Map()
    this.sceneControls = new Map()
    this.cache = new WorldTileCache({
      onChange: () => {
        this.geometryRevision += 1
        const signature = this.cache.manifest ? JSON.stringify(this.membershipRequest(this.cache.watchPayload())) : null
        if (this.membershipSignature && signature !== this.membershipSignature) this.invalidateMembership()
        this.render()
      },
      onRetain: () => this.scheduleWatch(),
    })
    this.overlays = new WorldOverlays(() => {this.overlayRevision += 1; this.render()})
    this.membership = new WorldMembership({
      onChange: () => {
        if (this.destroyed) return
        this.membershipRevision += 1
        if (!this.membership.pending && this.membership.sequence !== null) {this.membershipError = null; this.clearMembershipRetry()}
        this.updateFilterPanel()
        this.render()
        if (!this.membership.pending && this.cache.manifest) {
          this.status(this.mapSummary(this.visibleTileCount ?? 0))
        }
      },
      onAck: payload => this.channel?.push("membership:ack", payload),
      onReset: (reason, view_digest) => {
        this.channel?.push("membership:reset", {view_digest})
        this.status(`Topology filter pending: ${reason}`)
        this.retryMembership(this.membershipSignature)
      },
    })
    this.getTileData = ({index, signal}) => this.cache.get(index, {signal})
    this.onViewportLoad = tiles => this.viewportLoaded(tiles)
    this.onTileError = error => {
      if (error.name !== "AbortError") {this.retryTiles = true; this.status(error.message)}
    }
    this.lifetime = new globalThis.AbortController()
  }

  async mount() {
    this.el.replaceChildren()
    this.el.style.position = "relative"
    this.el.style.backgroundColor = "var(--sr-color-canvas)"
    this.canvas = element("canvas", "absolute inset-0 h-full w-full")
    this.canvas.tabIndex = 0
    this.canvas.setAttribute("aria-label", "Topology map")
    this.measureText = createTopologyLabelMeasureText()
    this.summary = element("div", "absolute bottom-2 left-3 right-3 pointer-events-none text-xs text-sr-muted", "Loading topology…")
    this.summary.setAttribute("role", "status")
    this.toolbar = element("form", "absolute left-3 top-3 z-20 flex max-w-[calc(100%-1.5rem)] flex-wrap gap-2")
    const input = element("input", "input input-sm bg-sr-surface")
    input.style.width = "13rem"
    input.style.maxWidth = "100%"
    input.placeholder = "Find device by ID"
    input.setAttribute("aria-label", "Find device by ID")
    const find = element("button", MAP_BUTTON_CLASS, "Find")
    find.type = "submit"
    this.back = element("button", MAP_BUTTON_CLASS, "Back to map")
    this.back.type = "button"
    this.back.hidden = true
    this.back.addEventListener("click", () => this.returnToMap())
    const share = element("button", MAP_BUTTON_CLASS, "Share map")
    share.type = "button"
    share.addEventListener("click", () => this.shareMap())
    this.toolbar.append(input, find, share, this.back)
    this.toolbar.addEventListener("submit", event => {event.preventDefault(); void this.search(input.value.trim())})
    this.panel = element("div", "absolute left-3 top-14 z-20 max-w-xs rounded-lg border border-sr-line bg-sr-surface p-3 text-sm")
    this.panel.hidden = true
    this.el.append(this.canvas, this.summary, this.toolbar, this.panel)
    this.filterPanel = new WorldFilterPanel({parent: this.el, toolbar: this.toolbar, onApply: query => this.setBitmapQuery(query)})
    window.addEventListener("keydown", event => {
      if (event.key === "Escape" && !this.panel.hidden) this.dismissPanel(true)
    }, {signal: this.lifetime.signal})
    this.el.addEventListener("pointerdown", event => {
      if (this.detailRenderer && event.target.tagName === "CANVAS") this.dismissPanel()
    }, {signal: this.lifetime.signal})
    this.viewState = this.overviewView()
    this.deck = new TopologyDeck({
      canvas: this.canvas, width: this.el.clientWidth, height: this.el.clientHeight,
      views: new OrthographicView({id: "god-view-world"}),
      deviceProps: {...GOD_VIEW_DEVICE_PROPS, onError: error => this.failRenderer(error)},
      onDeviceInitialized: device => {
        if (device.info.type !== "webgpu") this.failRenderer(new Error("WebGPU is required for topology"))
        else {
          this.deviceType = "webgpu"
          syncCanvasContextSize(device.canvasContext, this.el.clientWidth, this.el.clientHeight)
        }
        const lost = device.handle?.lost || device.lost
        lost?.then(info => {
          if (!this.destroyed && info?.reason !== "destroyed") this.failRenderer(new Error(`WebGPU device lost: ${info?.message || info?.reason || "unknown"}`))
        })
      },
      onError: error => this.failRenderer(error),
      // Deck advances camera transitions after drawing, before Luma's loop
      // submits. Flush now, before those updates can retire drawn buffers.
      onAfterRender: ({device}) => device.submit(),
      viewState: this.viewState, parameters: GOD_VIEW_ALPHA_BLEND,
      controller: {dragPan: true, scrollZoom: {smooth: true}, touchZoom: true, dragRotate: false, touchRotate: false, doubleClickZoom: false},
      pickingRadius: 6, _animate: true,
      onViewStateChange: ({viewState}) => {
        this.setView(viewState)
      },
      onClick: info => {if (info.object) void this.pick(info); else this.dismissPanel()},
      getTooltip: info => info.object ? {text: selectionTitle(info.object)} : null,
    })
    this.resize = new ResizeObserver(() => {
      const width = this.el.clientWidth
      const height = this.el.clientHeight
      this.flushPendingCommands()
      this.deck?.setProps({width, height})
      adoptDeckViewportSize(this.deck, width, height)
    })
    this.resize.observe(this.el)
    this.locationPath = window.location.pathname
    this.onLocationHistory = () => {
      if (this.destroyed || !this.cache.manifest || window.location.pathname !== this.locationPath) return
      this.returnToMap()
      this.setView(this.overviewView())
      this.restoreLocation()
    }
    window.addEventListener("popstate", this.onLocationHistory)
    this.handleEvent("god_view:reset_view", () => {
      // The mounted detail renderer fits its own coordinate space. Fitting
      // must not also discard that scene or move the retained map camera.
      if (this.detailRenderer) this.detailHandlers.get("god_view:reset_view")?.({})
      else {this.returnToMap(); this.setView(this.overviewView())}
    })
    this.handleEvent("god_view:set_layers", ({layers}) => {
      this.setSceneControl("god_view:set_layers", {layers})
      this.packetFlow = layers?.atmosphere !== false
      this.links = layers?.mantle !== false
      this.render()
    })
    this.handleEvent("god_view:set_bitmap_query", ({query}) => this.setBitmapQuery(query))
    this.handleEvent("god_view:set_filters", ({filters}) => {
      this.setSceneControl("god_view:set_filters", {filters})
      this.filters = {...filters}
      this.render()
    })
    for (const name of ["god_view:set_topology_layers", "god_view:mtr_path_data"]) {
      this.handleEvent(name, payload => this.setSceneControl(name, payload))
    }
    this.handleEvent("god_view:set_zoom_mode", ({mode}) => {
      if (this.detailRenderer) return this.detailHandlers.get("god_view:set_zoom_mode")?.({mode})
      const zoom = {global: 0, regional: 4, local: 10, auto: this.overviewView().zoom}[mode]
      if (zoom === undefined) return
      this.setZoomMode(mode)
      this.setView({...this.viewState, zoom: Math.min(this.cache.manifest?.zmax ?? 16, zoom)})
    })
    this.timer = setInterval(() => void this.poll(), 5000)
    await this.poll()
  }

  setZoomMode(mode) {
    this.zoomMode = mode
  }

  setBitmapQuery(query) {
    const next = query === undefined ? null : query
    if (JSON.stringify(next) === JSON.stringify(this.bitmapQuery ?? null)) return
    this.returnToMap()
    this.sceneCache.clear()
    this.queryGeneration = (this.queryGeneration || 0) + 1
    this.bitmapQuery = next
    this.clearMembershipRetry()
    this.invalidateMembership()
    if (!this.membershipEnabled && query) this.status("Topology query filters are unavailable on this server.")
    this.scheduleWatch()
  }

  updateFilterPanel() {
    this.filterPanel?.update({enabled: this.membershipEnabled, capability: this.cache.manifest?.bitmap,
      query: this.bitmapQuery, pending: this.membership.pending, total: this.membership.total, error: this.membershipError})
  }

  setSceneControl(name, payload) {
    this.sceneControls.set(name, payload)
    this.detailHandlers?.get(name)?.(payload)
    this.pendingDetail?.handlers.get(name)?.(payload)
    if (name === "god_view:set_topology_layers") {
      this.inferred = payload.layers?.inferred === true
      this.render()
    }
  }

  async poll() {
    if (this.destroyed || this.polling) return
    this.polling = true
    try {
      // Index readiness and source catalogs change without geometry publication.
      await this.refreshManifest()
      if (this.destroyed) return
      if (!this.channel) this.connect()
      if (this.retryTiles) {
        this.retryTiles = false
        this.geometryRevision += 1
        this.render()
      }
      await this.overlays.poll()
    } catch (error) {
      if (!this.destroyed) this.status(error.message)
    } finally {this.polling = false}
  }

  overviewView() {
    const bounds = this.cache.manifest?.bounds
    if (!bounds) return {target: [256, 256, 0], zoom: Math.min(0, Math.max(-2, Math.log2(Math.max(128, Math.min(this.el.clientWidth, this.el.clientHeight) - 100) / WORLD_TILE_SIZE)))}
    const scale = WORLD_TILE_SIZE / WORLD_EXTENT
    const width = Math.max(2, (bounds[1][0] - bounds[0][0]) * scale)
    const height = Math.max(2, (bounds[1][1] - bounds[0][1]) * scale)
    const zoom = Math.log2(Math.min(Math.max(128, this.el.clientWidth - 160) / width, Math.max(128, this.el.clientHeight - 140) / height))
    return {target: [(bounds[0][0] + bounds[1][0]) * scale / 2, (bounds[0][1] + bounds[1][1]) * scale / 2, 0],
      zoom: Math.max(-2, Math.min(this.cache.manifest?.zmax ?? 16, zoom))}
  }

  setView(viewState) {
    this.viewState = viewState
    this.flushPendingCommands()
    this.deck?.setProps({viewState})
    this.scheduleLocationUpdate()
  }

  flushPendingCommands() {
    this.deck?.device?.submit?.()
  }

  locationFrame() {
    return {resource: "topology", space: "topology-world", version: this.cache.manifest.layout_version,
      bounds: [[0, 0], [WORLD_EXTENT, WORLD_EXTENT]], minZoom: -2, maxZoom: this.cache.manifest.zmax}
  }

  restoreLocation() {
    const params = new URL(window.location.href).searchParams
    // Restore only after the first successful manifest, including retry after
    // an initial outage. Search is asynchronous and resolves the current world.
    if (params.has("device")) {
      const device = params.get("device")
      if (device && device.length <= 512) void this.search(device)
      else this.locationNotice("Invalid device link")
      return
    }
    try {
      const location = readPlanLocation(window.location.href, this.locationFrame())
      if (!location) return
      this.setView({target: [...location.center.map(value => value * WORLD_TILE_SIZE / WORLD_EXTENT), 0], zoom: location.zoom})
    } catch (error) {
      this.setView(this.overviewView())
      this.locationNotice(`${error.message}. Showing the current Home view.`)
    }
  }

  locationNotice(message) {
    this.selection?.abort()
    this.openPanel(element("p", "text-sr-muted", message))
  }

  dismissPanel(focusMap = false) {
    this.selection?.abort()
    this.searchRequest?.abort()
    if (!this.detailRenderer) this.sceneRequest?.abort()
    this.panel.hidden = true
    if (focusMap) this.canvas.focus({preventScroll: true})
  }

  openPanel(...content) {
    const close = element("button", `${MAP_BUTTON_CLASS} float-right ml-2`, "Close")
    close.type = "button"
    close.setAttribute("aria-label", "Close map popup")
    close.addEventListener("click", () => this.dismissPanel(true))
    this.panel.replaceChildren(close, ...content)
    this.panel.hidden = false
  }

  scheduleLocationUpdate() {
    clearTimeout(this.locationTimer)
    if (this.destroyed || !this.cache.manifest) return
    this.locationTimer = setTimeout(() => {
      if (this.destroyed || this.rendererFailed) return
      if (!this.deck?.isInitialized) {
        this.scheduleLocationUpdate()
        return
      }
      // Read the rendered camera: controller transition intents can contain
      // legacy zoom alongside independently interpolated zoomX/zoomY values.
      const viewport = this.deck.getViewports()[0]
      if (!viewport) return
      const target = viewport.target.map(value => Math.max(0, Math.min(WORLD_TILE_SIZE, value)))
      const zoom = Math.max(-2, Math.min(this.cache.manifest.zmax, viewport.zoom))
      if (zoom !== viewport.zoom || target.some((value, axis) => value !== viewport.target[axis])) {
        this.setView({target, zoom})
        return
      }
      const url = this.mapURL(viewport)
      if (url.href !== window.location.href) window.history.replaceState(window.history.state, "", url.href)
    }, 250)
  }

  mapURL(view) {
    const center = view.target.slice(0, 2).map(value => value * WORLD_EXTENT / WORLD_TILE_SIZE)
    const url = planLocationURL(window.location.href, {center, zoom: view.zoom}, this.locationFrame())
    url.searchParams.delete("device")
    return url
  }

  shareMap() {
    if (!this.cache.manifest || !this.deck?.isInitialized) return
    // Share the retained map camera even while a bounded detail scene is open.
    const viewport = this.deck.getViewports()[0]
    if (!viewport) return
    this.showLink(this.mapURL(viewport), "Map link")
  }

  shareDevice(id) {
    const url = clearPlanLocation(window.location.href)
    url.searchParams.set("device", id)
    this.showLink(url, "Device link")
  }

  showLink(url, label) {
    this.selection?.abort()
    url.hash = ""
    const input = element("input", "input input-sm w-full mt-2 bg-sr-surface")
    input.setAttribute("aria-label", label)
    input.readOnly = true
    input.value = url.href
    input.addEventListener("click", () => input.select())
    this.openPanel(element("p", "text-sr-muted", `${label}: copy this address to share.`), input)
    input.focus()
    input.select()
  }

  async refreshManifest() {
    if (this.manifestRequest) return this.manifestRequest
    this.manifestRequest = worldJson("/topology/tiles/manifest", this.lifetime.signal, 16384).then(manifest => {
      const previous = this.cache.manifest
      if (this.destroyed) return
      const changed = this.cache.observe(manifest)
      const capability = value => [value?.bitmap?.ready, value?.bitmap?.reason, capabilityIdentity(value?.bitmap?.query)]
      const capabilityChanged = JSON.stringify(capability(previous)) !== JSON.stringify(capability(manifest))
      const membershipChanged = this.membershipEnabled !== (manifest.bitmap_membership_protocol === 1)
      this.membershipEnabled = manifest.bitmap_membership_protocol === 1
      this.overlays.setBinary(manifest.world_overlay_protocol === 1)
      this.updateFilterPanel()
      if (!this.membershipEnabled && this.bitmapQuery !== null) this.status("Topology query unavailable: filtering is disabled")
      if (!changed) {
        if (membershipChanged || capabilityChanged) {this.clearMembershipRetry(); this.invalidateMembership(); this.render(); this.scheduleWatch()}
        return
      }
      this.watchSignature = null
      this.clearMembershipRetry()
      this.invalidateMembership()
      this.geometryRevision += 1
      this.sceneCache.clear()
      this.overlays.setVisible([])
      this.returnToMap()
      if (!previous) {this.setView(this.overviewView()); this.restoreLocation()}
      else if (previous.layout_version !== manifest.layout_version) {
        this.setView(this.overviewView())
        this.locationNotice("The topology layout changed. Showing the current Home view.")
      }
      this.render()
      this.scheduleWatch()
      this.scheduleLocationUpdate()
    }).finally(() => {this.manifestRequest = null})
    return this.manifestRequest
  }

  connect() {
    if (!window.godViewSocket) {
      window.godViewSocket = new Socket("/socket", {params: {_csrf_token: this.csrfToken}})
      window.godViewSocket.connect()
    }
    this.channel = window.godViewSocket.channel("topology:tiles", {})
    const generation = async fence => {
      if (fence.layout_version !== this.cache.manifest?.layout_version || fence.generation > this.cache.manifest.generation) {
        await this.refreshManifest()
        if (!this.destroyed && fence.generation > this.cache.manifest.generation) await this.refreshManifest()
      }
      this.scheduleWatch()
    }
    this.channel.on("topology_generation", fence => {void generation(fence).catch(error => this.status(error.message))})
    this.channel.on("topology_invalidated", message => {
      if (!this.cache.invalidate(message)) this.pendingInvalidation = message
    })
    this.channel.on("membership:frame", bytes => this.membership.receive(bytes))
    this.channel.onClose(() => {if (!this.destroyed) this.invalidateMembership()})
    this.channel.onError(() => {this.watchSignature = null; this.invalidateMembership(); this.status("Topology connection interrupted; reconnecting…")})
    this.channel.join().receive("ok", fence => {
      this.watchSignature = null
      void generation(fence).catch(error => this.status(error.message))
    }).receive("error", error => this.status(`Topology unavailable: ${error.reason}`))
  }

  scheduleWatch() {
    if (this.destroyed) return
    if (this.membershipSignature && this.cache.manifest &&
        JSON.stringify(this.membershipRequest(this.cache.watchPayload())) !== this.membershipSignature) this.invalidateMembership()
    if (this.watchTimer) return
    this.watchTimer = setTimeout(() => {this.watchTimer = null; this.syncWatch()}, 50)
  }

  syncWatch() {
    if (this.destroyed || !this.cache.manifest || this.channel?.state !== "joined") return
    const payload = this.cache.watchPayload()
    const signature = JSON.stringify(payload)
    if (signature === this.watchSignature) {this.syncMembership(payload); return}
    this.watchSignature = signature
    this.channel.push("tiles:watch", payload).receive("ok", reply => {
      if (this.destroyed || signature !== this.watchSignature) return
      this.cache.acknowledgeWatch(reply.watch_id, payload)
      this.syncMembership(payload)
      if (this.pendingInvalidation) {
        this.cache.invalidate(this.pendingInvalidation)
        this.pendingInvalidation = null
      }
    }).receive("error", () => {this.watchSignature = null; void this.refreshManifest().catch(error => this.status(error.message))})
      .receive("timeout", () => {this.watchSignature = null; this.scheduleWatch()})
  }

  invalidateMembership() {
    if ((!this.membershipEnabled || this.bitmapQuery === null) && (this.membershipSignature || this.membership.binding) && this.channel?.state === "joined") {
      this.channel.push("membership:unwatch", {})
    }
    // Disconnect/reconciliation may clear a binding without changing the query
    // or displayed receipts. Keep its retry deadline and history in that case.
    if (!this.membershipEnabled || this.bitmapQuery === null) this.clearMembershipRetry()
    this.membershipError = null
    this.membershipSignature = null
    this.membership?.clear(this.bitmapQuery !== null)
  }

  clearMembershipRetry() {
    clearTimeout(this.membershipRetryTimer)
    this.membershipRetryTimer = null
    this.membershipRetrySignature = null
    this.membershipRetryAttempt = 0
  }

  retryMembership(signature) {
    if (this.destroyed || signature !== this.membershipSignature) return
    this.membershipSignature = null
    this.membership.clear(true)
    this.membershipRetrySignature = signature
    const delay = Math.min(10000, 1000 * 2 ** Math.min(this.membershipRetryAttempt || 0, 4))
    this.membershipRetryAttempt = (this.membershipRetryAttempt || 0) + 1
    this.membershipRetryTimer = setTimeout(() => {
      this.membershipRetryTimer = null
      if (!this.destroyed) this.scheduleWatch()
    }, delay)
  }

  membershipRequest(payload) {
    // Prefetched geometry stays watched for invalidation but cannot change the
    // displayed membership view. Canonical order also ignores cache LRU churn.
    const tiles = payload.tiles.filter(tile => this.cache.visible.has(`${tile.z}/${tile.x}/${tile.y}`) && typeof tile.revision === "string")
      .sort((left, right) => left.z - right.z || left.x - right.x || left.y - right.y)
    return {protocol: 1, layout_version: payload.layout_version, tiles, query: this.bitmapQuery}
  }

  syncMembership(payload) {
    if (!this.membershipEnabled || this.bitmapQuery === null) return
    const request = this.membershipRequest(payload)
    const {tiles} = request
    const signature = JSON.stringify(request)
    if (signature === this.membershipRetrySignature && this.membershipRetryTimer) return
    if (signature !== this.membershipRetrySignature) this.clearMembershipRetry()
    if (signature === this.membershipSignature) return
    this.membershipSignature = signature
    this.membershipPush = (this.membershipPush || 0) + 1
    const pushId = this.membershipPush
    this.membership.clear(true)
    this.channel.push("membership:watch", request).receive("ok", binding => {
      if (this.destroyed || pushId !== this.membershipPush || signature !== this.membershipSignature) return
      const geometries = tiles.map(tile => this.cache.entries.get(`${tile.z}/${tile.x}/${tile.y}`)?.geometry)
      if (geometries.some((geometry, index) => !geometry || geometry.revision !== tiles[index].revision)) {
        this.invalidateMembership()
        this.scheduleWatch()
        return
      }
      this.membershipProjectionIncomplete = binding.projection?.mapped < binding.projection?.total
      try {this.membership.bind(binding, geometries)} catch (error) {this.status(error.message)}
    }).receive("error", error => {
      if (pushId !== this.membershipPush || signature !== this.membershipSignature) return
      this.membershipError = error.reason || "unsupported filter"
      this.updateFilterPanel()
      this.status(`Topology query unavailable: ${error.reason || "unsupported filter"}`)
      if (["membership_not_ready", "membership_replaced", "index_not_ready", "index_unavailable", "prefix_source_unavailable", "source_changed", "query_busy", "query_timeout", "query_unavailable"].includes(error.reason)) this.retryMembership(signature)
    }).receive("timeout", () => {
      if (pushId !== this.membershipPush || signature !== this.membershipSignature) return
      this.retryMembership(signature)
    })
  }

  viewportLoaded(tiles) {
    if (this.destroyed) return
    this.cache.setVisible(tiles.map(tile => tile.index))
    const geometries = tiles.map(tile => tile.content).filter(Boolean)
    const count = Math.max(1, tiles.length)
    if (count !== this.visibleTileCount) {this.visibleTileCount = count; this.render()}
    this.overlays.setVisible(geometries)
    void this.overlays.poll()
    this.scheduleWatch()
    const prefetchViewport = `${this.cache.manifest.layout_version}:${tiles.map(tile => `${tile.index.z}/${tile.index.x}/${tile.index.y}`).sort().join(",")}`
    if (prefetchViewport !== this.prefetchViewport) {
      this.prefetchViewport = prefetchViewport
      this.cache.prefetch()
    }
    const manifest = this.cache.manifest
    this.status(this.bitmapQuery !== null && !this.membershipEnabled ? "Topology query unavailable: filtering is disabled" : this.mapSummary(tiles.length))
    const payload = {
      schema_version: 3, revision: manifest.generation, node_count: manifest.node_count, edge_count: manifest.relation_count,
      rendered_node_count: geometries.reduce((sum, tile) => sum + tile.nodes.length, 0),
      rendered_edge_count: geometries.reduce((sum, tile) => sum + tile.edges.length, 0),
      bytes: geometries.reduce((sum, tile) => sum + tile.byteLength, 0), renderer_mode: this.deviceType,
    }
    if (typeof manifest.generated_at === "string") payload.generated_at = manifest.generated_at
    const stats = {}
    if (manifest.pipeline_stats && typeof manifest.pipeline_stats === "object") {
      for (const [key, value] of Object.entries(manifest.pipeline_stats)) {
        if (Number.isInteger(value)) stats[key] = value
      }
    }
    if (Object.keys(stats).length > 0) payload.pipeline_stats = stats
    if (typeof this.viewState?.zoom === "number") payload.zoom_tier = worldZoomTier(this.viewState.zoom)
    if (this.zoomMode) payload.zoom_mode = this.zoomMode
    this.pushEvent("god_view_stream_stats", payload)
  }

  render() {
    if (!this.deck || !this.cache.manifest || this.destroyed || this.rendererFailed) return
    this.flushPendingCommands()
    this.deck.setProps({layers: [new WorldTileLayer({
      id: `god-view-world-${this.cache.manifest.layout_version}`, visible: !this.detailRenderer,
      maxZoom: this.cache.manifest.zmax, getTileData: this.getTileData,
      updateTriggers: {getTileData: this.geometryRevision},
      overlays: this.overlays.entries, overlayRevision: this.overlayRevision, packetFlow: this.packetFlow,
      membership: this.membership.entries, membershipRevision: this.membershipRevision,
      membershipEnabled: this.bitmapQuery !== null, membershipPending: this.membership.pending,
      links: this.links, inferred: this.inferred, filters: this.filters, visibleTileCount: this.visibleTileCount ?? 64,
      onViewportLoad: this.onViewportLoad, onTileError: this.onTileError, measureText: this.measureText,
    })], _animate: !this.detailRenderer && this.packetFlow})
  }

  async search(id) {
    if (!id) return
    this.searchRequest?.abort()
    const request = new globalThis.AbortController()
    this.searchRequest = request
    try {
      const params = this.queryParams({device_id: id})
      const result = await worldJsonParams("/topology/tiles/search", params, {signal: request.signal, limit: 16384, csrfToken: this.csrfToken})
      this.assertQuery(params)
      if (this.destroyed || request.signal.aborted) return
      await this.refreshManifest()
      if (this.destroyed || request.signal.aborted) return
      if (result.layout_version !== this.cache.manifest.layout_version || result.generation !== this.cache.manifest.generation) throw new Error("Topology changed; search again")
      if (![result.x, result.y].every(value => Number.isInteger(value) && value >= 0 && value < WORLD_EXTENT) ||
          !Number.isInteger(result.zoom) || result.zoom < 0 || result.zoom > this.cache.manifest.zmax) throw new Error("Invalid device location")
      this.searchRequest = null
      this.returnToMap()
      this.setView({target: [result.x, result.y, 0].map(value => value * WORLD_TILE_SIZE / WORLD_EXTENT), zoom: result.zoom,
        transitionDuration: 500, transitionInterpolator: new LinearInterpolator(["target", "zoom"])})
      await this.showSelection({kind: "device", id, label: id}, {
        layout_version: result.layout_version, generation: result.generation, kind: "device", id,
      })
    } catch (error) {if (!this.destroyed && !request.signal.aborted) this.locationNotice(error.message)}
  }

  async pick(info) {
    const geometry = info.sourceTile?.content
    if (!geometry) return
    const object = info.object
    if (object.kind === "aggregate") {
      this.dismissPanel()
      if (!this.deck?.isInitialized) return
      const viewport = this.deck.getViewports()[0]
      if (!viewport) return
      const zoom = Math.min(this.cache.manifest.zmax, Math.max(viewport.zoom, geometry.key.z) + 2)
      if (zoom > viewport.zoom) {
        const target = [geometry.positions[object.index * 2], geometry.positions[object.index * 2 + 1], 0]
        this.setView({target, zoom, transitionDuration: 500, transitionInterpolator: new LinearInterpolator(["target", "zoom"])})
        return
      }
      const selection = new globalThis.AbortController()
      this.selection = selection
      const params = {...geometry.key, generation: geometry.generation, tile_revision: geometry.revision, kind: object.kind, id: object.id}
      try {
        const bound = this.queryParams(params)
        const result = await worldJsonParams("/topology/details", bound, {signal: selection.signal, csrfToken: this.csrfToken})
        this.assertQuery(bound)
        if (selection.signal.aborted || this.destroyed) return
        await this.openScene({layout_version: params.layout_version, generation: params.generation, ...result.details.scene})
      } catch (error) {if (!selection.signal.aborted && !this.destroyed) this.locationNotice(error.message)}
      return
    }
    return this.showSelection(object, {...geometry.key, generation: geometry.generation, tile_revision: geometry.revision, kind: object.kind, id: object.id})
  }

  async showSelection(object, params) {
    this.selection?.abort()
    const selection = new globalThis.AbortController()
    this.selection = selection
    const title = element("div", "font-semibold", selectionTitle(object))
    this.openPanel(title)
    try {
      params = this.queryParams(params)
      const result = await worldJsonParams("/topology/details", params, {signal: selection.signal, csrfToken: this.csrfToken})
      this.assertQuery(params)
      if (selection.signal.aborted || this.destroyed) return
      const details = result.details
      const seen = storedObservation(details)
      const stale = object?.stale === true || details?.relation?.stale === true
      title.textContent = selectionTitle({label: object.label, count: object.count, stale, lastSeen: seen})
      const text = details.members ? `${details.members.toLocaleString()} devices` : details.device?.label || details.device?.id || "Selected topology connection"
      this.panel.append(element("p", "mt-2 text-sr-muted", text))
      const observation = []
      if (stale) observation.push("last known")
      if (seen) observation.push(seen)
      if (observation.length > 0) this.panel.append(element("p", "mt-2 text-sr-muted", observation.join(" · ")))
      const open = element("button", "btn btn-sm mt-3", object.kind === "device" ? "Open neighborhood" : "Show members")
      // Scene identity comes from the server. A device neighborhood is the
      // same scene when picked from a parent tile, child tile, or search.
      const scene = {layout_version: params.layout_version, generation: params.generation, ...details.scene, query: params.query}
      open.addEventListener("click", () => void this.openScene(scene))
      this.panel.append(open)
      if (object.kind === "device") {
        const share = element("button", "btn btn-sm mt-3", "Share device")
        share.type = "button"
        share.addEventListener("click", () => this.shareDevice(object.id))
        this.panel.append(share)
      }
    } catch (error) {if (!selection.signal.aborted && !this.destroyed) this.panel.append(element("p", "mt-2", error.message))}
  }

  async openScene(params) {
    this.sceneRequest?.abort()
    this.pendingDetail?.renderer.destroy()
    this.pendingDetail?.el.remove()
    this.pendingDetail = null
    const request = new globalThis.AbortController()
    this.sceneRequest = request
    let candidate
    try {
      params = this.queryParams(params)
      const url = topologyTarget("/topology/snapshot/latest", params).target
      let scene = params.query ? null : this.sceneCache.get(url)
      if (!scene) {
        const exchange = await worldExchange("/topology/snapshot/latest", params, {
          signal: request.signal, accept: "application/vnd.apache.arrow.file", csrfToken: this.csrfToken,
        })
        if (!exchange.response.ok) throw new Error(`Topology detail HTTP ${exchange.response.status}`)
        scene = {bytes: await readBoundedBody(exchange.response, MAX_TILE_BYTES), headers: exchange.response.headers}
      }
      this.assertQuery(params)
      if (request.signal.aborted || this.destroyed) return
      const {bytes, headers} = scene
      if (headers.get("x-sr-topology-layout-version") !== this.cache.manifest.layout_version ||
          Number(headers.get("x-sr-topology-generation")) !== this.cache.manifest.generation) throw new Error("Topology changed; select the item again")
      const el = element("div", "absolute inset-0 h-full w-full")
      el.style.visibility = "hidden"
      this.el.insertBefore(el, this.toolbar)
      const events = (name, payload) => {
        if (request.signal.aborted || this.destroyed) return
        if (name === "god_view_stream_error") this.status(payload.message || "Detail unavailable")
        else if (name !== "god_view_stream_stats") this.pushEvent(name, payload)
      }
      const handlers = new Map()
      const handleSceneEvent = (name, callback) => {
        handlers.set(name, callback)
        if (this.sceneControls.has(name)) callback(this.sceneControls.get(name))
      }
      candidate = {el, handlers, renderer: new GodViewRenderer(el, events, handleSceneEvent, {csrfToken: this.csrfToken})}
      this.pendingDetail = candidate
      await candidate.renderer.mountScene(bytes, headers)
      this.assertQuery(params)
      if (request.signal.aborted || this.destroyed) return
      if (!params.query) {
        this.sceneCache.delete(url)
        this.sceneCache.set(url, scene)
        while (this.sceneCache.size > 4) this.sceneCache.delete(this.sceneCache.keys().next().value)
      }
      this.detailRenderer?.destroy()
      this.detailEl?.remove()
      this.detailEl = candidate.el
      this.detailRenderer = candidate.renderer
      this.detailHandlers = candidate.handlers
      this.detailEl.style.visibility = "visible"
      this.pendingDetail = null
      candidate = null
      this.panel.hidden = true
      this.back.hidden = false
      this.render()
      this.nextPage?.remove()
      const cursor = headers.get("x-sr-topology-next-cursor")
      if (cursor) {
        this.nextPage = element("button", "btn btn-sm", "Next page")
        this.nextPage.type = "button"
        this.nextPage.addEventListener("click", () => void this.openScene({...params, cursor}))
        this.toolbar.append(this.nextPage)
      }
    } catch (error) {if (!request.signal.aborted && !this.destroyed) this.status(error.message)}
    finally {
      if (candidate) {
        candidate.renderer.destroy()
        candidate.el.remove()
        if (this.pendingDetail === candidate) this.pendingDetail = null
      }
    }
  }

  queryParams(params) {
    const query = this.bitmapQuery === null ? null : JSON.stringify(this.bitmapQuery)
    if (query !== null && (!this.membershipEnabled || this.membership.pending)) {
      throw new Error("Topology filter pending; try again when the map is ready")
    }
    if (params.query && params.query !== query) throw new Error("Topology query changed; select the item again")
    if (query && new TextEncoder().encode(query).length > 16384) throw new Error("Topology filter is too large")
    const {query: _unused, ...bound} = params
    if (query) bound.query = query
    Object.defineProperty(bound, QUERY_GENERATION, {value: this.queryGeneration || 0})
    return bound
  }

  assertQuery(params) {
    if (params[QUERY_GENERATION] !== (this.queryGeneration || 0)) {
      throw new Error("Topology query changed; select the item again")
    }
  }

  returnToMap() {
    this.searchRequest?.abort()
    this.selection?.abort()
    this.sceneRequest?.abort()
    this.pendingDetail?.renderer.destroy()
    this.pendingDetail?.el.remove()
    this.pendingDetail = null
    this.detailRenderer?.destroy()
    this.detailRenderer = null
    this.detailHandlers = null
    this.detailEl?.remove()
    this.nextPage?.remove()
    if (this.back) this.back.hidden = true
    if (this.panel) this.panel.hidden = true
    this.render()
  }

  mapSummary(tiles) {
    if (this.bitmapQuery !== null && this.membershipError) return `Topology query unavailable: ${this.membershipError}`
    if (this.bitmapQuery !== null && (this.membership.pending || this.membership.total === null)) return "Topology filter pending…"
    const summary = this.bitmapQuery === null ? `${this.cache.manifest.node_count.toLocaleString()} devices · ${tiles} visible tiles` :
      `${new Intl.NumberFormat().format(this.membership.total)} matching devices · ${tiles} visible tiles`
    return this.bitmapQuery !== null && this.membershipProjectionIncomplete ? `${summary} · Some geometry has no canonical device identity` : summary
  }

  status(message) {if (this.summary) this.summary.textContent = this.rendererError || message}

  failRenderer(error) {
    if (this.rendererFailed) return
    this.rendererFailed = true
    this.rendererError = `Topology renderer stopped: ${error.message}. Reload to try again.`
    this.flushPendingCommands()
    this.deck?.setProps({_animate: false, layers: []})
    this.status(this.rendererError)
  }

  update() {}

  destroy() {
    this.destroyed = true
    this.lifetime.abort()
    this.filterPanel?.destroy()
    this.selection?.abort()
    this.returnToMap()
    clearInterval(this.timer)
    clearTimeout(this.watchTimer)
    this.clearMembershipRetry()
    clearTimeout(this.locationTimer)
    window.removeEventListener("popstate", this.onLocationHistory)
    this.channel?.leave()
    this.membership.clear()
    this.overlays.destroy()
    this.cache.destroy()
    this.sceneCache.clear()
    this.resize?.disconnect()
    this.deck?.finalize()
    this.deck = null
  }
}
