import mapboxgl from "mapbox-gl"
import {ArcLayer, LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"
import {MapboxOverlay} from "@deck.gl/mapbox"
import {Socket} from "phoenix"

const DEFAULT_LIGHT_STYLE = "mapbox://styles/mapbox/light-v11"
const DEFAULT_DARK_STYLE = "mapbox://styles/mapbox/dark-v11"
const OSM_STYLE_ID = "serviceradar-dashboard-osm-raster"
const MAX_INLINE_LAYER_ROWS = 10000
const DASHBOARD_WASM_INTERFACE = "dashboard-wasm-v1"
const DASHBOARD_BROWSER_MODULE_INTERFACE = "dashboard-browser-module-v1"
const MAX_MERCATOR_LAT = 85.05112878

function rasterStyle(dark) {
  const mode = dark ? "dark" : "light"
  const base = dark ? "dark_nolabels" : "light_nolabels"
  const labels = dark ? "dark_only_labels" : "light_only_labels"

  return {
    version: 8,
    metadata: {sr_style_url: `${OSM_STYLE_ID}-${mode}`},
    sources: {
      carto: {
        type: "raster",
        tiles: [
          `https://a.basemaps.cartocdn.com/${base}/{z}/{x}/{y}.png`,
          `https://b.basemaps.cartocdn.com/${base}/{z}/{x}/{y}.png`,
          `https://c.basemaps.cartocdn.com/${base}/{z}/{x}/{y}.png`,
          `https://d.basemaps.cartocdn.com/${base}/{z}/{x}/{y}.png`,
        ],
        tileSize: 256,
        attribution: "© OpenStreetMap contributors © CARTO",
      },
      cartoLabels: {
        type: "raster",
        tiles: [
          `https://a.basemaps.cartocdn.com/${labels}/{z}/{x}/{y}.png`,
          `https://b.basemaps.cartocdn.com/${labels}/{z}/{x}/{y}.png`,
          `https://c.basemaps.cartocdn.com/${labels}/{z}/{x}/{y}.png`,
          `https://d.basemaps.cartocdn.com/${labels}/{z}/{x}/{y}.png`,
        ],
        tileSize: 256,
        attribution: "© OpenStreetMap contributors © CARTO",
      },
    },
    layers: [
      {id: "carto", type: "raster", source: "carto"},
      {id: "carto-labels", type: "raster", source: "cartoLabels"},
    ],
  }
}

function looksLikeMapboxPublicToken(token) {
  return /^pk\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(String(token || "").trim())
}

function shouldUseMapbox(mapbox) {
  return looksLikeMapboxPublicToken(mapbox?.access_token)
}

function createSrqlApi({frames, pushQuery}) {
  const currentQuery = (frameId = "sites") => {
    const preferred = frames.find((frame) => String(frame?.id || "") === String(frameId || ""))
    return preferred?.query || frames[0]?.query || ""
  }
  const update = (query, frameQueries = {}) => pushQuery(query, frameQueries)
  const api = Object.assign(() => ({query: currentQuery()}), {
    query: currentQuery,
    update,
    updateQuery: update,
    setQuery: update,
    escapeValue: srqlValue,
    list: (values) => `(${Array.from(values || []).map(srqlValue).join(",")})`,
    build: buildSrqlQuery,
  })

  return api
}

function buildSrqlQuery(options = {}) {
  const entity = String(options.entity || "devices").trim()
  const tokens = [`in:${entity || "devices"}`]
  const search = String(options.search || "").trim()
  const searchField = String(options.searchField || "").trim()

  if (search && searchField) tokens.push(`${searchField}:%${srqlValue(search)}%`)
  appendSrqlFilters(tokens, options.include)

  for (const [field, values] of Object.entries(options.exclude || {})) {
    const list = Array.from(values || []).filter(Boolean)
    if (field && list.length > 0) tokens.push(`!${field}:${apiSrqlList(list)}`)
  }

  for (const clause of Array.from(options.where || [])) {
    const text = String(clause || "").trim()
    if (text) tokens.push(text)
  }

  const limit = Number(options.limit)
  if (Number.isInteger(limit) && limit > 0) tokens.push(`limit:${limit}`)

  return tokens.join(" ")
}

function appendSrqlFilters(tokens, filters) {
  for (const [field, values] of Object.entries(filters || {})) {
    const list = Array.from(values || []).filter(Boolean)
    if (field && list.length > 0) tokens.push(`${field}:${apiSrqlList(list)}`)
  }
}

function apiSrqlList(values) {
  return `(${Array.from(values || []).map(srqlValue).join(",")})`
}

function srqlValue(value) {
  return String(value || "").trim().replace(/\s+/g, "\\ ")
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

function callAccessor(accessor, row) {
  return typeof accessor === "function" ? accessor(row) : accessor
}

function cssColor(value) {
  const color = colorOr(value, [37, 99, 235, 210])
  const alpha = numberOr(color[3], 255) / 255
  return `rgba(${color[0]}, ${color[1]}, ${color[2]}, ${clamp(alpha, 0, 1)})`
}

function base64ToBytes(payload) {
  const decoded = atob(String(payload || ""))
  const bytes = new Uint8Array(decoded.length)

  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index)
  }

  return bytes
}

function binaryMessageBytes(message) {
  if (message instanceof ArrayBuffer) return new Uint8Array(message)
  if (message?.binary instanceof ArrayBuffer) return new Uint8Array(message.binary)
  if (ArrayBuffer.isView(message)) return new Uint8Array(message.buffer, message.byteOffset, message.byteLength)
  if (Array.isArray(message) && message[0] === "binary" && typeof message[1] === "string") return base64ToBytes(message[1])
  return new Uint8Array()
}

function parseFrameBinaryMessage(message) {
  const bytes = binaryMessageBytes(message)
  if (bytes.byteLength < 10) throw new Error("invalid dashboard frame binary payload")

  const magic = String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3])
  if (magic !== "DFB1") throw new Error("unexpected dashboard frame binary magic")

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const idSize = view.getUint16(4, false)
  const metadataSize = view.getUint32(6, false)
  const metadataStart = 10 + idSize
  const payloadStart = metadataStart + metadataSize

  if (payloadStart > bytes.byteLength) throw new Error("truncated dashboard frame binary payload")

  const decoder = new TextDecoder()
  const id = decoder.decode(bytes.slice(10, metadataStart))
  const metadata = JSON.parse(decoder.decode(bytes.slice(metadataStart, payloadStart)))
  const payload = bytes.slice(payloadStart)

  return {id, frame: {...metadata, id, payload, payload_encoding: "arraybuffer"}}
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

function currentLayerZoom(map, viewState) {
  if (map && typeof map.getZoom === "function") return numberOr(map.getZoom(), 0)
  return numberOr(viewState?.zoom, 0)
}

function lngLatToWorld(longitude, latitude, zoom = 0) {
  const lat = clamp(latitude, -MAX_MERCATOR_LAT, MAX_MERCATOR_LAT)
  const scale = 256 * 2 ** zoom
  const sinLat = Math.sin((lat * Math.PI) / 180)

  return {
    x: ((longitude + 180) / 360) * scale,
    y: (0.5 - Math.log((1 + sinLat) / (1 - sinLat)) / (4 * Math.PI)) * scale,
  }
}

const DashboardWasmHost = {
  mounted() {
    this.cancelled = false
    this._frameUpdateCallbacks = []
    this._hostPayloadSignature = null
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

  updated() {
    const signature = this.el.dataset.host || ""
    if (!signature || signature === this._hostPayloadSignature) return

    const nextHost = this.readHostPayload()
    if (nextHost && this.updateBrowserModuleHost(nextHost, signature)) return

    this.cancelled = true

    try {
      this._moduleDestroy?.()
    } catch (_error) {}

    this.disconnectFrameStream()
    this.teardownMap()
    this._frameUpdateCallbacks = []
    this._moduleDestroy = null
    this._wasmContext = null
    this._wasmInstance = null
    this._host = null
    this.cancelled = false
    this.boot()
  },

  updateBrowserModuleHost(nextHost, signature) {
    if (!this._host || this.rendererKind(this._host) !== "browser_module" || this.rendererKind(nextHost) !== "browser_module") {
      return false
    }

    const currentUrl = this._host?.package?.renderer_url || this._host?.package?.wasm_url
    const nextUrl = nextHost?.package?.renderer_url || nextHost?.package?.wasm_url
    if (!currentUrl || currentUrl !== nextUrl) return false

    const currentFrames = Array.isArray(this._host.package?.frames) ? this._host.package.frames : []
    const nextFrames = Array.isArray(nextHost.package?.frames) ? nextHost.package.frames : []
    currentFrames.splice(0, currentFrames.length, ...nextFrames)

    this._host = {
      ...this._host,
      ...nextHost,
      package: {
        ...(this._host.package || {}),
        ...(nextHost.package || {}),
        frames: currentFrames,
      },
    }
    this._hostPayloadSignature = signature
    this.notifyFrameUpdate({frames: currentFrames, host_update: true})
    return true
  },

  destroyed() {
    this.cancelled = true
    window.removeEventListener("resize", this._onResize)

    try {
      this._themeObserver?.disconnect()
    } catch (_error) {}

    try {
      this._moduleDestroy?.()
    } catch (_error) {}

    this.disconnectFrameStream()
    this.teardownMap()
  },

  async boot() {
    const host = this.readHostPayload()
    if (!host) return
    this._hostPayloadSignature = this.el.dataset.host || ""

    this.renderState("loading", "Loading dashboard renderer")

    try {
      this.validateInterfaceVersion(host)

      if (this.rendererKind(host) === "browser_module") {
        await this.bootBrowserModule(host)
        return
      }

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
      this._wasmContext = wasmContext
      this._wasmInstance = instance
      this.validateExports(instance, host)
      this.invokeEntrypoint(instance, host)

      if (wasmContext.renderModel) {
        this.renderModel(wasmContext.renderModel, host)
      } else {
        this.renderState("ready", `${host.package.name} renderer loaded`)
      }

      this.connectFrameStream(host)
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

  async bootBrowserModule(host) {
    const moduleUrl = host?.package?.renderer_url || host?.package?.wasm_url
    if (!moduleUrl) throw new Error("renderer module URL is missing")
    if (host?.package?.renderer?.trust !== "trusted") {
      throw new Error("dashboard browser module renderer must declare trust: trusted")
    }

    const module = await import(/* @vite-ignore */ moduleUrl)
    if (this.cancelled) return

    const mount = module.mountDashboard || module.default
    if (typeof mount !== "function") {
      throw new Error("dashboard browser module must export mountDashboard(hostElement, hostPayload, api)")
    }

    this.el.innerHTML = ""
    this.el.classList.add("sr-dashboard-browser-module")
    this._host = host

    const mounted = await mount(this.el, host, this.browserModuleApi(host))
    this._moduleDestroy = typeof mounted === "function" ? mounted : mounted?.destroy
    this.connectFrameStream(host)
  },

  browserModuleApi(host) {
    const capabilities = new Set(Array.isArray(host?.package?.capabilities) ? host.package.capabilities : [])
    const capabilityAllowed = (capability) => capabilities.has(String(capability || ""))
    const frames = Array.isArray(host?.package?.frames) ? host.package.frames : []
    const resolveFrame = (idOrFrame) => {
      if (idOrFrame && typeof idOrFrame === "object") return idOrFrame
      return frames.find((frame) => String(frame?.id) === String(idOrFrame))
    }
    const arrowBytes = (idOrFrame) => {
      const frame = resolveFrame(idOrFrame)
      if (!frame) return new Uint8Array()

      if (frame.encoding !== "arrow_ipc") {
        throw new Error(`dashboard frame ${frame.id || "unknown"} is ${frame.encoding || "unencoded"}, not arrow_ipc`)
      }

      if (frame.payload instanceof ArrayBuffer) return new Uint8Array(frame.payload)
      if (frame.payload instanceof Uint8Array) return frame.payload
      if (frame.payload_encoding === "base64" && typeof frame.payload === "string") return base64ToBytes(frame.payload)
      if (typeof frame.payload_base64 === "string") return base64ToBytes(frame.payload_base64)

      return new Uint8Array()
    }
    const pushSrqlQuery = (query, frameQueries = {}) => {
      const payload = {q: String(query || "")}

      if (frameQueries && typeof frameQueries === "object") {
        for (const [id, value] of Object.entries(frameQueries)) {
          const frameId = String(id || "").trim()
          const frameQuery = String(value || "").trim()
          if (frameId && frameQuery) payload[`frame_${frameId}`] = frameQuery
        }
      }

      this.updateVisibleSrqlQuery(payload.q)
      this.pushEvent("dashboard_srql_query", payload)
    }
    const srql = createSrqlApi({frames, pushQuery: pushSrqlQuery})
    const navigate = (target) => {
      if (!capabilityAllowed("navigation.open")) {
        throw new Error("dashboard capability is not approved: navigation.open")
      }

      const path = this.navigationPath(target)
      if (!path) return
      window.location.assign(path)
    }

    return {
      version: "dashboard-browser-module-host-v1",
      capabilityAllowed,
      requireCapability: (capability) => {
        if (!capabilityAllowed(capability)) throw new Error(`dashboard capability is not approved: ${capability}`)
      },
      theme: () => (this.isDarkMode() ? "dark" : "light"),
      isDarkMode: () => this.isDarkMode(),
      frames: () => frames,
      frame: (id) => resolveFrame(id),
      srql,
      setSrqlQuery: srql.update,
      navigate,
      openDevice: (uid) => navigate({type: "device", uid}),
      openDashboard: (routeSlug) => navigate({type: "dashboard", route_slug: routeSlug}),
      onFrameUpdate: (callback) => {
        if (typeof callback !== "function") return () => {}

        this._frameUpdateCallbacks.push(callback)
        return () => {
          this._frameUpdateCallbacks = this._frameUpdateCallbacks.filter((registered) => registered !== callback)
        }
      },
      arrow: {
        frameBytes: arrowBytes,
        table: async (idOrFrame) => {
          const {tableFromIPC} = await import("apache-arrow")
          return tableFromIPC(arrowBytes(idOrFrame))
        },
      },
      mapbox: () => (capabilityAllowed("map.basemap.read") ? host?.mapbox || {} : {}),
      libraries: {
        mapboxgl,
        MapboxOverlay,
        ArcLayer,
        LineLayer,
        ScatterplotLayer,
        TextLayer,
      },
      onThemeChange: (callback) => {
        if (typeof callback !== "function") return () => {}

        const observer = new MutationObserver(() => callback(this.isDarkMode() ? "dark" : "light"))
        observer.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme", "class", "style"]})
        observer.observe(document.body, {attributes: true, attributeFilter: ["data-theme", "class", "style"]})

        return () => observer.disconnect()
      },
    }
  },

  navigationPath(target) {
    if (typeof target === "string") {
      const path = target.trim()
      return path.startsWith("/") ? path : null
    }

    const type = String(target?.type || "").trim()

    if (type === "device") {
      const uid = String(target?.uid || target?.device_uid || "").trim()
      return uid ? `/devices/${encodeURIComponent(uid)}` : null
    }

    if (type === "dashboard") {
      const routeSlug = String(target?.route_slug || target?.routeSlug || "").trim()
      return routeSlug ? `/dashboards/${encodeURIComponent(routeSlug)}` : null
    }

    if (type === "path") {
      const path = String(target?.path || "").trim()
      return path.startsWith("/") ? path : null
    }

    return null
  },

  srqlUrlFor(payload) {
    const url = new URL(window.location.href)

    url.searchParams.delete("_probe")
    url.searchParams.delete("q")

    for (const key of Array.from(url.searchParams.keys())) {
      if (key.startsWith("frame_")) url.searchParams.delete(key)
    }

    if (payload.q) url.searchParams.set("q", payload.q)

    for (const [key, value] of Object.entries(payload)) {
      if (key.startsWith("frame_") && value) url.searchParams.set(key, value)
    }

    return url
  },

  currentSrqlUrlMatches(nextUrl) {
    const current = new URL(window.location.href)
    return current.pathname === nextUrl.pathname && current.search === nextUrl.search
  },

  updateVisibleSrqlQuery(query) {
    const input = document.querySelector("#srql-query-bar input[name='q']")
    if (input instanceof HTMLInputElement) input.value = String(query || "")
  },

  connectFrameStream(host) {
    const topic = host?.data_provider?.stream_topic
    const token = host?.data_provider?.stream_token
    if (!topic || !token || this._frameChannel || this.cancelled) return

    this._frameSocket = new Socket("/socket", {params: {}})
    this._frameSocket.connect()
    this._frameChannel = this._frameSocket.channel(topic, {
      token,
      refresh_interval_ms: host?.data_provider?.refresh_interval_ms,
    })

    this._frameChannel.on("frames:replace", (payload) => this.replaceFramePayload(payload))
    this._frameChannel.on("frame:binary", (payload) => this.replaceBinaryFramePayload(payload))
    this._frameChannel.on("frames:error", (payload) => {
      console.warn("[DashboardWasmHost] dashboard frame stream error:", payload?.reason || payload)
    })

    this._frameChannel.join()
      .receive("error", (reply) => {
        console.warn("[DashboardWasmHost] dashboard frame stream join failed:", reply?.reason || reply)
        this.disconnectFrameStream()
      })
  },

  disconnectFrameStream() {
    try {
      this._frameChannel?.leave()
    } catch (_error) {}

    try {
      this._frameSocket?.disconnect()
    } catch (_error) {}

    this._frameChannel = null
    this._frameSocket = null
  },

  replaceFramePayload(payload) {
    const frames = Array.isArray(payload?.frames) ? payload.frames : []
    if (frames.length === 0 || !this._host?.package) return

    const currentFrames = Array.isArray(this._host.package.frames) ? this._host.package.frames : []
    currentFrames.splice(0, currentFrames.length, ...frames)
    this._host.package.frames = currentFrames
    this._pendingBinaryFrameIds = new Set(Array.isArray(payload?.pending_binary_frame_ids) ? payload.pending_binary_frame_ids.map(String) : [])

    if (payload?.data_provider && this._host.data_provider) {
      this._host.data_provider.frames = payload.data_provider.frames || this._host.data_provider.frames
      this._host.data_provider.generated_at = payload.generated_at
    }

    if (this._pendingBinaryFrameIds.size > 0) return
    this.notifyFrameUpdate(payload)
  },

  replaceBinaryFramePayload(message) {
    if (!this._host?.package) return

    try {
      const {id, frame} = parseFrameBinaryMessage(message)
      const currentFrames = Array.isArray(this._host.package.frames) ? this._host.package.frames : []
      const index = currentFrames.findIndex((candidate) => String(candidate?.id) === String(id))

      if (index >= 0) {
        currentFrames.splice(index, 1, {...currentFrames[index], ...frame})
      } else {
        currentFrames.push(frame)
      }

      this._pendingBinaryFrameIds?.delete(String(id))
      if (!this._pendingBinaryFrameIds || this._pendingBinaryFrameIds.size === 0) {
        this.notifyFrameUpdate({frames: currentFrames})
      }
    } catch (error) {
      console.warn("[DashboardWasmHost] invalid dashboard frame binary payload:", error?.message || error)
    }
  },

  notifyFrameUpdate(payload) {
    const currentFrames = Array.isArray(this._host?.package?.frames) ? this._host.package.frames : []

    this.invokeWasmFrameUpdate()
    this.refreshDeckLayers()

    for (const callback of this._frameUpdateCallbacks || []) {
      try {
        callback({frames: currentFrames, payload})
      } catch (error) {
        console.warn("[DashboardWasmHost] frame update callback failed:", error?.message || error)
      }
    }
  },

  invokeWasmFrameUpdate() {
    const exports = this._wasmInstance?.exports || {}
    const update = exports.sr_dashboard_frames_updated || exports.sr_dashboard_update
    if (typeof update !== "function") return

    try {
      update()
    } catch (error) {
      console.warn("[DashboardWasmHost] dashboard WASM frame update failed:", error?.message || error)
    }
  },

  importsFor(host, wasmContext) {
    const encoder = new TextEncoder()
    const frames = Array.isArray(host?.package?.frames) ? host.package.frames : []
    const encodedFrame = (index) => {
      if (!Number.isInteger(index) || index < 0 || index >= frames.length) return new Uint8Array()
      return encoder.encode(JSON.stringify(frames[index]))
    }
    const framePayloadBytes = (index) => {
      if (!Number.isInteger(index) || index < 0 || index >= frames.length) return new Uint8Array()

      const frame = frames[index]
      if (frame?.encoding !== "arrow_ipc") return new Uint8Array()
      if (frame.payload instanceof ArrayBuffer) return new Uint8Array(frame.payload)
      if (frame.payload instanceof Uint8Array) return frame.payload
      if (frame.payload_encoding === "base64" && typeof frame.payload === "string") return base64ToBytes(frame.payload)
      if (typeof frame.payload_base64 === "string") return base64ToBytes(frame.payload_base64)

      return new Uint8Array()
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
        if (this._host && this._renderModel) {
          this.updateRenderModel(wasmContext.renderModel, host)
        }
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
        sr_frame_bytes_len: index => framePayloadBytes(index).byteLength,
        sr_frame_bytes_write: (index, ptr, len) => writeBytes(ptr, len, framePayloadBytes(index)),
        sr_frame_encoding: index => (frames[index]?.encoding === "arrow_ipc" ? 1 : 0),
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
        frame_bytes_len: index => framePayloadBytes(index).byteLength,
        frame_bytes_write: (index, ptr, len) => writeBytes(ptr, len, framePayloadBytes(index)),
        frame_encoding: index => (frames[index]?.encoding === "arrow_ipc" ? 1 : 0),
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
    const kind = this.rendererKind(host)

    if (kind === "browser_module" && declared !== DASHBOARD_BROWSER_MODULE_INTERFACE) {
      throw new Error(`unsupported dashboard browser module interface: ${declared || "missing"}`)
    }

    if (kind !== "browser_module" && declared !== DASHBOARD_WASM_INTERFACE) {
      throw new Error(`unsupported dashboard WASM interface: ${declared || "missing"}`)
    }
  },

  rendererKind(host) {
    return String(host?.package?.renderer?.kind || "browser_wasm")
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

    const payload = new TextEncoder().encode(JSON.stringify(this.rendererInitPayload(host)))
    const ptr = exports.alloc_bytes(payload.length)

    if (!ptr && payload.length > 0) {
      throw new Error(`renderer could not allocate init payload (${payload.length} bytes)`)
    }

    try {
      new Uint8Array(memory.buffer, ptr, payload.length).set(payload)
      entrypoint(ptr, payload.length)
    } finally {
      if (typeof exports.free_bytes === "function") {
        exports.free_bytes(ptr, payload.length)
      }
    }
  },

  rendererInitPayload(host) {
    const packagePayload = {...(host?.package || {})}
    delete packagePayload.frames

    return {
      ...host,
      package: packagePayload,
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

  updateRenderModel(model, host) {
    const kind = String(model?.kind || "deck_map")
    if (kind !== "deck_map") {
      console.warn("[DashboardWasmHost] unsupported render model update kind:", kind)
      return
    }

    this._host = host || this._host
    this._renderModel = model
    this.refreshDeckLayers()
    this.fitToLayerData()
  },

  ensureMapContainers() {
    if (this._mapContainer) return

    this.el.innerHTML = ""
    this.el.classList.add("sr-dashboard-wasm-map")

    this._mapContainer = document.createElement("div")
    this._mapContainer.className = "absolute inset-0"

    this.el.appendChild(this._mapContainer)
  },

  createMap() {
    const mapbox = this._host?.mapbox || {}
    const useMapbox = shouldUseMapbox(mapbox)
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
      this.createDeckOverlay()
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

  createDeckOverlay() {
    try {
      this._overlay = new MapboxOverlay({
        interleaved: false,
        onError: (error) => {
          console.warn("[DashboardWasmHost] deck error:", error?.message || error)
          this.handleRenderingUnavailable()
          return true
        },
        onClick: (info) => this.handleLayerClick(info),
        onHover: (info) => {
          const canvas = this._map?.getCanvas?.()
          if (canvas) canvas.style.cursor = info?.object ? "pointer" : ""
        },
        layers: this.deckLayers(),
      })
      this._map.addControl(this._overlay)
      this._map.on("moveend", () => this.refreshDeckLayers())
      this._map.on("zoomend", () => this.refreshDeckLayers())
    } catch (error) {
      console.warn("[DashboardWasmHost] deck overlay initialization failed:", error?.message || error)
      this.handleRenderingUnavailable()
    }
  },

  refreshDeckLayers() {
    try {
      this._overlay?.setProps({layers: this.deckLayers()})
    } catch (error) {
      console.warn("[DashboardWasmHost] deck refresh failed:", error?.message || error)
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
    if (!this.layerVisible(layer)) return null

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
        getText: (row) => String(row.__cluster ? row.__cluster_label || row.__cluster_count || "" : getField(row, layer.text_field) ?? layer.text ?? ""),
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
    const results = this.rawLayerData(layer)
    return this.clusteredLayerData(layer, results)
  },

  rawLayerData(layer) {
    if (Array.isArray(layer?.data)) return layer.data.slice(0, MAX_INLINE_LAYER_ROWS)

    const frameId = layer?.data_frame || layer?.frame
    const frames = Array.isArray(this._host?.package?.frames) ? this._host.package.frames : []
    const frame = frames.find((item) => item?.id === frameId)
    const results = Array.isArray(frame?.results) ? frame.results : []
    return results.slice(0, MAX_INLINE_LAYER_ROWS)
  },

  clusteredLayerData(layer, rows) {
    const cluster = layer?.cluster
    if (!cluster || cluster.enabled === false) return rows

    const zoom = currentLayerZoom(this._map, this._viewState || this.initialViewState())
    if (zoom >= numberOr(cluster.disable_at_zoom, 7)) return rows

    const getPosition = positionAccessor(layer.position)
    const radius = Math.max(8, numberOr(cluster.radius_pixels || cluster.max_radius_pixels, 50))
    const buckets = new Map()
    const bucketKey = (point) => `${Math.floor(point.x / radius)}:${Math.floor(point.y / radius)}`
    const aggregateFields = Array.isArray(cluster.aggregate_fields)
      ? cluster.aggregate_fields
      : ["ap_count", "up_count", "down_count", "wlc_count"]

    for (const row of rows) {
      const position = getPosition(row)
      if (!isFinitePosition(position)) continue

      const point = this.projectClusterPoint(position, zoom)
      const key = bucketKey(point)
      const bucket = buckets.get(key) || {
        rows: [],
        longitudeSum: 0,
        latitudeSum: 0,
        xSum: 0,
        ySum: 0,
        aggregates: {},
      }

      bucket.rows.push(row)
      bucket.longitudeSum += position[0]
      bucket.latitudeSum += position[1]
      bucket.xSum += point.x
      bucket.ySum += point.y

      for (const field of aggregateFields) {
        bucket.aggregates[field] = numberOr(bucket.aggregates[field], 0) + numberOr(getField(row, field), 0)
      }

      buckets.set(key, bucket)
    }

    return Array.from(buckets.values()).map((bucket) => {
      if (bucket.rows.length === 1) return bucket.rows[0]

      const count = bucket.rows.length
      const representative = bucket.rows[0] || {}
      const clustered = {
        ...representative,
        __cluster: true,
        __cluster_count: count,
        __cluster_label: String(count),
        __cluster_rows: bucket.rows,
        longitude: bucket.longitudeSum / count,
        latitude: bucket.latitudeSum / count,
      }

      for (const [field, value] of Object.entries(bucket.aggregates)) {
        clustered[`__cluster_${field}`] = value
        if (field in clustered) clustered[field] = value
      }

      return clustered
    })
  },

  projectClusterPoint(position, zoom) {
    if (this._map && typeof this._map.project === "function") {
      const point = this._map.project(position)
      return {x: numberOr(point.x, 0), y: numberOr(point.y, 0)}
    }

    return lngLatToWorld(position[0], position[1], zoom)
  },

  layerVisible(layer) {
    const zoom = currentLayerZoom(this._map, this._viewState || this.initialViewState())
    const minZoom = Number(layer?.min_zoom ?? layer?.minZoom)
    const maxZoom = Number(layer?.max_zoom ?? layer?.maxZoom)

    if (Number.isFinite(minZoom) && zoom < minZoom) return false
    if (Number.isFinite(maxZoom) && zoom > maxZoom) return false
    return true
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
      if (row?.__cluster) {
        const cluster = layer?.cluster || {}
        const clusterField = cluster.radius_field || "__cluster_count"
        const clusterScale = numberOr(cluster.radius_scale, 4)
        const clusterMin = numberOr(cluster.radius_min, 18)
        const clusterMax = numberOr(cluster.radius_max, 46)
        const clusterValue = numberOr(getField(row, clusterField), row.__cluster_count || 1)
        return clamp(14 + Math.sqrt(Math.max(clusterValue, 1)) * clusterScale, clusterMin, clusterMax)
      }

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

    return (row) => {
      const clusterColor = row?.__cluster && key === "fill_color" ? row.__cluster_fill_color || layer?.cluster?.fill_color : null
      if (clusterColor) return colorOr(clusterColor, defaultColor)
      return colorOr(colorMap[String(getField(row, field))], defaultColor)
    }
  },

  handleLayerClick(info) {
    const layerModel = this.layerModelFor(info?.layer?.id)
    const row = info?.object
    if (!row || !layerModel || !this._map) return

    if (row.__cluster) {
      const position = info.coordinate || positionAccessor(layerModel.position)(row)
      if (!isFinitePosition(position)) return

      const disableAtZoom = numberOr(layerModel?.cluster?.disable_at_zoom, 7)
      const nextZoom = Math.min(Math.max(currentLayerZoom(this._map, this._viewState) + 2, disableAtZoom), 14)
      this._map.easeTo({center: position, zoom: nextZoom, duration: 350})
      return
    }

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
        return `<div class="flex justify-between gap-4 border-t border-base-300 py-1.5 text-xs"><span class="text-base-content/60">${escapeHtml(label)}</span><strong class="max-w-48 text-right font-medium">${escapeHtml(formatPopupValue(value))}</strong></div>`
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
    const enabled = useMapbox === null ? shouldUseMapbox(mapbox) : useMapbox
    if (!enabled) return rasterStyle(this.isDarkMode())
    return this.isDarkMode() ? mapbox.style_dark || DEFAULT_DARK_STYLE : mapbox.style_light || DEFAULT_LIGHT_STYLE
  },

  currentStyleId(useMapbox = null) {
    const mapbox = this._host?.mapbox || {}
    const enabled = useMapbox === null ? shouldUseMapbox(mapbox) : useMapbox
    if (!enabled) return `${OSM_STYLE_ID}-${this.isDarkMode() ? "dark" : "light"}`
    return this.isDarkMode() ? mapbox.style_dark || DEFAULT_DARK_STYLE : mapbox.style_light || DEFAULT_LIGHT_STYLE
  },

  isDarkMode() {
    try {
      const colorScheme = window.getComputedStyle(document.documentElement).colorScheme
      if (typeof colorScheme === "string") {
        if (colorScheme.includes("dark")) return true
        if (colorScheme.includes("light")) return false
      }
    } catch (_error) {}

    const theme =
      document.documentElement.getAttribute("data-theme") || document.body?.getAttribute?.("data-theme") || ""
    const normalizedTheme = String(theme || "").toLowerCase().trim()

    if (normalizedTheme === "dark") return true
    if (normalizedTheme === "light") return false

    try {
      const background =
        (document.body && window.getComputedStyle(document.body).backgroundColor) ||
        window.getComputedStyle(document.documentElement).backgroundColor ||
        ""
      const match = String(background).match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i)

      if (match) {
        const red = Number(match[1]) / 255
        const green = Number(match[2]) / 255
        const blue = Number(match[3]) / 255
        const luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.45
      }
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
      this._overlay?.setProps({layers: this.deckLayers()})
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
      this._overlay?.setProps({layers: this.deckLayers()})
    } catch (_error) {}
  },

  teardownMap() {
    try {
      this._popup?.remove()
    } catch (_error) {}

    try {
      if (this._overlay && this._map) {
        this._map.removeControl(this._overlay)
      } else {
        this._overlay?.finalize?.()
      }
    } catch (_error) {}

    try {
      this._map?.remove()
    } catch (_error) {}

    this._popup = null
    this._overlay = null
    this._map = null
    this._mapContainer = null
    this._moduleDestroy = null
  },

  handleRenderingUnavailable() {
    if (this._webglUnavailable) return

    this._webglUnavailable = true
    this.teardownMap()

    if (this.renderSvgFallback()) return

    this.renderState("error", "Map rendering requires WebGL.")
  },

  renderSvgFallback() {
    const layers = Array.isArray(this._renderModel?.layers) ? this._renderModel.layers : []
    const scatterLayers = layers.filter((layer) => String(layer?.type || "").toLowerCase() === "scatterplot")
    const textLayers = layers.filter((layer) => String(layer?.type || "").toLowerCase() === "text")
    const points = []

    for (const layer of scatterLayers) {
      const getPosition = positionAccessor(layer.position)
      const getRadius = this.radiusAccessor(layer)
      const getFillColor = this.colorAccessor(layer, "fill_color", [37, 99, 235, 210])
      const getLineColor = this.colorAccessor(layer, "line_color", [255, 255, 255, 230])

      for (const row of this.layerData(layer)) {
        const position = getPosition(row)
        if (!isFinitePosition(position)) continue

        points.push({
          layer,
          row,
          longitude: position[0],
          latitude: position[1],
          radius: clamp(numberOr(callAccessor(getRadius, row), 8), 4, 28),
          fill: cssColor(callAccessor(getFillColor, row)),
          stroke: cssColor(callAccessor(getLineColor, row)),
        })
      }
    }

    if (points.length === 0) return false

    const width = 1000
    const height = 620
    const padding = 56
    const lngLatBounds = points.reduce(
      (acc, point) => ({
        minLng: Math.min(acc.minLng, point.longitude),
        maxLng: Math.max(acc.maxLng, point.longitude),
        minLat: Math.min(acc.minLat, point.latitude),
        maxLat: Math.max(acc.maxLat, point.latitude),
      }),
      {minLng: Infinity, maxLng: -Infinity, minLat: Infinity, maxLat: -Infinity},
    )
    const worldBoundsAtZero = [
      lngLatToWorld(lngLatBounds.minLng, lngLatBounds.maxLat, 0),
      lngLatToWorld(lngLatBounds.maxLng, lngLatBounds.minLat, 0),
    ]
    const worldSpanX = Math.max(Math.abs(worldBoundsAtZero[1].x - worldBoundsAtZero[0].x), 1)
    const worldSpanY = Math.max(Math.abs(worldBoundsAtZero[1].y - worldBoundsAtZero[0].y), 1)
    const fitZoom = Math.floor(Math.log2(Math.min((width - padding * 2) / worldSpanX, (height - padding * 2) / worldSpanY)))
    const zoom = clamp(numberOr(this._renderModel?.fallback_zoom, fitZoom), 1, 6)
    const center = lngLatToWorld((lngLatBounds.minLng + lngLatBounds.maxLng) / 2, (lngLatBounds.minLat + lngLatBounds.maxLat) / 2, zoom)
    const topLeft = {x: center.x - width / 2, y: center.y - height / 2}
    const project = (longitude, latitude) => {
      const point = lngLatToWorld(longitude, latitude, zoom)
      return [point.x - topLeft.x, point.y - topLeft.y]
    }
    const labelFor = (row) => {
      if (row.__cluster) return String(row.__cluster_label || row.__cluster_count || "")

      for (const layer of textLayers) {
        if (!this.layerVisible(layer)) continue
        const text = getField(row, layer.text_field) ?? layer.text
        if (text !== undefined && text !== null && text !== "") return String(text)
      }

      return String(getField(row, "site_code") || getField(row, "label") || "")
    }
    const tiles = this.svgTileImages(topLeft, width, height, zoom)
    const rows = points
      .map((point, index) => {
        const [x, y] = project(point.longitude, point.latitude)
        const label = labelFor(point.row)
        const clusterClass = point.row.__cluster ? "font-bold" : "font-semibold"
        const clusterLabelY = point.row.__cluster ? y + 4 : y - point.radius - 7

        return `
          <g class="sr-dashboard-svg-point cursor-pointer" data-point-index="${index}" tabindex="0" role="button" aria-label="${escapeHtml(label || "Map asset")}">
            <circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${point.radius.toFixed(1)}" fill="${point.fill}" stroke="${point.stroke}" stroke-width="2" />
            ${
              label
                ? `<text x="${x.toFixed(1)}" y="${clusterLabelY.toFixed(1)}" text-anchor="middle" class="fill-base-content text-[11px] ${clusterClass}">${escapeHtml(label)}</text>`
                : ""
            }
          </g>
        `
      })
      .join("")

    this._svgFallbackPoints = points
    this.el.innerHTML = `
      <div class="relative h-full min-h-[calc(100vh-10rem)] overflow-hidden bg-base-200">
        <svg class="absolute inset-0 h-full w-full" viewBox="0 0 ${width} ${height}" role="img" aria-label="Network asset map">
          <rect width="${width}" height="${height}" class="fill-base-200" />
          ${tiles}
          ${rows}
        </svg>
        <div class="absolute right-4 bottom-4 rounded-box border border-base-300 bg-base-100/90 px-3 py-2 text-[0.65rem] text-base-content/70 shadow">
          Raster fallback
        </div>
      </div>
    `
    this.el.querySelectorAll(".sr-dashboard-svg-point").forEach((node) => {
      node.addEventListener("click", (event) => this.showSvgFallbackPopup(event, Number(node.dataset.pointIndex)))
      node.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault()
          this.showSvgFallbackPopup(event, Number(node.dataset.pointIndex))
        }
      })
    })

    return true
  },

  svgTileImages(topLeft, width, height, zoom) {
    const dark = this.isDarkMode()
    const base = dark ? "dark_nolabels" : "light_nolabels"
    const labels = dark ? "dark_only_labels" : "light_only_labels"
    const z = Math.round(zoom)
    const tileCount = 2 ** z
    const minTileX = Math.floor(topLeft.x / 256)
    const maxTileX = Math.floor((topLeft.x + width) / 256)
    const minTileY = clamp(Math.floor(topLeft.y / 256), 0, tileCount - 1)
    const maxTileY = clamp(Math.floor((topLeft.y + height) / 256), 0, tileCount - 1)
    const subdomains = ["a", "b", "c", "d"]
    const tileUrl = (kind, x, y) => {
      const wrappedX = ((x % tileCount) + tileCount) % tileCount
      const subdomain = subdomains[Math.abs(x + y) % subdomains.length]
      return `https://${subdomain}.basemaps.cartocdn.com/${kind}/${z}/${wrappedX}/${y}.png`
    }
    const imageFor = (kind, x, y) => {
      const imageX = x * 256 - topLeft.x
      const imageY = y * 256 - topLeft.y
      return `<image href="${tileUrl(kind, x, y)}" x="${imageX.toFixed(1)}" y="${imageY.toFixed(1)}" width="256" height="256" preserveAspectRatio="none" />`
    }
    const images = []

    for (let y = minTileY; y <= maxTileY; y += 1) {
      for (let x = minTileX; x <= maxTileX; x += 1) {
        images.push(imageFor(base, x, y))
      }
    }

    for (let y = minTileY; y <= maxTileY; y += 1) {
      for (let x = minTileX; x <= maxTileX; x += 1) {
        images.push(imageFor(labels, x, y))
      }
    }

    return images.join("")
  },

  showSvgFallbackPopup(event, index) {
    const point = this._svgFallbackPoints?.[index]
    if (!point) return

    try {
      this._popup?.remove()
    } catch (_error) {}

    const popup = document.createElement("div")
    popup.className = "absolute z-10 max-w-80 rounded-box border border-base-300 bg-base-100 p-3 text-base-content shadow-xl"
    popup.innerHTML = this.popupHtml(point.row, point.layer.popup || {})

    const hostRect = this.el.getBoundingClientRect()
    const targetRect = event.currentTarget.getBoundingClientRect()
    popup.style.left = `${clamp(targetRect.left - hostRect.left + targetRect.width / 2 + 14, 12, hostRect.width - 340)}px`
    popup.style.top = `${clamp(targetRect.top - hostRect.top - 24, 12, hostRect.height - 220)}px`
    this.el.appendChild(popup)
    this._popup = popup
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

function formatPopupValue(value) {
  if (Array.isArray(value)) return value.filter((item) => item !== null && item !== undefined && item !== "").join(", ")

  if (value && typeof value === "object") {
    return Object.entries(value)
      .filter(([, item]) => item !== null && item !== undefined && item !== "")
      .map(([key, item]) => `${key}: ${item}`)
      .join(", ")
  }

  if (typeof value === "number") return Number.isInteger(value) ? value.toLocaleString() : value.toLocaleString(undefined, {maximumFractionDigits: 3})
  return value
}

export default DashboardWasmHost
