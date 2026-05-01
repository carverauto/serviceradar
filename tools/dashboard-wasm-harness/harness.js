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

  const wasmBytes = await fetchBytes(requiredUrl("wasm"))
  await verifyDigest(manifest.renderer.sha256, wasmBytes)

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
      wasm_url: inputs.wasm.value,
    },
  }

  status("Instantiating renderer")
  const result = await instantiateDashboardWasm(wasmBytes, host, frames)
  outputEl.textContent = JSON.stringify(result || {status: "renderer did not emit a render model"}, null, 2)
  status("Renderer completed")
}

async function instantiateDashboardWasm(bytes, host, frames) {
  const encoder = new TextEncoder()
  const decoder = new TextDecoder()
  const context = {instance: null, memory: null, renderModel: null}
  const encodedFrame = (index) => {
    if (!Number.isInteger(index) || index < 0 || index >= frames.length) return new Uint8Array()
    return encoder.encode(JSON.stringify(frames[index]))
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
  if (manifest.renderer.kind !== "browser_wasm") throw new Error("renderer.kind must be browser_wasm")
  if (manifest.renderer.interface_version !== INTERFACE_VERSION) {
    throw new Error(`renderer.interface_version must be ${INTERFACE_VERSION}`)
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
