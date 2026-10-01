import WorldMapRenderer from "./js/lib/god_view/WorldMapRenderer"
import {worldTileKey, worldTileRevision} from "./js/lib/god_view/fixtures/world_tile_ipc"

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
  window.__SR_WORLD_TRANSPORT__ = {
    renderer, events, measurements,
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
