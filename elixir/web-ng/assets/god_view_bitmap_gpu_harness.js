import {mountTransportHarness} from "./god_view_world_transport_harness"
import {worldTileIpc, worldTileKey} from "./js/lib/god_view/fixtures/world_tile_ipc"
import {decodeWorldTile} from "./js/lib/god_view/world_tile_decode"
import {bitmapBinding, bitmapFrame} from "./js/lib/god_view/fixtures/bitmap_frame"
import {telemetryFrame} from "./js/lib/god_view/fixtures/world_overlay_frame"
import {WORLD_OVERLAY_MIME} from "./js/lib/god_view/world_overlay_frame"
import {atlasCaptureHealth, atlasCaptureInventory, atlasCaptureMatches, atlasCaptureQueryDescriptor, atlasCaptureTile} from "./js/lib/god_view/fixtures/atlas_capture"

// Synthetic transport only. The real WorldMapRenderer, Phoenix client, Arrow
// decoder and WebGPU execute unchanged. This is not a running Phoenix server.
export function mountBitmapGpuHarness() {
  const capture = new URLSearchParams(location.search).has("capture")
  let enabled = true, unavailable = false, authority = 0, sequence = 0n, watchId = 0, connection, watch, pan = 0
  const version = worldTileKey.layout_version
  const geometries = new Map()
  const samples = {tileRequests: 0, overlayRequests: 0, membershipFrames: 0, acknowledgements: 0,
    arrowBytes: 0, membershipBytes: 0, telemetryBytes: 0, arrayBufferSliceBytes: 0, gpuUploadBytes: 0,
    gpuBuffers: 0, gpuBufferBytes: 0, gpuPeakBufferBytes: 0, gpuDevices: 0, membershipDecodeSliceBytes: 0, errors: []}
  const originalFetch = window.fetch, originalSocket = window.WebSocket
  const originalSlice = ArrayBuffer.prototype.slice
  ArrayBuffer.prototype.slice = function(...args) {
    const result = originalSlice.apply(this, args)
    samples.arrayBufferSliceBytes += result.byteLength
    return result
  }
  const createBuffer = GPUDevice.prototype.createBuffer
  const destroyDevice = GPUDevice.prototype.destroy
  const deviceBuffers = new WeakMap()
  GPUDevice.prototype.createBuffer = function(descriptor) {
    const buffer = createBuffer.call(this, descriptor), destroy = buffer.destroy.bind(buffer)
    if (!deviceBuffers.has(this)) {deviceBuffers.set(this, new Set()); samples.gpuDevices += 1}
    const owned = deviceBuffers.get(this)
    samples.gpuBuffers += 1; samples.gpuBufferBytes += buffer.size
    samples.gpuPeakBufferBytes = Math.max(samples.gpuPeakBufferBytes, samples.gpuBufferBytes)
    let destroyed = false
    const release = () => {
      if (!destroyed) {destroyed = true; samples.gpuBuffers -= 1; samples.gpuBufferBytes -= buffer.size}
      owned.delete(release)
    }
    owned.add(release)
    buffer.destroy = () => {release(); destroy()}
    return buffer
  }
  GPUDevice.prototype.destroy = function() {
    destroyDevice.call(this)
    const owned = deviceBuffers.get(this)
    if (owned) {for (const release of owned) release(); deviceBuffers.delete(this); samples.gpuDevices -= 1}
  }
  const writeBuffer = GPUQueue.prototype.writeBuffer
  GPUQueue.prototype.writeBuffer = function(buffer, offset, data, dataOffset = 0, size) {
    samples.gpuUploadBytes += size === undefined ? data.byteLength - dataOffset * (data.BYTES_PER_ELEMENT || 1) : size * (data.BYTES_PER_ELEMENT || 1)
    return writeBuffer.call(this, buffer, offset, data, dataOffset, size)
  }
  window.addEventListener("error", event => samples.errors.push(event.error?.stack || event.message))
  window.addEventListener("unhandledrejection", event => samples.errors.push(String(event.reason)))

  function tile(z, x, y) {
    const id = `${z}/${x}/${y}`
    if (geometries.has(id)) return geometries.get(id)
    if (capture) {
      const result = atlasCaptureTile(z, x, y)
      geometries.set(id, result)
      return result
    }
    const width = 512 / 2 ** z
    const points = []
    for (let row = 0; row < 64; row += 1) for (let column = 0; column < 64; column += 1) {
      const px = column * 8 + 4, py = row * 8 + 4
      if (px >= x * width && px < (x + 1) * width && py >= y * width && py < (y + 1) * width) points.push({px, py, row, column})
    }
    const aggregate = points.length > 128
    const selected = aggregate ? [{px: (x + 0.5) * width, py: (y + 0.5) * width, row: y, column: x}] : points
    const bytes = worldTileIpc({metadata: {z, x, y, origin_x: x * width * 32768, origin_y: y * width * 32768,
      coordinate_scale: width * 32768 / 65535, device_count: points.length},
      nodes: selected.map(point => ({x: Math.round((point.px / width - x) * 65535), y: Math.round((point.py / width - y) * 65535),
        label: `Synthetic ${point.row}-${point.column}`, details: {id: `synthetic-${z}-${point.row}-${point.column}`,
          type: aggregate ? "aggregate" : "device", cluster_member_count: aggregate ? points.length : 1}})),
      edges: aggregate ? [] : selected.slice(1).map((_, index) => ({source: index, target: index + 1,
        details: {id: `synthetic-edge-${index}`, represented_count: 1, phase_start: 0, phase_end: 1}})),
    })
    const geometry = {...decodeWorldTile(bytes, {...worldTileKey, z, x, y}), generation: 1}
    const result = {bytes, geometry}
    geometries.set(id, result)
    return result
  }
  window.fetch = async (input, options = {}) => {
    const url = new URL(typeof input === "string" ? input : input.url, location.href)
    if (!url.pathname.startsWith("/topology/")) return originalFetch(input, options)
    if (url.pathname.endsWith("/manifest")) return Response.json({layout_version: version, generation: 1, zmax: 8,
      extent: 2 ** 24, node_count: capture ? 1024 : 4096, relation_count: capture ? 64 : 4095, bounds: [[0, 0], [2 ** 24, 2 ** 24]],
      bitmap_membership_protocol: enabled ? 1 : 0, world_overlay_protocol: enabled ? 1 : 0,
      bitmap: {ready: enabled, query: capture ? atlasCaptureQueryDescriptor : {entity_kind: "device", facets: [
        {key: "vlan", label: "Inventory VLAN", operators: ["eq", "prefix"]},
        {key: "tag:owner", label: "Device tag: owner", operators: ["eq", "prefix"]},
        {key: "vendor", label: "Vendor", operators: ["eq", "prefix"]},
      ], tag_keys: ["owner"], operators: {tag_key_prefix: true, ip_cidr: true},
      ip_sources: "current_device_and_interface_addresses",
      prefix_tags: {available: true, discovery_url: "/topology/query/prefix-tags", sources: [{source: "synthetic-prefixes", version: 1, available: true}]}}}})
    if (url.pathname === "/topology/query/prefix-tags") return Response.json({source: "synthetic-prefixes", version: 1, labels: ["Synthetic Transit", "Synthetic Access"], cursor: null})
    const parts = url.pathname.split("/").slice(-3).map(Number)
    if (parts.some(Number.isNaN)) return new Response(null, {status: 404})
    const {bytes, geometry, populations} = tile(...parts)
    if (url.pathname.startsWith("/topology/tiles/")) {
      samples.tileRequests += 1; samples.arrowBytes += bytes.byteLength
      return new Response(bytes, {headers: {"content-type": "application/vnd.apache.arrow.file",
        "x-sr-topology-layout-version": version, "x-sr-topology-generation": "1", etag: `"${version}:${geometry.revision}"`}})
    }
    samples.overlayRequests += 1
    if (!enabled) return new Response(null, {status: 503})
    if (options.headers?.Accept !== WORLD_OVERLAY_MIME) throw new Error("Expected binary telemetry request")
    const frame = telemetryFrame(geometry, {complete: true, health: populations?.map(atlasCaptureHealth)})
    samples.telemetryBytes += frame.byteLength
    return new Response(frame, {headers: {"content-type": WORLD_OVERLAY_MIME}})
  }
  const broadcast = (socket, event, payload) => {
    const topic = new TextEncoder().encode("topology:tiles"), name = new TextEncoder().encode(event)
    const frame = new Uint8Array(3 + topic.length + name.length + payload.byteLength)
    frame.set([2, topic.length, name.length]); frame.set(topic, 3); frame.set(name, 3 + topic.length)
    frame.set(payload, 3 + topic.length + name.length)
    socket.onmessage?.({data: frame.buffer})
  }
  function membershipTiles() {
    if (!watch) return null
    return watch.tiles.map(receipt => {
      const {geometry, populations} = tile(receipt.z, receipt.x, receipt.y)
      const selected = populations?.map(members => members.filter(device => watch.selected.has(device.id)))
      const counts = selected ? selected.map(members => members.length) : geometry.nodes.map(node => node.count)
      return {...receipt, mask: counts.map(count => Number(count > 0)), counts,
        causal: counts.map(() => 3), availability: selected ? selected.map(members => !members.length ? 2 :
          members.every(device => device.availability === "healthy") ? 0 : members.every(device => device.availability === "unavailable") ? 1 : 2) : counts.map(() => unavailable ? 1 : 0)}
    })
  }
  function broadcastMembership(binding, total) {
    const tiles = membershipTiles()
    if (!tiles || connection?.readyState !== 1) return
    const frame = bitmapFrame({sequence: ++sequence, total, binding, tiles})
    samples.membershipFrames += 1; samples.membershipBytes += frame.byteLength
    const before = samples.arrayBufferSliceBytes
    broadcast(connection, "membership:frame", frame)
    samples.membershipDecodeSliceBytes += samples.arrayBufferSliceBytes - before
  }
  function deliver() {
    if (!watch || !enabled || connection?.readyState !== 1) return
    broadcastMembership(watch.binding, capture ? watch.selected.size : 4096)
  }
  window.WebSocket = class {
    static OPEN = 1
    constructor() {connection = this; this.readyState = 0; setTimeout(() => {this.readyState = 1; this.onopen?.({})}, 0)}
    close() {this.readyState = 3; watch = null; this.onclose?.({code: 1006})}
    send(raw) {
      const [join, ref, topic, event, payload] = JSON.parse(raw)
      let response = {}, status = "ok"
      if (event === "phx_join") response = {layout_version: version, generation: 1}
      if (event === "tiles:watch") response = {watch_id: ++watchId}
      if (event === "membership:ack") samples.acknowledgements += 1
      if (event === "membership:unwatch") watch = null
      if (event === "membership:watch") {
        const binding = {...bitmapBinding, authority_fingerprint: `synthetic-authority-${authority}`, view_digest: `synthetic-view-${++sequence}`}
        try {
          const selected = capture ? new Set(atlasCaptureInventory.filter(device => atlasCaptureMatches(device, payload.query)).map(device => device.id)) : null
          watch = {...payload, binding, selected}; response = binding
        } catch (error) {watch = null; status = "error"; response = {reason: error.message}}
      }
      setTimeout(() => {
        this.onmessage?.({data: JSON.stringify([join, ref, topic, "phx_reply", {status, response}])})
        if (event === "membership:watch") setTimeout(deliver, 20)
      }, 0)
    }
  }
  mountTransportHarness()
  let {renderer, measurements} = window.__SR_WORLD_TRANSPORT__
  function observeErrors() {
    const failRenderer = renderer.failRenderer.bind(renderer)
    renderer.failRenderer = error => {samples.errors.push(error.message); failRenderer(error)}
  }
  observeErrors()
  const controls = document.createElement("aside")
  controls.style.cssText = "position:fixed;right:12px;bottom:12px;z-index:10000;background:#14232b;padding:10px;max-width:320px"
  const output = document.createElement("pre")
  output.style.cssText = "font-size:11px;max-height:220px;overflow:auto"
  const button = (label, action) => {const element = document.createElement("button"); element.textContent = label; element.onclick = action; controls.append(element); return element}
  button("Zoom tiles", () => renderer.setView({target: [256, 256, 0], zoom: 3}))
  button("Overview tiles", () => renderer.setView({target: [256, 256, 0], zoom: 0.5}))
  button("Pan tiles", () => {pan += 1; renderer.setView({target: [64 + pan * 97 % 384, 64 + pan * 73 % 384, 0], zoom: 3})})
  button("Change membership", () => {unavailable = !unavailable; deliver()})
  button("Toggle query", () => {window.__SR_WORLD_TRANSPORT__.events.get("god_view:set_bitmap_query")({query: renderer.bitmapQuery === null ? {all: []} : null})})
  button("Disconnect socket", () => connection?.close())
  button("Change authority", () => {
    if (!watch?.binding) return
    authority += 1
    broadcastMembership({...watch.binding, authority_fingerprint: `synthetic-authority-${authority}`}, capture ? watch.selected.size : 4096)
  })
  button("Toggle binary", async () => {enabled = !enabled; await renderer.refreshManifest(); renderer.scheduleWatch()})
  button("Measure frames", () => {measurements.frames = []; measurements.recordFrames = true; setTimeout(() => {measurements.recordFrames = false}, 3000)})
  button("Teardown renderer", () => {renderer.destroy(); controls.querySelectorAll("button").forEach(item => {item.disabled = item !== remount})})
  const remount = button("Remount renderer", () => {
    mountTransportHarness()
    ;({renderer, measurements} = window.__SR_WORLD_TRANSPORT__)
    observeErrors()
    controls.querySelectorAll("button").forEach(item => {item.disabled = false})
    remount.disabled = true
    document.body.append(controls)
  })
  remount.disabled = true
  controls.append(output)
  if (!capture) document.body.append(controls)
  function metrics() {
    return {...samples, enabled, authority, pending: renderer.membership.pending, channel: renderer.channel?.state,
      rendererMode: renderer.deviceType, rendererFailed: !!renderer.rendererFailed,
      geometryEntries: renderer.cache.entries.size, membershipEntries: renderer.membership.entries.size,
      membershipRetainedBytes: renderer.membership.retainedBufferBytes, overlayEntries: renderer.overlays.entries.size,
      overlayChargedBytes: renderer.overlays.retainedBytes, gpuInfo: renderer.deck?.device?.info,
      frameIntervals: measurements.frames.slice(1).map((time, index) => time - measurements.frames[index])}
  }
  window.__SR_BITMAP_GPU__ = {get renderer() {return renderer}, get measurements() {return measurements}, samples, metrics, refreshMembership: deliver}
  setInterval(() => {output.textContent = JSON.stringify(metrics(), null, 2)}, 250)
  window.addEventListener("pagehide", () => {
    window.fetch = originalFetch; window.WebSocket = originalSocket; ArrayBuffer.prototype.slice = originalSlice
    GPUDevice.prototype.createBuffer = createBuffer; GPUDevice.prototype.destroy = destroyDevice; GPUQueue.prototype.writeBuffer = writeBuffer
  })
}
