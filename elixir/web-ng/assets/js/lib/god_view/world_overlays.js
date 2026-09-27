import {worldJson} from "./world_http"
import {tileId} from "./world_tile_cache"

function matches(overlay, geometry) {
  return overlay?.layout_version === geometry.key.layout_version && overlay?.generation === geometry.generation &&
    overlay?.tile_id === tileId(geometry.key) && overlay?.revision === geometry.revision
}

/** Only telemetry for the displayed, revision-fenced tiles. Never fetches geometry. */
export class WorldOverlays {
  constructor(onChange) {
    this.onChange = onChange
    this.entries = new Map()
    this.visible = new Map()
    this.pending = new Map()
    this.polling = null
  }

  setVisible(geometries) {
    if (geometries.length > 64) throw new Error("Topology overlay viewport exceeds budget")
    const visible = new Map(geometries.map(geometry => [tileId(geometry.key), geometry]))
    if (visible.size === this.visible.size && [...visible].every(([id, geometry]) => this.visible.get(id) === geometry)) return
    this.visible = visible
    for (const [id, overlay] of this.entries) {
      const geometry = this.visible.get(id)
      if (!geometry || !matches(overlay, geometry)) this.entries.delete(id)
    }
    for (const [id, job] of this.pending) {
      if (job.geometry !== this.visible.get(id)) job.controller.abort()
    }
  }

  poll() {
    if (this.polling) {
      if (this.visible !== this.pollingVisible) this.pollAgain = true
      return this.polling
    }
    this.polling = this.pollVisible().finally(() => {this.polling = null})
    return this.polling
  }

  async pollVisible() {
    do {
      this.pollAgain = false
      this.pollingVisible = this.visible
      const queue = [...this.visible.values()]
      const run = async () => {
        while (queue.length > 0) {
          const geometry = queue.shift()
          if (this.visible.get(tileId(geometry.key)) === geometry) await this.load(geometry)
        }
      }
      await Promise.all(Array.from({length: Math.min(4, queue.length)}, run))
      // A viewport change may have cancelled this round. A caller waiting for
      // the current viewport must receive its overlays without a polling gap.
    } while (this.pollAgain && this.visible.size > 0)
  }

  async load(geometry) {
    const id = tileId(geometry.key)
    const controller = new globalThis.AbortController()
    const job = {geometry, controller}
    this.pending.set(id, job)
    const deadline = setTimeout(() => controller.abort(), 10000)
    try {
      const overlay = await worldJson(`/topology/overlays/${geometry.key.layout_version}/${id}?revision=${geometry.revision}`, controller.signal)
      if (controller.signal.aborted || this.visible.get(id) !== geometry) return
      if (!matches(overlay, geometry) || !Array.isArray(overlay.health?.glyphs) || overlay.health.glyphs.length > 128 ||
          !Array.isArray(overlay.flow?.edges) || overlay.flow.edges.length > 256) throw new Error("Invalid topology overlay")
      this.entries.set(id, overlay)
      this.onChange()
    } catch (_error) {
      // An unavailable sample becomes unknown, never a frozen green/flow display.
      if (this.visible.get(id) === geometry && this.entries.delete(id)) this.onChange()
    } finally {
      clearTimeout(deadline)
      if (this.pending.get(id) === job) this.pending.delete(id)
    }
  }

  destroy() {
    this.visible.clear()
    this.entries.clear()
    for (const job of this.pending.values()) job.controller.abort()
  }
}
