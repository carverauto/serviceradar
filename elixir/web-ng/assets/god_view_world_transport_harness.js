import WorldMapRenderer from "./js/lib/god_view/WorldMapRenderer"
import {worldTileIpc, worldTileKey, worldTileRevision} from "./js/lib/god_view/fixtures/world_tile_ipc"
import {snapshotIpcBytes} from "./js/lib/god_view/fixtures/snapshot_ipc"

// An independently invented two-device HTTP fixture. The browser tests own
// HTTP and Phoenix protocol responses; the production renderer owns requests,
// tile selection, caching, picking and scene navigation.
export function mountTransportHarness() {
  document.body.replaceChildren()
  const root = document.createElement("div")
  root.style.cssText = "position:relative;width:100vw;height:100vh"
  document.body.append(root)
  const events = new Map()
  const renderer = new WorldMapRenderer(root, () => {}, (name, callback) => {
    // LiveView delivers an event to every registered callback, including the
    // overview owner and the currently mounted detail renderer.
    const previous = events.get(name)
    events.set(name, payload => {previous?.(payload); callback(payload)})
  })
  const measurements = {loads: [], frames: [], firstFrame: null}
  const load = renderer.cache.load.bind(renderer.cache)
  renderer.cache.load = async job => {
    const started = performance.now()
    const geometry = await load(job)
    measurements.loads.push(performance.now() - started)
    return geometry
  }
  const devices = [
    {id: "invented-device-a", label: "Synthetic access", x: 192, y: 192},
    {id: "invented-device-b", label: "Synthetic endpoint", x: 208, y: 216},
  ]
  window.__SR_WORLD_TRANSPORT__ = {
    renderer, events, measurements,
    tile({z, x, y}) {
      const width = 512 / 2 ** z
      const selected = devices.filter(node => node.x >= x * width && node.x < (x + 1) * width && node.y >= y * width && node.y < (y + 1) * width)
      return Array.from(worldTileIpc({
        metadata: {z, x, y, origin_x: x * width * 32768, origin_y: y * width * 32768,
          coordinate_scale: width * 32768 / 65535, device_count: selected.length},
        nodes: selected.map(node => ({x: Math.round((node.x / width - x) * 65535), y: Math.round((node.y / width - y) * 65535),
          label: node.label, details: {id: node.id, type: "device", cluster_member_count: 1}})),
        edges: selected.length === 2 ? [{source: 0, target: 1, details: {id: "invented-link", represented_count: 1, phase_start: 0, phase_end: 1}}] : [],
      }))
    },
    detail() {
      return Array.from(snapshotIpcBytes({
        nodes: devices.map(node => ({state: 2, label: node.label, details: {id: node.id, type: "device", device_role: "access"}})),
        edges: [{source: 0, target: 1, topologyClass: "backbone", evidenceClass: "direct-physical"}],
        metadataEntries: [["payload_kind", "detail"], ["layout_algorithm", "elk"]],
      }))
    },
    version: worldTileKey.layout_version,
    revision: worldTileRevision,
  }
  void renderer.mount().then(() => {
    renderer.deck.setProps({onAfterRender: () => {
      const usable = renderer.cache.entries.size > 0 && renderer.deck.props.layers[0]?.isLoaded
      const recording = measurements.recordFrames
      if ((!usable || measurements.firstFrame != null) && !recording) return
      // GPU completion, not merely CPU submission. Retained frames still count
      // while finer tiles load; first-frame admission requires usable geometry.
      renderer.deck.device.handle.queue.onSubmittedWorkDone().then(() => {
        if (usable) measurements.firstFrame ??= performance.now()
        if (recording && measurements.recordFrames) measurements.frames.push(performance.now())
      }).catch(error => renderer.failRenderer(error))
    }})
  })
}
