import {readBoundedBody} from "./world_http"
import {decodeWorldTile, MAX_TILE_BYTES, WORLD_EXTENT} from "./world_tile_decode"

export const tileId = ({z, x, y}) => `${z}/${x}/${y}`
const abortError = () => new globalThis.DOMException("Topology request superseded", "AbortError")

/** Geometry LRU, shared by viewport requests and a bounded neighboring-tile prefetch. */
export class WorldTileCache {
  constructor({maxEntries = 64, maxBytes = 32 * 1024 * 1024, onChange = () => {}, onRetain = () => {}} = {}) {
    if (!Number.isInteger(maxEntries) || maxEntries < 1 || maxEntries > 64 ||
        !Number.isSafeInteger(maxBytes) || maxBytes < MAX_TILE_BYTES) {
      throw new Error("Invalid topology cache budget")
    }
    this.maxEntries = maxEntries
    this.maxBytes = maxBytes
    this.onChange = onChange
    this.onRetain = onRetain
    this.entries = new Map()
    this.pending = new Map()
    this.queue = []
    this.visible = new Map()
    this.bytes = 0
    this.running = 0
    this.epoch = 0
    this.manifest = null
    this.watch = null
  }

  observe(manifest) {
    if (!manifest || !/^[0-9a-f-]{36}$/.test(manifest.layout_version) ||
        !Number.isSafeInteger(manifest.generation) || manifest.generation < 1 ||
        !Number.isSafeInteger(manifest.node_count) || manifest.node_count < 0 ||
        !Number.isSafeInteger(manifest.relation_count) || manifest.relation_count < 0 ||
        !Number.isInteger(manifest.zmax) || manifest.zmax < 0 || manifest.zmax > 24 || manifest.extent !== WORLD_EXTENT) {
      throw new Error("Invalid topology manifest")
    }
    if (manifest.bounds !== undefined && (!Array.isArray(manifest.bounds) || manifest.bounds.length !== 2 ||
        !manifest.bounds.every(point => Array.isArray(point) && point.length === 2 && point.every(value => Number.isSafeInteger(value) && value >= 0 && value <= WORLD_EXTENT)) ||
        manifest.bounds[0].some((value, axis) => value > manifest.bounds[1][axis]))) {
      throw new Error("Invalid topology bounds")
    }
    if (this.manifest?.layout_version === manifest.layout_version && this.manifest.generation >= manifest.generation) return false
    const reset = this.manifest?.layout_version !== manifest.layout_version
    this.epoch += 1
    this.abortPending()
    if (reset) {
      this.entries.clear()
      this.visible.clear()
      this.bytes = 0
      this.watch = null
    }
    this.manifest = {...manifest}
    return true
  }

  setVisible(keys) {
    if (keys.length > this.maxEntries) throw new Error("Topology viewport exceeds tile budget")
    this.visible = new Map(keys.map(key => [tileId(key), this.key(key)]))
    // Every retained tile must fit in the channel watch, including pending
    // visible tiles. Evict off-screen entries before they can become unwatched.
    for (const id of this.entries.keys()) {
      if (new Set([...this.entries.keys(), ...this.visible.keys()]).size <= 64) break
      if (!this.visible.has(id)) this.evict(id)
    }
  }

  key(index) {
    const {z, x, y} = index
    if (!this.manifest || ![z, x, y].every(Number.isInteger) || z < 0 || z > this.manifest.zmax ||
        x < 0 || y < 0 || x >= 2 ** z || y >= 2 ** z) throw new Error("Invalid topology tile key")
    return {layout_version: this.manifest.layout_version, z, x, y}
  }

  watchPayload() {
    const retained = new Map(this.visible)
    for (const [id, entry] of this.entries) {
      if (retained.size >= 64) break
      retained.set(id, entry.geometry.key)
    }
    return {
      layout_version: this.manifest.layout_version,
      tiles: [...retained].map(([id, key]) => ({z: key.z, x: key.x, y: key.y, revision: this.entries.get(id)?.geometry.revision ?? null})),
    }
  }

  acknowledgeWatch(watchId, payload) {
    if (payload.layout_version !== this.manifest.layout_version || !Number.isSafeInteger(watchId)) return
    this.watch = {id: watchId, keys: new Set(payload.tiles.map(tileId))}
  }

  invalidate(message) {
    if (message.layout_version !== this.manifest?.layout_version || message.generation !== this.manifest.generation ||
        message.watch_id !== this.watch?.id) return false
    const dirty = new Set(message.dirty_tiles || [])
    for (const [id, entry] of this.entries) {
      if (!this.watch.keys.has(id)) continue
      entry.dirty = message.reset === true || dirty.has(id)
      if (!entry.dirty) entry.geometry = {...entry.geometry, generation: message.generation}
    }
    this.onChange()
    return true
  }

  async get(index, {signal, prefetch = false} = {}) {
    if (signal?.aborted) throw abortError()
    const key = this.key(index)
    const id = tileId(key)
    const cached = this.entries.get(id)
    if (cached && !cached.dirty) {
      this.entries.delete(id)
      this.entries.set(id, cached)
      return cached.geometry
    }
    let job = this.pending.get(id)
    if (!job) {
      if (this.pending.size >= 64) throw new Error("Topology request queue is full")
      job = {id, key, epoch: this.epoch, generation: this.manifest.generation, controller: new globalThis.AbortController()}
      job.promise = new Promise((resolve, reject) => Object.assign(job, {resolve, reject}))
      this.pending.set(id, job)
      if (prefetch) this.queue.push(job)
      else this.queue.unshift(job)
      this.drain()
    }
    const geometry = await job.promise
    if (signal?.aborted) throw abortError()
    return geometry
  }

  prefetch() {
    // Foreground requests keep one of the four network slots available.
    let count = 0
    for (const key of this.visible.values()) {
      for (const [dx, dy] of [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
        const neighbor = {...key, x: key.x + dx, y: key.y + dy}
        const id = tileId(neighbor)
        if (neighbor.x < 0 || neighbor.y < 0 || neighbor.x >= 2 ** key.z || neighbor.y >= 2 ** key.z ||
            this.visible.has(id) || this.entries.has(id) || this.pending.has(id)) continue
        if (count >= 8 || this.running >= 3) return
        count += 1
        this.get(neighbor, {prefetch: true}).catch(() => {})
      }
    }
  }

  drain() {
    while (this.running < 4 && this.queue.length > 0) {
      const job = this.queue.shift()
      if (job.epoch !== this.epoch) {
        job.reject(abortError())
        continue
      }
      this.running += 1
      const deadline = setTimeout(() => job.controller.abort(), 15000)
      this.load(job).then(job.resolve, job.reject).finally(() => {
        clearTimeout(deadline)
        this.running -= 1
        if (this.pending.get(job.id) === job) this.pending.delete(job.id)
        this.drain()
      })
    }
  }

  async load(job) {
    const cached = this.entries.get(job.id)
    const response = await fetch(`/topology/tiles/${job.key.layout_version}/${job.id}`, {
      credentials: "same-origin",
      signal: job.controller.signal,
      headers: {Accept: "application/vnd.apache.arrow.file", ...(cached ? {"If-None-Match": cached.etag} : {})},
    })
    if (job.epoch !== this.epoch || job.controller.signal.aborted) throw abortError()
    if (!response.ok && response.status !== 304) throw new Error(`Topology tile HTTP ${response.status}`)
    const version = response.headers.get("x-sr-topology-layout-version")
    const generation = Number(response.headers.get("x-sr-topology-generation"))
    if (job.epoch !== this.epoch || version !== job.key.layout_version || generation !== job.generation) throw abortError()
    const etag = response.headers.get("etag")
    let geometry
    if (response.status === 304 && cached && etag === cached.etag) {
      geometry = cached.geometry
    } else {
      if (!response.ok) throw new Error(`Topology tile HTTP ${response.status}`)
      const bytes = await readBoundedBody(response, MAX_TILE_BYTES)
      geometry = decodeWorldTile(bytes, job.key)
      if (etag !== `"${version}:${geometry.revision}"`) throw new Error("Topology tile ETag mismatch")
    }
    if (job.epoch !== this.epoch || job.controller.signal.aborted) throw abortError()
    geometry = {...geometry, generation}
    // Includes Arrow buffers, decoded columns, labels and render attributes.
    const retainedBytes = geometry.byteLength * 8 + 4096
    if (retainedBytes > this.maxBytes) throw new Error("Topology cache byte budget exceeded")
    this.evict(job.id)
    this.entries.set(job.id, {geometry, etag, dirty: false, bytes: retainedBytes})
    this.bytes += retainedBytes
    this.trim()
    if (this.bytes > this.maxBytes) {
      this.evict(job.id)
      throw new Error("Topology visible tiles exceed cache budget")
    }
    this.onRetain()
    return geometry
  }

  trim() {
    while (this.entries.size > this.maxEntries || this.bytes > this.maxBytes ||
           new Set([...this.entries.keys(), ...this.visible.keys()]).size > 64) {
      const victim = [...this.entries.keys()].find(id => !this.visible.has(id))
      if (!victim) break
      this.evict(victim)
    }
  }

  evict(id) {
    const entry = this.entries.get(id)
    if (entry) this.bytes -= entry.bytes
    this.entries.delete(id)
  }

  abortPending() {
    for (const job of this.pending.values()) {
      job.controller.abort()
      job.reject(abortError())
    }
    this.pending.clear()
    this.queue = []
  }

  destroy() {
    this.epoch += 1
    this.abortPending()
    this.entries.clear()
    this.visible.clear()
    this.bytes = 0
    this.manifest = null
  }
}
