import mapboxgl from "mapbox-gl"
import {Deck, MapView} from "@deck.gl/core"
import {ArcLayer, LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"

const DEFAULT_LIGHT_STYLE = "mapbox://styles/mapbox/light-v11"
const DEFAULT_DARK_STYLE = "mapbox://styles/mapbox/dark-v11"
const OSM_STYLE_ID = "serviceradar-dashboard-osm-raster"
const MAX_INLINE_LAYER_ROWS = 10000
const DASHBOARD_WASM_INTERFACE = "dashboard-wasm-v1"

function osmRasterStyle() {
  return {
    version: 8,
    metadata: {sr_style_url: OSM_STYLE_ID},
    sources: {
      osm: {
        type: "raster",
        tiles: [
          "https://a.tile.openstreetmap.org/{z}/{x}/{y}.png",
          "https://b.tile.openstreetmap.org/{z}/{x}/{y}.png",
          "https://c.tile.openstreetmap.org/{z}/{x}/{y}.png",
        ],
        tileSize: 256,
        attribution: "© OpenStreetMap contributors",
      },
    },
    layers: [{id: "osm", type: "raster", source: "osm"}],
  }
}

function looksLikeMapboxPublicToken(token) {
  return /^pk\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(String(token || "").trim())
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
}

function numberOr(value, fallback) {
  const number = Number(value)
  return Number.isFinite(number) ? number : fallback
}

function colorOr(value, fallback) {
  if (!Array.isArray(value)) return fallback
  const color = value.slice(0, 4).map((part) => clamp(Math.round(Number(part) || 0), 0, 255))
  return color.length >= 3 ? (color.length === 3 ? [...color, 255] : color) : fallback
}

function getField(row, field) {
  if (!field) return undefined
  return String(field)
    .split(".")
    .reduce((acc, key) => (acc && typeof acc === "object" ? acc[key] : undefined), row)
}

function positionAccessor(spec, fallback = ["longitude", "latitude"]) {
  let fields = fallback

  if (Array.isArray(spec)) {
    fields = spec
  } else if (spec && typeof spec === "object") {
    fields = [spec.longitude || spec.lng || spec.x || fallback[0], spec.latitude || spec.lat || spec.y || fallback[1]]
  }

  const [lngField, latField] = fields

  return (row) => {
    const longitude = numberOr(getField(row, lngField), NaN)
    const latitude = numberOr(getField(row, latField), NaN)
    return [longitude, latitude]
  }
}

function isFinitePosition(position) {
  const [longitude, latitude] = position || []

  return (
    Number.isFinite(longitude) &&
    Number.isFinite(latitude) &&
    longitude >= -180 &&
    longitude <= 180 &&
    latitude >= -90 &&
    latitude <= 90
  )
}

const DashboardWasmHost = {
  mounted() {
    this.cancelled = false
    this._onResize = () => this.resizeMap()
    this._onThemeChange = () => this.applyThemeStyle()
    window.addEventListener("resize", this._onResize)

    this._themeObserver = new MutationObserver(this._onThemeChange)
    this._themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme", "class", "style"],
    })
    this._themeObserver.observe(document.body, {
      attributes: true,
      attributeFilter: ["data-theme", "class", "style"],
    })

    this.boot()
  },

  destroyed() {
    this.cancelled = true
    window.removeEventListener("resize", this._onResize)

    try {
      this._themeObserver?.disconnect()
    } catch (_error) {}

    this.teardownMap()
  },

  async boot() {
    const host = this.readHostPayload()
    if (!host) return

    this.renderState("loading", "Loading dashboard renderer")

    try {
      this.validateInterfaceVersion(host)

      const wasmUrl = host?.package?.wasm_url
      if (!wasmUrl) throw new Error("renderer URL is missing")

      const response = await fetch(wasmUrl, {credentials: "same-origin", cache: "force-cache"})
      if (!response.ok) throw new Error(`renderer fetch failed (${response.status})`)

      const wasmContext = {instance: null, memory: null, renderModel: null}
      const imports = this.importsFor(host, wasmContext)
      let result

      if (WebAssembly.instantiateStreaming) {
        try {
          result = await WebAssembly.instantiateStreaming(response, imports)
        } catch (_error) {
          const retry = await fetch(wasmUrl, {credentials: "same-origin", cache: "force-cache"})
          const bytes = await retry.arrayBuffer()
          result = await WebAssembly.instantiate(bytes, imports)
        }
      } else {
        const bytes = await response.arrayBuffer()
        result = await WebAssembly.instantiate(bytes, imports)
      }

      if (this.cancelled) return

      const instance = result.instance || result
      wasmContext.instance = instance
      wasmContext.memory = instance?.exports?.memory || null
      this.validateExports(instance, host)
      this.invokeEntrypoint(instance, host)

      if (wasmContext.renderModel) {
        this.renderModel(wasmContext.renderModel, host)
      } else {
        this.renderState("ready", `${host.package.name} renderer loaded`)
      }
    } catch (error) {
      if (!this.cancelled) this.renderState("error", error?.message || String(error))
    }
  },

  readHostPayload() {
    try {
      return JSON.parse(this.el.dataset.host || "{}")
    } catch (_error) {
      this.renderState("error", "dashboard host payload is invalid")
      return null
    }
  },

  importsFor(host, wasmContext) {
    const encoder = new TextEncoder()
    const frames = Array.isArray(host?.package?.frames) ? host.package.frames : []
    const encodedFrame = (index) => {
      if (!Number.isInteger(index) || index < 0 || index >= frames.length) return new Uint8Array()
      return encoder.encode(JSON.stringify(frames[index]))
    }
    const writeBytes = (ptr, len, bytes) => {
      const memory = wasmContext.memory || wasmContext.instance?.exports?.memory
      if (!memory) return 0

      const writable = Math.min(Number(len) || 0, bytes.byteLength)
      new Uint8Array(memory.buffer, ptr, writable).set(bytes.slice(0, writable))
      return writable
    }
    const readJson = (ptr, len) => {
      const memory = wasmContext.memory || wasmContext.instance?.exports?.memory
      if (!memory) throw new Error("renderer memory is unavailable")

      const bytes = new Uint8Array(memory.buffer, ptr, len)
      return JSON.parse(new TextDecoder().decode(bytes))
    }
    const emitRenderModel = (ptr, len) => {
      try {
        wasmContext.renderModel = readJson(ptr, len)
        return 1
      } catch (error) {
        console.warn("[DashboardWasmHost] invalid render model:", error?.message || error)
        return 0
      }
    }

    return {
      env: {
        sr_log: (_ptr, _len) => {},
        sr_capability_allowed: (_ptr, _len) => 0,
        sr_emit_render_model: emitRenderModel,
        sr_frame_count: () => frames.length,
        sr_frame_status: index => (frames[index]?.status === "ok" ? 1 : 0),
        sr_frame_row_count: index => frames[index]?.results?.length || 0,
        sr_frame_json_len: index => encodedFrame(index).byteLength,
        sr_frame_json_write: (index, ptr, len) => writeBytes(ptr, len, encodedFrame(index)),
        sr_theme: () => (this.isDarkMode() ? 1 : 0),
      },
      serviceradar: {
        log: (_level, _ptr, _len) => {},
        emit_render_model: emitRenderModel,
        frame_count: () => frames.length,
        frame_status: index => (frames[index]?.status === "ok" ? 1 : 0),
        frame_row_count: index => frames[index]?.results?.length || 0,
        frame_json_len: index => encodedFrame(index).byteLength,
        frame_json_write: (index, ptr, len) => writeBytes(ptr, len, encodedFrame(index)),
        theme: () => (this.isDarkMode() ? 1 : 0),
        host_version: () => encoder.encode("dashboard-host-v1").byteLength,
      },
      wasi_snapshot_preview1: {
        fd_write: () => 0,
        proc_exit: code => {
          throw new Error(`renderer exited with code ${code}`)
        },
        random_get: (ptr, len) => {
          const memory = wasmContext.memory || wasmContext.instance?.exports?.memory
          if (!memory) return 1
          crypto.getRandomValues(new Uint8Array(memory.buffer, ptr, len))
          return 0
        },
      },
    }
  },

  validateInterfaceVersion(host) {
    const declared = host?.package?.renderer?.interface_version || host?.host?.interface_version

    if (declared !== DASHBOARD_WASM_INTERFACE) {
      throw new Error(`unsupported dashboard WASM interface: ${declared || "missing"}`)
    }
  },

  validateExports(instance, host) {
    const exports = instance?.exports || {}
    const declared = host?.package?.renderer?.exports

    if (Array.isArray(declared) && declared.length > 0) {
      const missing = declared.filter(name => typeof exports[name] === "undefined")
      if (missing.length > 0) throw new Error(`renderer missing exports: ${missing.join(", ")}`)
    }
  },

  invokeEntrypoint(instance, host) {
    const exports = instance?.exports || {}
    const configured = host?.package?.renderer?.entrypoint

    if (typeof exports.sr_dashboard_init_json === "function") {
      this.callJsonEntrypoint(instance, exports.sr_dashboard_init_json, host)
      return
    }

    if (typeof exports.sr_dashboard_render_json === "function") {
      this.callJsonEntrypoint(instance, exports.sr_dashboard_render_json, host)
      return
    }

    const candidates = [configured, "sr_dashboard_init", "render"].filter(Boolean)

    for (const name of candidates) {
      if (typeof exports[name] === "function") {
        exports[name]()
        return
      }
    }
  },

  callJsonEntrypoint(instance, entrypoint, host) {
    const exports = instance?.exports || {}
    const memory = exports.memory

    if (!memory || typeof exports.alloc_bytes !== "function") {
      throw new Error("renderer JSON ABI requires memory and alloc_bytes exports")
    }

    const payload = new TextEncoder().encode(JSON.stringify(host))
    const ptr = exports.alloc_bytes(payload.length)

    try {
      new Uint8Array(memory.buffer, ptr, payload.length).set(payload)
      entrypoint(ptr, payload.length)
    } finally {
      if (typeof exports.free_bytes === "function") {
        exports.free_bytes(ptr, payload.length)
      }
    }
  },

  renderModel(model, host) {
    const kind = String(model?.kind || "deck_map")

    if (kind !== "deck_map") {
      this.renderState("error", `unsupported render model kind: ${kind}`)
      return
    }

    this._host = host
    this._renderModel = model
    this._webglUnavailable = false
    this.ensureMapContainers()
    this.createMap()
  },

  ensureMapContainers() {
    if (this._mapContainer && this._deckContainer) return

    this.el.innerHTML = ""
    this.el.classList.add("sr-dashboard-wasm-map")

    this._mapContainer = document.createElement("div")
    this._mapContainer.className = "absolute inset-0"

    this._deckContainer = document.createElement("div")
    this._deckContainer.className = "absolute inset-0"

    this.el.appendChild(this._mapContainer)
    this.el.appendChild(this._deckContainer)
  },

  createMap() {
    const mapbox = this._host?.mapbox || {}
    const useMapbox = Boolean(mapbox.enabled) && looksLikeMapboxPublicToken(mapbox.access_token)
    const style = this.currentStyle(useMapbox)
    const initialViewState = this.initialViewState()

    if (useMapbox) {
      mapboxgl.accessToken = mapbox.access_token
    }

    try {
      this._map = new mapboxgl.Map({
        container: this._mapContainer,
        style,
        center: [initialViewState.longitude, initialViewState.latitude],
        zoom: initialViewState.zoom,
        bearing: initialViewState.bearing,
        pitch: initialViewState.pitch,
        attributionControl: false,
        interactive: this._renderModel?.interactive !== false,
      })
    } catch (error) {
      console.warn("[DashboardWasmHost] map initialization failed:", error?.message || error)
      this.handleRenderingUnavailable()
      return
    }

    this._map.addControl(new mapboxgl.NavigationControl({showCompass: true}), "top-right")
    this._map.once("webglcontextlost", () => this.handleRenderingUnavailable())
    this._map.getCanvas?.()?.addEventListener?.("webglcontextlost", () => this.handleRenderingUnavailable(), {once: true})

    this._map.on("load", () => {
      this.stampStyleUrl(this.currentStyleId(useMapbox))
      this.createDeck(initialViewState)
      this.fitToLayerData()
      this.resizeMap()
    })

    this._map.on("error", (event) => {
      const msg = event?.error?.message || event?.message || "Unknown map error"
      console.warn("[DashboardWasmHost] map error:", msg)

      if (msg.toLowerCase().includes("webgl") || msg.toLowerCase().includes("context lost")) {
        this.handleRenderingUnavailable()
      }
    })
  },

  createDeck(initialViewState) {
    try {
      this._viewState = initialViewState
      this._deck = new Deck({
        parent: this._deckContainer,
        views: new MapView({repeat: true}),
        controller: this._renderModel?.interactive !== false,
        initialViewState,
        onError: (error) => {
          console.warn("[DashboardWasmHost] deck error:", error?.message || error)
          this.handleRenderingUnavailable()
          return true
        },
        onViewStateChange: ({viewState}) => this.setViewState(viewState, true),
        onClick: (info) => this.handleLayerClick(info),
        onHover: (info) => {
          this.el.style.cursor = info?.object ? "pointer" : ""
        },
        layers: this.deckLayers(),
      })
    } catch (error) {
      console.warn("[DashboardWasmHost] deck initialization failed:", error?.message || error)
      this.handleRenderingUnavailable()
    }
  },

  deckLayers() {
    const layerModels = Array.isArray(this._renderModel?.layers) ? this._renderModel.layers : []

    return layerModels
      .map((layer) => this.deckLayer(layer))
      .filter(Boolean)
  },

  deckLayer(layer) {
    const type = String(layer?.type || "").toLowerCase()
    const data = this.layerData(layer)
    const id = String(layer?.id || `${type}-${Math.random().toString(16).slice(2)}`)

    if (type === "scatterplot") {
      return new ScatterplotLayer({
        id,
        data,
        pickable: layer.pickable !== false,
        opacity: numberOr(layer.opacity, 0.72),
        radiusUnits: "pixels",
        getPosition: positionAccessor(layer.position),
        getRadius: this.radiusAccessor(layer),
        getFillColor: this.colorAccessor(layer, "fill_color", [37, 99, 235, 210]),
        getLineColor: colorOr(layer.line_color, [255, 255, 255, 220]),
        lineWidthUnits: "pixels",
        getLineWidth: numberOr(layer.line_width, 1),
      })
    }

    if (type === "text") {
      return new TextLayer({
        id,
        data,
        pickable: layer.pickable === true,
        getPosition: positionAccessor(layer.position),
        getText: (row) => String(getField(row, layer.text_field) ?? layer.text ?? ""),
        getSize: numberOr(layer.size, 12),
        getPixelOffset: Array.isArray(layer.pixel_offset) ? layer.pixel_offset : [0, -16],
        getColor: this.colorAccessor(layer, "color", [15, 23, 42, 255]),
        getTextAnchor: layer.text_anchor || "middle",
        getAlignmentBaseline: layer.alignment_baseline || "bottom",
        background: layer.background !== false,
        getBackgroundColor: colorOr(layer.background_color, [255, 255, 255, 235]),
        backgroundPadding: Array.isArray(layer.background_padding) ? layer.background_padding : [6, 3],
      })
    }

    if (type === "line") {
      return new LineLayer({
        id,
        data,
        pickable: layer.pickable === true,
        getSourcePosition: positionAccessor(layer.source_position),
        getTargetPosition: positionAccessor(layer.target_position),
        getColor: this.colorAccessor(layer, "color", [59, 130, 246, 190]),
        getWidth: numberOr(layer.width, 2),
      })
    }

    if (type === "arc") {
      return new ArcLayer({
        id,
        data,
        pickable: layer.pickable === true,
        getSourcePosition: positionAccessor(layer.source_position),
        getTargetPosition: positionAccessor(layer.target_position),
        getSourceColor: colorOr(layer.source_color, [34, 197, 94, 180]),
        getTargetColor: colorOr(layer.target_color, [59, 130, 246, 180]),
        getWidth: numberOr(layer.width, 2),
      })
    }

    console.warn("[DashboardWasmHost] unsupported deck layer type:", type)
    return null
  },

  layerData(layer) {
    if (Array.isArray(layer?.data)) return layer.data.slice(0, MAX_INLINE_LAYER_ROWS)

    const frameId = layer?.data_frame || layer?.frame
    const frames = Array.isArray(this._host?.package?.frames) ? this._host.package.frames : []
    const frame = frames.find((item) => item?.id === frameId)
    const results = Array.isArray(frame?.results) ? frame.results : []
    return results.slice(0, MAX_INLINE_LAYER_ROWS)
  },

  radiusAccessor(layer) {
    const radius = numberOr(layer.radius, null)
    if (radius !== null) return radius

    const field = layer.radius_field
    const scale = numberOr(layer.radius_scale, 1)
    const min = numberOr(layer.radius_min, 5)
    const max = numberOr(layer.radius_max, 24)
    const sqrt = layer.radius_sqrt !== false

    return (row) => {
      const value = numberOr(getField(row, field), 0)
      const scaled = (sqrt ? Math.sqrt(Math.max(value, 0)) : value) * scale
      return clamp(scaled, min, max)
    }
  },

  colorAccessor(layer, key, fallback) {
    const staticColor = colorOr(layer[key], null)
    if (staticColor) return staticColor

    const field = layer[`${key}_field`] || layer.color_field
    const colorMap = layer[`${key}_map`] || layer.color_map || {}
    const defaultColor = colorOr(layer[`default_${key}`] || layer.default_color, fallback)

    if (!field || typeof colorMap !== "object" || Array.isArray(colorMap)) return defaultColor

    return (row) => colorOr(colorMap[String(getField(row, field))], defaultColor)
  },

  handleLayerClick(info) {
    const layerModel = this.layerModelFor(info?.layer?.id)
    const row = info?.object
    if (!row || !layerModel || !this._map) return

    if (layerModel?.popup !== false) {
      const position = info.coordinate || positionAccessor(layerModel.position)(row)
      if (!isFinitePosition(position)) return

      try {
        this._popup?.remove()
      } catch (_error) {}

      this._popup = new mapboxgl.Popup({offset: 18, closeButton: true})
        .setLngLat(position)
        .setHTML(this.popupHtml(row, layerModel.popup || {}))
        .addTo(this._map)
    }
  },

  layerModelFor(id) {
    const layers = Array.isArray(this._renderModel?.layers) ? this._renderModel.layers : []
    return layers.find((layer) => String(layer?.id) === String(id))
  },

  popupHtml(row, popup) {
    const title = getField(row, popup.title_field) || popup.title || getField(row, "name") || getField(row, "id") || "Asset"
    const fields = Array.isArray(popup.fields) && popup.fields.length > 0 ? popup.fields : this.defaultPopupFields(row)
    const rows = fields
      .map((field) => {
        const label = field.label || field.field
        const value = getField(row, field.field)
        if (value === undefined || value === null || value === "") return ""
        return `<div class="flex justify-between gap-4 border-t border-base-300 py-1.5 text-xs"><span class="text-base-content/60">${escapeHtml(label)}</span><strong class="text-right font-medium">${escapeHtml(value)}</strong></div>`
      })
      .join("")

    return `<div class="min-w-56 max-w-80 rounded-box bg-base-100 text-base-content"><div class="pb-2 text-sm font-semibold">${escapeHtml(title)}</div>${rows}</div>`
  },

  defaultPopupFields(row) {
    return Object.keys(row || {})
      .filter((key) => !["latitude", "longitude", "lat", "lng"].includes(key))
      .slice(0, 8)
      .map((key) => ({label: key, field: key}))
  },

  initialViewState() {
    const view = this._renderModel?.view_state || {}

    return {
      longitude: numberOr(view.longitude, -98),
      latitude: numberOr(view.latitude, 39),
      zoom: numberOr(view.zoom, 2.8),
      bearing: numberOr(view.bearing, 0),
      pitch: numberOr(view.pitch, 0),
    }
  },

  setViewState(viewState, syncMap) {
    this._viewState = {
      longitude: numberOr(viewState.longitude, -98),
      latitude: numberOr(viewState.latitude, 39),
      zoom: numberOr(viewState.zoom, 2.8),
      bearing: numberOr(viewState.bearing, 0),
      pitch: numberOr(viewState.pitch, 0),
    }

    this._deck?.setProps({viewState: this._viewState})

    if (syncMap && this._map) {
      this._map.jumpTo({
        center: [this._viewState.longitude, this._viewState.latitude],
        zoom: this._viewState.zoom,
        bearing: this._viewState.bearing,
        pitch: this._viewState.pitch,
      })
    }
  },

  fitToLayerData() {
    if (this._renderModel?.fit_bounds === false || !this._map) return

    const positions = []

    for (const layer of this._renderModel?.layers || []) {
      const getPosition = positionAccessor(layer.position)

      for (const row of this.layerData(layer)) {
        const position = getPosition(row)
        if (isFinitePosition(position)) positions.push(position)
      }
    }

    if (positions.length === 0) return

    if (positions.length === 1) {
      const [longitude, latitude] = positions[0]
      this.setViewState({longitude, latitude, zoom: 6, bearing: 0, pitch: 0}, true)
      return
    }

    const bounds = positions.reduce((acc, coord) => acc.extend(coord), new mapboxgl.LngLatBounds(positions[0], positions[0]))
    this._map.fitBounds(bounds, {padding: 72, duration: 0, maxZoom: numberOr(this._renderModel?.max_fit_zoom, 8)})
    this.setViewState(
      {
        longitude: this._map.getCenter().lng,
        latitude: this._map.getCenter().lat,
        zoom: this._map.getZoom(),
        bearing: this._map.getBearing(),
        pitch: this._map.getPitch(),
      },
      false,
    )
  },

  currentStyle(useMapbox = null) {
    const mapbox = this._host?.mapbox || {}
    const enabled = useMapbox === null ? Boolean(mapbox.enabled) && looksLikeMapboxPublicToken(mapbox.access_token) : useMapbox
    if (!enabled) return osmRasterStyle()
    return this.isDarkMode() ? mapbox.style_dark || DEFAULT_DARK_STYLE : mapbox.style_light || DEFAULT_LIGHT_STYLE
  },

  currentStyleId(useMapbox = null) {
    const mapbox = this._host?.mapbox || {}
    const enabled = useMapbox === null ? Boolean(mapbox.enabled) && looksLikeMapboxPublicToken(mapbox.access_token) : useMapbox
    if (!enabled) return OSM_STYLE_ID
    return this.isDarkMode() ? mapbox.style_dark || DEFAULT_DARK_STYLE : mapbox.style_light || DEFAULT_LIGHT_STYLE
  },

  isDarkMode() {
    const theme =
      document.documentElement.getAttribute("data-theme") || document.body?.getAttribute?.("data-theme") || ""

    if (String(theme).toLowerCase() === "dark") return true
    if (String(theme).toLowerCase() === "light") return false

    try {
      const colorScheme = window.getComputedStyle(document.documentElement).colorScheme
      if (colorScheme.includes("dark")) return true
      if (colorScheme.includes("light")) return false
    } catch (_error) {}

    return Boolean(window.matchMedia?.("(prefers-color-scheme: dark)")?.matches)
  },

  applyThemeStyle() {
    if (!this._map) return

    const desiredId = this.currentStyleId()
    if (this.styleUrlFromMeta() === desiredId) return

    this._map.setStyle(this.currentStyle(), {diff: true})
    this._map.once("style.load", () => {
      this.stampStyleUrl(desiredId)
      this._deck?.setProps({layers: this.deckLayers()})
    })
  },

  styleUrlFromMeta() {
    try {
      return this._map?.getStyle?.()?.metadata?.sr_style_url
    } catch (_error) {
      return null
    }
  },

  stampStyleUrl(url) {
    try {
      const style = this._map.getStyle()
      style.metadata = {...(style.metadata || {}), sr_style_url: url}
    } catch (_error) {}
  },

  resizeMap() {
    try {
      this._map?.resize()
    } catch (_error) {}

    try {
      const rect = this.el.getBoundingClientRect()
      this._deck?.setProps({width: rect.width, height: rect.height})
      this._deck?.redraw(true)
    } catch (_error) {}
  },

  teardownMap() {
    try {
      this._popup?.remove()
    } catch (_error) {}

    try {
      this._deck?.finalize()
    } catch (_error) {}

    try {
      this._map?.remove()
    } catch (_error) {}

    this._popup = null
    this._deck = null
    this._map = null
    this._mapContainer = null
    this._deckContainer = null
  },

  handleRenderingUnavailable() {
    if (this._webglUnavailable) return

    this._webglUnavailable = true
    this.teardownMap()
    this.renderState("error", "Map rendering requires WebGL.")
  },

  renderState(kind, message) {
    const alertClass = kind === "error" ? "alert-error" : kind === "ready" ? "alert-success" : "alert-info"
    const title = kind === "error" ? "Dashboard renderer failed" : kind === "ready" ? "Dashboard renderer ready" : "Dashboard renderer"

    this.el.innerHTML = `
      <div class="flex min-h-[calc(100vh-10rem)] items-center justify-center p-6">
        <div class="alert ${alertClass} max-w-xl">
          <div>
            <div class="font-semibold">${escapeHtml(title)}</div>
            <div class="text-sm opacity-80">${escapeHtml(message)}</div>
          </div>
        </div>
      </div>
    `
  },
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;")
}

export default DashboardWasmHost
