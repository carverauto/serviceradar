import {Deck, LinearInterpolator, OrthographicView} from "@deck.gl/core"
import {Socket} from "phoenix"
import GodViewRenderer from "../GodViewRenderer"
import {GOD_VIEW_DEVICE_PROPS} from "./lifecycle_dom_setup_methods"
import {GOD_VIEW_ALPHA_BLEND} from "./gpu_parameters"
import {WorldTileCache} from "./world_tile_cache"
import {WorldOverlays} from "./world_overlays"
import WorldTileLayer from "./world_tile_layer"
import {WORLD_EXTENT, WORLD_TILE_SIZE, MAX_TILE_BYTES} from "./world_tile_decode"
import {readBoundedBody, worldJson} from "./world_http"

function element(tag, className, text) {
  const node = document.createElement(tag)
  node.className = className
  if (text) node.textContent = text
  return node
}

/** The persistent world camera owns bounded ELK scenes and returns to its retained tiles. */
export default class WorldMapRenderer {
  constructor(el, pushEvent, handleEvent, {csrfToken = ""} = {}) {
    Object.assign(this, {el, pushEvent, handleEvent, csrfToken})
    this.geometryRevision = 0
    this.overlayRevision = 0
    this.packetFlow = true
    this.links = true
    this.filters = {}
    this.destroyed = false
    this.sceneCache = new Map()
    this.cache = new WorldTileCache({
      onChange: () => {this.geometryRevision += 1; this.render()},
      onRetain: () => this.scheduleWatch(),
    })
    this.overlays = new WorldOverlays(() => {this.overlayRevision += 1; this.render()})
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
    this.canvas = element("canvas", "absolute inset-0 h-full w-full")
    this.summary = element("div", "absolute bottom-2 left-3 right-3 pointer-events-none text-xs text-sr-muted", "Loading topology…")
    this.summary.setAttribute("role", "status")
    this.toolbar = element("form", "absolute left-3 top-3 z-20 flex gap-2")
    const input = element("input", "input input-sm bg-sr-surface")
    input.placeholder = "Find device by ID"
    input.setAttribute("aria-label", "Find device by ID")
    const find = element("button", "btn btn-sm", "Find")
    find.type = "submit"
    this.back = element("button", "btn btn-sm", "Back to map")
    this.back.type = "button"
    this.back.hidden = true
    this.back.addEventListener("click", () => this.returnToMap())
    this.toolbar.append(input, find, this.back)
    this.toolbar.addEventListener("submit", event => {event.preventDefault(); void this.search(input.value.trim())})
    this.panel = element("div", "absolute left-3 top-14 z-20 max-w-xs rounded-lg border border-sr-line bg-sr-surface p-3 text-sm")
    this.panel.hidden = true
    this.el.append(this.canvas, this.summary, this.toolbar, this.panel)
    this.viewState = this.overviewView()
    this.deck = new Deck({
      canvas: this.canvas, width: this.el.clientWidth, height: this.el.clientHeight,
      views: new OrthographicView({id: "god-view-world"}),
      deviceProps: {...GOD_VIEW_DEVICE_PROPS, onError: error => this.failRenderer(error)},
      onDeviceInitialized: device => {
        if (device.info.type !== "webgpu") this.failRenderer(new Error("WebGPU is required for topology"))
        else this.deviceType = "webgpu"
        const lost = device.handle?.lost || device.lost
        lost?.then(info => {
          if (!this.destroyed && info?.reason !== "destroyed") this.failRenderer(new Error(`WebGPU device lost: ${info?.message || info?.reason || "unknown"}`))
        })
      },
      onError: error => this.failRenderer(error),
      initialViewState: this.viewState, parameters: GOD_VIEW_ALPHA_BLEND,
      controller: {dragPan: true, scrollZoom: {smooth: true}, touchZoom: true, dragRotate: false, touchRotate: false, doubleClickZoom: false},
      pickingRadius: 6, _animate: true,
      onViewStateChange: ({viewState}) => {
        this.viewState = {...viewState, zoom: Math.max(-2, Math.min(this.cache.manifest?.zmax ?? 16, viewState.zoom))}
        return this.viewState
      },
      onClick: info => {if (info.object) void this.pick(info)},
      getTooltip: info => info.object ? {text: info.object.label || `${info.object.count.toLocaleString()} relations`} : null,
    })
    this.resize = new ResizeObserver(() => this.deck?.setProps({width: this.el.clientWidth, height: this.el.clientHeight}))
    this.resize.observe(this.el)
    this.handleEvent("god_view:reset_view", () => {this.returnToMap(); this.setView(this.overviewView())})
    this.handleEvent("god_view:set_layers", ({layers}) => {
      this.packetFlow = layers?.atmosphere !== false
      this.links = layers?.mantle !== false
      this.render()
    })
    this.handleEvent("god_view:set_filters", ({filters}) => {this.filters = {...filters}; this.render()})
    this.handleEvent("god_view:set_zoom_mode", ({mode}) => {
      const zoom = {global: 0, regional: 4, local: 10, auto: this.overviewView().zoom}[mode]
      if (zoom !== undefined) this.setView({...this.viewState, zoom: Math.min(this.cache.manifest?.zmax ?? 16, zoom)})
    })
    this.timer = setInterval(() => void this.poll(), 5000)
    await this.poll()
  }

  async poll() {
    if (this.destroyed || this.polling) return
    this.polling = true
    try {
      if (this.channel?.state !== "joined") await this.refreshManifest()
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
    return {target: [256, 256, 0], zoom: Math.min(0, Math.max(-2, Math.log2(Math.max(128, Math.min(this.el.clientWidth, this.el.clientHeight) - 100) / WORLD_TILE_SIZE)))}
  }

  setView(viewState) {
    this.viewState = viewState
    this.deck?.setProps({initialViewState: viewState})
  }

  async refreshManifest() {
    if (this.manifestRequest) return this.manifestRequest
    this.manifestRequest = worldJson("/topology/tiles/manifest", this.lifetime.signal, 16384).then(manifest => {
      if (this.destroyed || !this.cache.observe(manifest)) return
      this.watchSignature = null
      this.geometryRevision += 1
      this.sceneCache.clear()
      this.overlays.setVisible([])
      this.returnToMap()
      this.render()
      this.scheduleWatch()
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
    this.channel.onError(() => {this.watchSignature = null; this.status("Topology connection interrupted; reconnecting…")})
    this.channel.join().receive("ok", fence => {
      this.watchSignature = null
      void generation(fence).catch(error => this.status(error.message))
    }).receive("error", error => this.status(`Topology unavailable: ${error.reason}`))
  }

  scheduleWatch() {
    if (this.watchTimer || this.destroyed) return
    this.watchTimer = setTimeout(() => {this.watchTimer = null; this.syncWatch()}, 50)
  }

  syncWatch() {
    if (this.destroyed || !this.cache.manifest || this.channel?.state !== "joined") return
    const payload = this.cache.watchPayload()
    const signature = JSON.stringify(payload)
    if (signature === this.watchSignature) return
    this.watchSignature = signature
    this.channel.push("tiles:watch", payload).receive("ok", reply => {
      if (this.destroyed || signature !== this.watchSignature) return
      this.cache.acknowledgeWatch(reply.watch_id, payload)
      if (this.pendingInvalidation) {
        this.cache.invalidate(this.pendingInvalidation)
        this.pendingInvalidation = null
      }
    }).receive("error", () => {this.watchSignature = null; void this.refreshManifest().catch(error => this.status(error.message))})
      .receive("timeout", () => {this.watchSignature = null; this.scheduleWatch()})
  }

  viewportLoaded(tiles) {
    if (this.destroyed) return
    this.cache.setVisible(tiles.map(tile => tile.index))
    const geometries = tiles.map(tile => tile.content).filter(Boolean)
    this.overlays.setVisible(geometries)
    void this.overlays.poll()
    this.scheduleWatch()
    this.cache.prefetch()
    const manifest = this.cache.manifest
    this.status(`${manifest.node_count.toLocaleString()} devices · ${tiles.length} visible tiles`)
    this.pushEvent("god_view_stream_stats", {
      schema_version: 3, revision: manifest.generation, node_count: manifest.node_count, edge_count: manifest.relation_count,
      rendered_node_count: geometries.reduce((sum, tile) => sum + tile.nodes.length, 0),
      rendered_edge_count: geometries.reduce((sum, tile) => sum + tile.edges.length, 0),
      bytes: geometries.reduce((sum, tile) => sum + tile.byteLength, 0), renderer_mode: this.deviceType,
      generated_at: new Date().toISOString(), zoom_mode: "auto", zoom_tier: "local",
    })
  }

  render() {
    if (!this.deck || !this.cache.manifest || this.destroyed || this.rendererFailed) return
    this.deck.setProps({layers: [new WorldTileLayer({
      id: `god-view-world-${this.cache.manifest.layout_version}`, visible: !this.detailRenderer,
      maxZoom: this.cache.manifest.zmax, getTileData: this.getTileData,
      updateTriggers: {getTileData: this.geometryRevision},
      overlays: this.overlays.entries, overlayRevision: this.overlayRevision, packetFlow: this.packetFlow,
      links: this.links, filters: this.filters,
      onViewportLoad: this.onViewportLoad, onTileError: this.onTileError,
    })], _animate: !this.detailRenderer && this.packetFlow})
  }

  async search(id) {
    if (!id) return
    this.searchRequest?.abort()
    const request = new globalThis.AbortController()
    this.searchRequest = request
    try {
      const result = await worldJson(`/topology/tiles/search?device_id=${encodeURIComponent(id)}`, request.signal, 16384)
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
    } catch (error) {if (!this.destroyed && !request.signal.aborted) this.status(error.message)}
  }

  async pick(info) {
    const geometry = info.sourceTile?.content
    if (!geometry) return
    this.selection?.abort()
    const selection = new globalThis.AbortController()
    this.selection = selection
    const object = info.object
    this.panel.replaceChildren(element("div", "font-semibold", object.label || `${object.count.toLocaleString()} relations`))
    this.panel.hidden = false
    const params = {...geometry.key, generation: geometry.generation, tile_revision: geometry.revision, kind: object.kind, id: object.id}
    try {
      const result = await worldJson(`/topology/details?${new URLSearchParams(params)}`, selection.signal)
      if (selection.signal.aborted || this.destroyed) return
      const details = result.details
      const text = details.members ? `${details.members.toLocaleString()} devices` : details.device?.label || details.device?.id || "Selected topology connection"
      this.panel.append(element("p", "mt-2 text-sr-muted", text))
      const open = element("button", "btn btn-sm mt-3", object.kind === "device" ? "Open neighborhood" : "Show members")
      open.addEventListener("click", () => void this.openScene({...params, ...details.scene}))
      this.panel.append(open)
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
      const url = `/topology/snapshot/latest?${new URLSearchParams(params)}`
      let scene = this.sceneCache.get(url)
      if (!scene) {
        const response = await fetch(url, {
          credentials: "same-origin", signal: globalThis.AbortSignal.any([request.signal, globalThis.AbortSignal.timeout(15000)]), headers: {Accept: "application/vnd.apache.arrow.file"},
        })
        if (!response.ok) throw new Error(`Topology detail HTTP ${response.status}`)
        scene = {bytes: await readBoundedBody(response, MAX_TILE_BYTES), headers: response.headers}
      }
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
      candidate = {el, renderer: new GodViewRenderer(el, events, this.handleEvent, {csrfToken: this.csrfToken})}
      this.pendingDetail = candidate
      await candidate.renderer.mountScene(bytes, headers)
      if (request.signal.aborted || this.destroyed) return
      this.sceneCache.delete(url)
      this.sceneCache.set(url, scene)
      while (this.sceneCache.size > 4) this.sceneCache.delete(this.sceneCache.keys().next().value)
      this.detailRenderer?.destroy()
      this.detailEl?.remove()
      this.detailEl = candidate.el
      this.detailRenderer = candidate.renderer
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

  returnToMap() {
    this.searchRequest?.abort()
    this.selection?.abort()
    this.sceneRequest?.abort()
    this.pendingDetail?.renderer.destroy()
    this.pendingDetail?.el.remove()
    this.pendingDetail = null
    this.detailRenderer?.destroy()
    this.detailRenderer = null
    this.detailEl?.remove()
    this.nextPage?.remove()
    if (this.back) this.back.hidden = true
    if (this.panel) this.panel.hidden = true
    this.render()
  }

  status(message) {if (this.summary) this.summary.textContent = message}

  failRenderer(error) {
    this.rendererFailed = true
    this.deck?.setProps({_animate: false, layers: []})
    this.status(`Topology renderer stopped: ${error.message}. Reload to try again.`)
  }

  update() {}

  destroy() {
    this.destroyed = true
    this.lifetime.abort()
    this.selection?.abort()
    this.returnToMap()
    clearInterval(this.timer)
    clearTimeout(this.watchTimer)
    this.channel?.leave()
    this.overlays.destroy()
    this.cache.destroy()
    this.sceneCache.clear()
    this.resize?.disconnect()
    this.deck?.finalize()
    this.deck = null
  }
}
