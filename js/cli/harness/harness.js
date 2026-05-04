const INTERFACE_VERSION = "dashboard-wasm-v1"

const params = new URLSearchParams(window.location.search)
const inputs = {
  manifest: document.querySelector("#manifest"),
  wasm: document.querySelector("#wasm"),
  frames: document.querySelector("#frames"),
  settings: document.querySelector("#settings"),
}
const statusEl = document.querySelector("#status")
const outputEl = document.querySelector("#output")

for (const [key, input] of Object.entries(inputs)) {
  input.value = params.get(key) || ""
}

document.querySelector("#run").addEventListener("click", () => {
  run().catch((error) => renderError(error))
})

if (inputs.manifest.value && inputs.wasm.value) {
  run().catch((error) => renderError(error))
}

async function run() {
  status("Loading package")
  outputEl.textContent = ""

  const manifest = await fetchJson(requiredUrl("manifest"), "manifest")
  validateManifest(manifest)

  const settings = inputs.settings.value ? await fetchJson(inputs.settings.value, "settings") : {}
  validateSettings(manifest.settings_schema || {}, settings)

  const frames = inputs.frames.value ? await fetchJson(inputs.frames.value, "frames") : []
  if (!Array.isArray(frames)) throw new Error("frames JSON must be an array")

  const rendererUrl = requiredUrl("wasm")
  const rendererBytes = await fetchBytes(rendererUrl)
  await verifyDigest(manifest.renderer.sha256, rendererBytes)

  const host = {
    host: {version: "dashboard-host-v1", interface_version: INTERFACE_VERSION},
    data_provider: {
      version: "dashboard-data-v1",
      frames: frames.map((frame) => ({
        id: frame.id,
        status: frame.status,
        encoding: frame.encoding,
        requested_encoding: frame.requested_encoding,
        row_count: Array.isArray(frame.results) ? frame.results.length : 0,
      })),
    },
    instance: {
      id: "local-dev",
      name: manifest.name,
      route_slug: "local-dev",
      placement: "custom",
      settings,
    },
    package: {
      id: "local-dev",
      dashboard_id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      vendor: manifest.vendor,
      capabilities: manifest.capabilities || [],
      renderer: manifest.renderer,
      data_frames: manifest.data_frames || [],
      frames,
      renderer_url: rendererUrl,
      wasm_url: rendererUrl,
    },
  }

  if (manifest.renderer.kind === "browser_module") {
    status("Importing browser module")
    const module = await import(rendererUrl)
    const mount = module.mountDashboard || module.default
    if (typeof mount !== "function") throw new Error("browser module must export mountDashboard")
    outputEl.innerHTML = ""
    const mountRoot = document.createElement("div")
    mountRoot.style.cssText = "position:relative;height:720px;border:1px solid #334155;border-radius:8px;overflow:hidden"
    outputEl.appendChild(mountRoot)
    await mount(mountRoot, host, await browserModuleApi(host, settings))
  } else {
    status("Instantiating renderer")
    const result = await instantiateDashboardWasm(rendererBytes, host, frames)
    outputEl.textContent = JSON.stringify(result || {status: "renderer did not emit a render model"}, null, 2)
  }

  status("Renderer completed")
}

async function browserModuleApi(host, settings) {
  const capabilities = new Set(Array.isArray(host?.package?.capabilities) ? host.package.capabilities : [])
  const frames = Array.isArray(host?.package?.frames) ? host.package.frames : []
  const libraries = await loadBrowserModuleLibraries()
  const capabilityAllowed = (capability) => capabilities.has(String(capability || ""))
  const resolveFrame = (idOrFrame) => {
    if (idOrFrame && typeof idOrFrame === "object") return idOrFrame
    return frames.find((frame) => String(frame.id) === String(idOrFrame))
  }
  const srql = createSrqlApi({
    frames,
    pushQuery: (query, frameQueries = {}) => {
      const text = String(query || "")
      const overrides = Object.fromEntries(
        Object.entries(frameQueries || {}).map(([id, value]) => [String(id), String(value || "")]),
      )

      if (frames[0]) frames[0].query = text
      for (const frame of frames) {
        if (overrides[frame.id]) frame.query = overrides[frame.id]
      }

      status(`SRQL update requested: ${text}`)
      console.info("ServiceRadar dashboard SRQL update requested", {query: text, frameQueries: overrides})
    },
  })

  return {
    version: "dashboard-browser-module-host-v1",
    capabilityAllowed,
    requireCapability: (capability) => {
      if (!capabilityAllowed(capability)) throw new Error(`dashboard capability is not approved: ${capability}`)
    },
    theme: () => (window.matchMedia?.("(prefers-color-scheme: dark)")?.matches ? "dark" : "light"),
    isDarkMode: () => Boolean(window.matchMedia?.("(prefers-color-scheme: dark)")?.matches),
    frames: () => frames,
    frame: (id) => resolveFrame(id),
    srql,
    setSrqlQuery: srql.update,
    navigate: (target) => {
      if (!capabilityAllowed("navigation.open")) {
        throw new Error("dashboard capability is not approved: navigation.open")
      }

      status(`Navigation requested: ${JSON.stringify(target)}`)
      console.info("ServiceRadar dashboard navigation requested", target)
    },
    openDevice: (uid) => {
      if (!capabilityAllowed("navigation.open")) {
        throw new Error("dashboard capability is not approved: navigation.open")
      }

      status(`Device navigation requested: ${uid}`)
      console.info("ServiceRadar dashboard device navigation requested", uid)
    },
    arrow: {
      frameBytes: (idOrFrame) => {
        const frame = resolveFrame(idOrFrame)
        if (!frame?.payload || frame.payload_encoding !== "base64") return new Uint8Array()
        const decoded = atob(String(frame.payload))
        const bytes = new Uint8Array(decoded.length)
        for (let index = 0; index < decoded.length; index += 1) bytes[index] = decoded.charCodeAt(index)
        return bytes
      },
      table: () => {
        throw new Error("Arrow table decoding is provided by the ServiceRadar web host")
      },
    },
    mapbox: () => ({
      enabled: Boolean(mapboxAccessToken(settings)),
      access_token: mapboxAccessToken(settings),
      style_dark: settings?.mapbox?.style_dark || settings?.mapbox_style_dark,
      style_light: settings?.mapbox?.style_light || settings?.mapbox_style_light,
    }),
    libraries,
    onThemeChange: () => () => {},
    onFrameUpdate: () => () => {},
  }
}

function createSrqlApi({frames, pushQuery}) {
  const currentQuery = (frameId = "sites") => {
    const preferred = frames.find((frame) => String(frame?.id || "") === String(frameId || ""))
    return preferred?.query || frames[0]?.query || ""
  }
  const update = (query, frameQueries = {}) => pushQuery(query, frameQueries)

  return Object.assign(() => ({query: currentQuery()}), {
    query: currentQuery,
    update,
    updateQuery: update,
    setQuery: update,
    escapeValue: srqlValue,
    list: (values) => `(${Array.from(values || []).map(srqlValue).join(",")})`,
    build: buildSrqlQuery,
  })
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

async function loadBrowserModuleLibraries() {
  ensureStylesheet("https://api.mapbox.com/mapbox-gl-js/v3.10.0/mapbox-gl.css")

  const [mapboxModule, deckLayers, deckMapbox] = await Promise.all([
    import("https://esm.sh/mapbox-gl@3.10.0"),
    import("https://esm.sh/@deck.gl/layers@9.3.2?bundle"),
    import("https://esm.sh/@deck.gl/mapbox@9.3.2?bundle"),
  ])

  return {
    mapboxgl: mapboxModule.default || mapboxModule,
    MapboxOverlay: deckMapbox.MapboxOverlay,
    ScatterplotLayer: deckLayers.ScatterplotLayer,
    TextLayer: deckLayers.TextLayer,
  }
}

function ensureStylesheet(href) {
  if (document.querySelector(`link[href="${href}"]`)) return
  const link = document.createElement("link")
  link.rel = "stylesheet"
  link.href = href
  document.head.appendChild(link)
}

function mapboxAccessToken(settings) {
  return (
    settings?.mapbox?.access_token ||
    settings?.mapbox_access_token ||
    ""
  )
}

async function instantiateDashboardWasm(bytes, host, frames) {
  const encoder = new TextEncoder()
  const decoder = new TextDecoder()
  const context = {instance: null, memory: null, renderModel: null}
  const encodedFrame = (index) => {
    if (!Number.isInteger(index) || index < 0 || index >= frames.length) return new Uint8Array()
    return encoder.encode(JSON.stringify(frames[index]))
  }
  const framePayloadBytes = (index) => {
    if (!Number.isInteger(index) || index < 0 || index >= frames.length) return new Uint8Array()

    const frame = frames[index]
    if (frame?.encoding !== "arrow_ipc") return new Uint8Array()
    if (frame.payload instanceof Uint8Array) return frame.payload
    if (frame.payload instanceof ArrayBuffer) return new Uint8Array(frame.payload)
    if (frame.payload_encoding === "base64" && typeof frame.payload === "string") {
      const decoded = atob(frame.payload)
      const payload = new Uint8Array(decoded.length)
      for (let offset = 0; offset < decoded.length; offset += 1) payload[offset] = decoded.charCodeAt(offset)
      return payload
    }

    return new Uint8Array()
  }
  const writeBytes = (ptr, len, frameBytes) => {
    const memory = context.memory || context.instance?.exports?.memory
    if (!memory) return 0
    const writable = Math.min(Number(len) || 0, frameBytes.byteLength)
    new Uint8Array(memory.buffer, ptr, writable).set(frameBytes.slice(0, writable))
    return writable
  }
  const readJson = (ptr, len) => {
    const memory = context.memory || context.instance?.exports?.memory
    if (!memory) throw new Error("renderer memory is unavailable")
    return JSON.parse(decoder.decode(new Uint8Array(memory.buffer, ptr, len)))
  }
  const emitRenderModel = (ptr, len) => {
    context.renderModel = readJson(ptr, len)
    return 1
  }

  const imports = {
    env: {
      sr_log: (_ptr, _len) => {},
      sr_capability_allowed: (_ptr, _len) => 0,
      sr_emit_render_model: emitRenderModel,
      sr_frame_count: () => frames.length,
      sr_frame_status: (index) => (frames[index]?.status === "ok" ? 1 : 0),
      sr_frame_row_count: (index) => frames[index]?.results?.length || 0,
      sr_frame_json_len: (index) => encodedFrame(index).byteLength,
      sr_frame_json_write: (index, ptr, len) => writeBytes(ptr, len, encodedFrame(index)),
      sr_frame_bytes_len: (index) => framePayloadBytes(index).byteLength,
      sr_frame_bytes_write: (index, ptr, len) => writeBytes(ptr, len, framePayloadBytes(index)),
      sr_frame_encoding: (index) => (frames[index]?.encoding === "arrow_ipc" ? 1 : 0),
      sr_theme: () => (window.matchMedia?.("(prefers-color-scheme: dark)")?.matches ? 1 : 0),
    },
    serviceradar: {
      log: (_level, _ptr, _len) => {},
      emit_render_model: emitRenderModel,
      frame_count: () => frames.length,
      frame_status: (index) => (frames[index]?.status === "ok" ? 1 : 0),
      frame_row_count: (index) => frames[index]?.results?.length || 0,
      frame_json_len: (index) => encodedFrame(index).byteLength,
      frame_json_write: (index, ptr, len) => writeBytes(ptr, len, encodedFrame(index)),
      frame_bytes_len: (index) => framePayloadBytes(index).byteLength,
      frame_bytes_write: (index, ptr, len) => writeBytes(ptr, len, framePayloadBytes(index)),
      frame_encoding: (index) => (frames[index]?.encoding === "arrow_ipc" ? 1 : 0),
      theme: () => (window.matchMedia?.("(prefers-color-scheme: dark)")?.matches ? 1 : 0),
      host_version: () => encoder.encode("dashboard-host-v1").byteLength,
    },
    wasi_snapshot_preview1: {
      fd_write: () => 0,
      proc_exit: (code) => {
        throw new Error(`renderer exited with code ${code}`)
      },
      random_get: (ptr, len) => {
        const memory = context.memory || context.instance?.exports?.memory
        if (!memory) return 1
        crypto.getRandomValues(new Uint8Array(memory.buffer, ptr, len))
        return 0
      },
    },
  }

  const result = await WebAssembly.instantiate(bytes, imports)
  context.instance = result.instance || result
  context.memory = context.instance.exports.memory

  const exports = context.instance.exports || {}
  const entrypoint = exports.sr_dashboard_init_json || exports.sr_dashboard_render_json
  if (typeof entrypoint !== "function") {
    throw new Error("renderer must export sr_dashboard_init_json or sr_dashboard_render_json")
  }
  if (!exports.memory || typeof exports.alloc_bytes !== "function") {
    throw new Error("renderer must export memory and alloc_bytes")
  }

  const payload = encoder.encode(JSON.stringify(host))
  const ptr = exports.alloc_bytes(payload.length)

  try {
    new Uint8Array(exports.memory.buffer, ptr, payload.length).set(payload)
    entrypoint(ptr, payload.length)
  } finally {
    if (typeof exports.free_bytes === "function") exports.free_bytes(ptr, payload.length)
  }

  return context.renderModel
}

function validateManifest(manifest) {
  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) {
    throw new Error("manifest must be an object")
  }
  for (const field of ["id", "name", "version", "renderer", "data_frames", "capabilities"]) {
    if (manifest[field] === undefined || manifest[field] === null) throw new Error(`manifest missing ${field}`)
  }
  const validKind = manifest.renderer.kind === "browser_wasm" || manifest.renderer.kind === "browser_module"
  if (!validKind) throw new Error("renderer.kind must be browser_wasm or browser_module")
  const validInterface =
    manifest.renderer.interface_version === INTERFACE_VERSION ||
    manifest.renderer.interface_version === "dashboard-browser-module-v1"
  if (!validInterface) {
    throw new Error("renderer.interface_version is unsupported")
  }
  if (manifest.renderer.kind === "browser_module" && manifest.renderer.trust !== "trusted") {
    throw new Error("browser_module renderers must declare renderer.trust=trusted")
  }
  if (!/^[a-fA-F0-9]{64}$/.test(String(manifest.renderer.sha256 || ""))) {
    throw new Error("renderer.sha256 must be a 64-character hex digest")
  }
}

function validateSettings(schema, settings) {
  if (!schema || Object.keys(schema).length === 0) return
  if (schema.type !== "object") throw new Error("settings_schema.type must be object")
  if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
    throw new Error("settings must be an object")
  }

  const required = Array.isArray(schema.required) ? schema.required : []
  for (const field of required) {
    if (settings[field] === undefined) throw new Error(`settings missing ${field}`)
  }

  if (schema.additionalProperties === false) {
    const allowed = new Set(Object.keys(schema.properties || {}))
    for (const key of Object.keys(settings)) {
      if (!allowed.has(key)) throw new Error(`settings contains unsupported key ${key}`)
    }
  }
}

async function verifyDigest(expected, bytes) {
  const actual = await crypto.subtle.digest("SHA-256", bytes)
  const hex = Array.from(new Uint8Array(actual), (byte) => byte.toString(16).padStart(2, "0")).join("")
  if (hex !== String(expected).toLowerCase()) throw new Error("renderer SHA256 digest mismatch")
}

async function fetchJson(url, label) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`${label} fetch failed: ${response.status}`)
  return response.json()
}

async function fetchBytes(url) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`wasm fetch failed: ${response.status}`)
  return response.arrayBuffer()
}

function requiredUrl(key) {
  const value = inputs[key].value.trim()
  if (!value) throw new Error(`${key} URL is required`)
  return value
}

function status(message) {
  statusEl.textContent = message
}

function renderError(error) {
  status("Failed")
  outputEl.textContent = error?.stack || error?.message || String(error)
}
