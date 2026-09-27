import {Deck, OrthographicView} from "@deck.gl/core"
import WorldTileLayer from "./js/lib/god_view/world_tile_layer"
import {GOD_VIEW_DEVICE_PROPS} from "./js/lib/god_view/lifecycle_dom_setup_methods"
import {decodeWorldTile} from "./js/lib/god_view/world_tile_decode"
import {worldTileIpc, worldTileKey} from "./js/lib/god_view/fixtures/world_tile_ipc"
import {snapshotIpcBytes} from "./js/lib/god_view/fixtures/snapshot_ipc"
import GodViewRenderer from "./js/lib/GodViewRenderer"

// GPU smoke only: invented bounded Arrow tiles. This does not stand in for the
// million-device server/HTTP/browser acceptance workload.
const status = document.querySelector("#status")
const samples = new Map()
const overlays = new Map()
let overlayRevision = 0
let unhealthy = false
let failed = false
let loads = 0
let frames = 0
let deviceType = "initializing"
let picked = "none"
let detail
let detailEl
const started = performance.now()

function report() {
  if (!failed) status.textContent = `GPU smoke: ${deviceType}; frames=${frames}; decoded tiles=${loads}; picked=${picked}; health=${unhealthy ? "unavailable" : "healthy"}; packet flow ON`
}
function fail(error) {if (failed) return; failed = true; status.textContent = `FAIL: ${error.message || error}`; status.style.color = "#ff8080"}
window.addEventListener("error", event => fail(event.error || event.message))
window.addEventListener("unhandledrejection", event => fail(event.reason))

function telemetry(tile) {
  return {layout_version: tile.key.layout_version, generation: 1, revision: tile.revision,
    health: {glyphs: [{id: "invented-router", counts: {total: 1, healthy: unhealthy ? 0 : 1, unavailable: unhealthy ? 1 : 0, unknown: 0}}]},
    flow: {edges: [{id: "invented-link", total_relations: 1, selected_relations: 1,
      forward: {status: "measured", animate: true, packets_per_second: 200, octets_per_second: 30000},
      reverse: {status: "measured", animate: true, packets_per_second: 75, octets_per_second: 10000}}]}}
}

function getTileData({index}) {
  const id = `${index.z}/${index.x}/${index.y}`
  if (samples.has(id)) return samples.get(id)
  const width = 2 ** (24 - index.z)
  const key = {...worldTileKey, ...index}
  const bytes = worldTileIpc({
    metadata: {...index, origin_x: index.x * width, origin_y: index.y * width, coordinate_scale: width / 65535, device_count: 1},
    nodes: [
      {x: 16384, y: 32768, label: "Synthetic router", details: {id: "invented-router", type: "device", cluster_member_count: 1}},
      {x: 65535, y: 49152, label: "Boundary", details: {id: "invented-boundary", type: "boundary", cluster_member_count: 0}},
    ],
    edges: [{source: 0, target: 1, details: {id: "invented-link", represented_count: 1, phase_start: 0.1, phase_end: 0.9}}],
  })
  const tile = {...decodeWorldTile(bytes, key), generation: 1}
  samples.set(id, tile)
  overlays.set(id, telemetry(tile))
  loads += 1
  return tile
}

const deck = new Deck({
  canvas: "map", width: window.innerWidth, height: window.innerHeight - 100,
  views: new OrthographicView({id: "world"}), initialViewState: {target: [256, 256, 0], zoom: 0.5},
  deviceProps: {...GOD_VIEW_DEVICE_PROPS, onError: fail}, onError: fail,
  onDeviceInitialized: device => {deviceType = device.info.type; if (deviceType !== "webgpu") fail("WebGPU required")},
  controller: {dragPan: true, scrollZoom: true, dragRotate: false}, _animate: true,
  onAfterRender: () => {frames += 1; if (frames % 30 === 0) report()},
  onClick: info => {picked = info.object?.id || "none"; report()},
})
// Acceptance-only inspection of the real deck instance; never imported by app.js.
window.__SR_WORLD_GPU_SMOKE__ = {deck, samples, get detail() {return detail}}
function render() {
  deck.setProps({layers: [new WorldTileLayer({
    id: "world-smoke", maxZoom: 16, getTileData,
    overlays, overlayRevision, onTileError: fail,
    onViewportLoad: () => {if (frames === 0 && performance.now() - started > 30000) fail("No GPU frame"); report()},
  })]})
}
document.querySelector("#telemetry").onclick = () => {
  unhealthy = !unhealthy
  for (const [id, tile] of samples) overlays.set(id, telemetry(tile))
  overlayRevision += 1
  render()
  report()
}
document.querySelector("#overview").onclick = () => deck.setProps({initialViewState: {target: [256, 256, 0], zoom: 0.5}})
document.querySelector("#zoom").onclick = () => deck.setProps({initialViewState: {target: [256, 256, 0], zoom: 5}})
document.querySelector("#detail").onclick = async () => {
  if (detail) return
  detailEl = document.createElement("div")
  detailEl.style.cssText = "position:absolute;left:0;top:100px;width:100vw;height:calc(100vh - 100px);background:#0b141a"
  document.body.append(detailEl)
  detail = new GodViewRenderer(detailEl, (name, payload) => {
    if (name === "god_view_stream_error") fail(payload.message || payload.reason)
  }, () => {})
  const nodes = ["core", "access", "endpoint"].map(role => ({label: `Synthetic ${role}`, state: 2,
    details: {id: `invented-detail-${role}`, type: role === "endpoint" ? "endpoint" : "device", device_role: role}}))
  const edges = [0, 1].map(source => ({source, target: source + 1, topologyClass: "backbone", evidenceClass: "direct-physical"}))
  try {
    await detail.mountScene(snapshotIpcBytes({nodes, edges, metadataEntries: [["payload_kind", "detail"], ["layout_algorithm", "elk"]]}),
      new globalThis.Headers({"x-sr-god-view-schema": "3", "x-sr-god-view-revision": "1", "x-sr-god-view-generated-at": "2026-01-01T00:00:00Z"}))
  } catch (error) {fail(error)}
}
document.querySelector("#close-detail").onclick = () => {
  detail?.destroy()
  detail = null
  detailEl?.remove()
}
window.addEventListener("resize", () => deck.setProps({width: innerWidth, height: innerHeight - 100}))
render()
setTimeout(() => {if (deviceType !== "webgpu" || frames === 0) fail("WebGPU did not render within 30 seconds")}, 30000)
