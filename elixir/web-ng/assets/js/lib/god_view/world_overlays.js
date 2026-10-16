import {readBoundedBody, worldJson} from "./world_http"
import {tileId} from "./world_tile_cache"
import {decodeWorldOverlay, worldOverlayReservation, WORLD_OVERLAY_MIME, WORLD_OVERLAY_MAX_BYTES} from "./world_overlay_frame"

// Reserve 3MiB for four bounded HTTP assemblies and transient decoding/packing.
const MAX_RETAINED_BYTES = 5 * 1024 * 1024

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
    this.admitted = new Map()
    this.pending = new Map()
    this.polling = null
    this.binary = false
    this.modeGeneration = 0
  }

  setBinary(enabled) {
    if (this.binary === enabled) return
    this.binary = enabled
    this.modeGeneration += 1
    this.entries.clear()
    for (const job of this.pending.values()) job.controller.abort()
    this.admit()
    this.pollAgain = true
    this.onChange()
  }

  get retainedBytes() {return [...this.entries.values()].reduce((bytes, overlay) => bytes + (overlay.retainedBytes || 0), 0)}

  setVisible(geometries) {
    if (geometries.length > 64) throw new Error("Topology overlay viewport exceeds budget")
    const visible = new Map(geometries.map(geometry => [tileId(geometry.key), geometry]))
    if (visible.size === this.visible.size && [...visible].every(([id, geometry]) => this.visible.get(id) === geometry)) return
    this.visible = visible
    this.admit()
  }

  admit() {
    let remaining = MAX_RETAINED_BYTES
    this.admitted = new Map([...this.visible].sort(([, left], [, right]) => left.key.z - right.key.z || left.key.x - right.key.x || left.key.y - right.key.y)
      .filter(([, geometry]) => {
        if (!this.binary) return true
        const bytes = worldOverlayReservation(geometry)
        if (bytes > remaining) return false
        remaining -= bytes
        return true
      }))
    let changed = false
    for (const [id, overlay] of this.entries) {
      const geometry = this.admitted.get(id)
      if (!geometry || !matches(overlay, geometry)) {this.entries.delete(id); changed = true}
    }
    for (const [id, job] of this.pending) {
      if (job.geometry !== this.admitted.get(id)) job.controller.abort()
    }
    if (changed) this.onChange()
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
      const queue = [...this.admitted.values()]
      const run = async () => {
        while (queue.length > 0) {
          const geometry = queue.shift()
          if (this.admitted.get(tileId(geometry.key)) === geometry) await this.load(geometry)
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
    const modeGeneration = this.modeGeneration
    try {
      const url = `/topology/overlays/${geometry.key.layout_version}/${id}?revision=${geometry.revision}`
      let overlay
      if (this.binary) {
        const response = await fetch(url, {credentials: "same-origin", signal: controller.signal, headers: {Accept: WORLD_OVERLAY_MIME}})
        if (!response.ok || response.headers.get("content-type")?.split(";")[0] !== WORLD_OVERLAY_MIME) {
          await response.body?.cancel()
          throw new Error("Invalid topology overlay response")
        }
        overlay = decodeWorldOverlay(await readBoundedBody(response, WORLD_OVERLAY_MAX_BYTES), geometry)
      } else {
        overlay = await worldJson(url, controller.signal)
        if (!matches(overlay, geometry) || !Array.isArray(overlay.health?.glyphs) || overlay.health.glyphs.length > 128 ||
            !Array.isArray(overlay.flow?.edges) || overlay.flow.edges.length > 512) throw new Error("Invalid topology overlay")
      }
      if (this.binary && overlay.retainedBytes > worldOverlayReservation(geometry)) throw new Error("Topology overlay exceeds admitted bytes")
      if (controller.signal.aborted || modeGeneration !== this.modeGeneration || this.admitted.get(id) !== geometry) return
      this.entries.delete(id)
      this.entries.set(id, overlay)
      this.onChange()
    } catch (_error) {
      // An unavailable sample becomes unknown, never a frozen green/flow display.
      if (modeGeneration === this.modeGeneration && this.visible.get(id) === geometry && this.entries.delete(id)) this.onChange()
    } finally {
      clearTimeout(deadline)
      if (this.pending.get(id) === job) this.pending.delete(id)
    }
  }

  destroy() {
    this.visible.clear()
    this.admitted.clear()
    this.entries.clear()
    for (const job of this.pending.values()) job.controller.abort()
  }
}
