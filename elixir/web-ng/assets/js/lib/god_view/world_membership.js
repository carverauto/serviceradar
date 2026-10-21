import {BINDING_FIELDS, decodeBitmapFrame} from "./bitmap_frame"
import {tileId} from "./world_tile_cache"

/** Full-view replacements stay bounded by admitted geometry, independent of fleet size. */
export class WorldMembership {
  constructor({onChange, onAck, onReset}) {
    Object.assign(this, {onChange, onAck, onReset})
    this.entries = new Map()
    this.receipts = new Map()
    this.pending = false
    this.sequence = null
    this.total = null
    this.prefixSources = []
  }

  bind(binding, geometries) {
    if (BINDING_FIELDS.some(field => typeof binding[field] !== "string" || !binding[field] ||
        new TextEncoder().encode(binding[field]).length > 128 || binding[field].includes("\0")) ||
        geometries.length > 64 || geometries.some(tile => tile.nodes.length > 128)) {
      this.clear(true)
      this.onReset("Invalid membership admission")
      return
    }
    // A camera move changes the view digest, not the query's authority. Keep
    // the last validated view only while that identity remains unchanged.
    if (BINDING_FIELDS.some(field => field !== "view_digest" && binding[field] !== this.displayBinding?.[field])) this.clear(true)
    else this.beginView()
    this.binding = binding
    for (const geometry of geometries) this.receipts.set(tileId(geometry.key), geometry)
  }

  beginView() {
    this.binding = null
    this.sequence = null
    this.receipts.clear()
    this.pending = true
    // Repeated camera moves cannot extend an unconfirmed view indefinitely.
    if (this.entries.size > 0 && !this.viewTimer) {
      this.viewTimer = setTimeout(() => this.reset("Membership view timed out"), 10000)
    }
    this.onChange()
  }

  receive(input) {
    if (!this.binding) return
    try {
      const frame = decodeBitmapFrame(input)
      if (frame.view_digest !== this.binding.view_digest) return
      if (frame.protocol !== (this.binding.protocol ?? 1)) throw new Error("Membership protocol changed")
      if (BINDING_FIELDS.some(field => frame[field] !== this.binding[field])) {this.reset("Membership binding changed"); return}
      if (frame.kind === "reset") {this.reset("Membership server reset"); return}
      if (this.sequence !== null && frame.sequence <= this.sequence) {
        this.onAck({sequence: this.sequence.toString(), view_digest: this.binding.view_digest})
        return
      }
      if (frame.tiles.size !== this.receipts.size) throw new Error("Incomplete membership view")
      for (const [key, tile] of frame.tiles) {
        const geometry = this.receipts.get(key)
        if (!geometry || tile.revision !== geometry.revision || tile.mask.length !== geometry.nodes.length) {
          throw new Error("Membership tile receipt changed")
        }
        for (let row = 0; row < geometry.nodes.length; row += 1) {
          if (geometry.nodes[row].kind === "device" && tile.counts[row] > 1) throw new Error("Invalid device membership count")
          // A boundary may project one exact remote endpoint while contributing
          // zero devices to this tile's geometry population.
          const population = geometry.nodes[row].kind === "boundary" ? 1 : geometry.nodes[row].count
          if (tile.counts[row] > population || tile.counts[row] > frame.total) throw new Error("Invalid represented membership count")
        }
        if (frame.protocol === 2 && (tile.edgeCounts.length !== geometry.edges.length ||
            geometry.edges.some((edge, row) => tile.edgeCounts[row] > edge.count))) {
          throw new Error("Invalid relation membership count")
        }
      }
      // The old view remains untouched until the entire replacement validates.
      clearTimeout(this.viewTimer)
      this.viewTimer = null
      this.entries = frame.tiles
      this.displayBinding = this.binding
      this.sequence = frame.sequence
      this.total = frame.total
      this.prefixSources = frame.prefix_sources
      this.pending = false
      this.retainedBufferBytes = frame.byteLength + [...frame.tiles.values()].reduce((sum, tile) => sum + tile.counts.byteLength + (tile.edgeCounts?.byteLength || 0), 0)
      this.onAck({sequence: frame.sequence.toString(), view_digest: this.binding.view_digest})
      this.onChange()
    } catch (error) {this.reset(error.message)}
  }

  reset(reason) {
    const digest = this.binding?.view_digest
    this.clear(true)
    this.onReset(reason, digest)
  }

  clear(pending = false) {
    clearTimeout(this.viewTimer)
    this.viewTimer = null
    this.binding = null
    this.displayBinding = null
    this.sequence = null
    this.total = null
    this.prefixSources = []
    this.entries.clear()
    this.receipts.clear()
    this.retainedBufferBytes = 0
    this.pending = pending
    this.onChange()
  }
}
