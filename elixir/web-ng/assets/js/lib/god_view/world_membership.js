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
    this.clear(true)
    if (BINDING_FIELDS.some(field => typeof binding[field] !== "string" || !binding[field] ||
        new TextEncoder().encode(binding[field]).length > 128 || binding[field].includes("\0")) ||
        geometries.length > 64 || geometries.some(tile => tile.nodes.length > 128)) {
      this.onReset("Invalid membership admission")
      return
    }
    this.binding = binding
    for (const geometry of geometries) this.receipts.set(tileId(geometry.key), geometry)
  }

  receive(input) {
    if (!this.binding) return
    try {
      const frame = decodeBitmapFrame(input)
      if (frame.view_digest !== this.binding.view_digest) return
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
        }
      }
      // The old view remains untouched until the entire replacement validates.
      this.entries = frame.tiles
      this.sequence = frame.sequence
      this.total = frame.total
      this.prefixSources = frame.prefix_sources
      this.pending = false
      this.retainedBufferBytes = frame.byteLength + [...frame.tiles.values()].reduce((sum, tile) => sum + tile.counts.byteLength, 0)
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
    this.binding = null
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
