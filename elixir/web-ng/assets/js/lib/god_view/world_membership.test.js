import {createHash} from "node:crypto"
import {describe, expect, it, vi} from "vitest"
import {WorldMembership} from "./world_membership"
import {decodeBitmapFrame} from "./bitmap_frame"
import WorldMapRenderer from "./WorldMapRenderer"
import {bitmapBinding, bitmapFrame} from "./fixtures/bitmap_frame"

const geometry = {key: {z: 0, x: 0, y: 0}, revision: "synthetic-tile", nodes: [{kind: "device"}, {kind: "aggregate"}]}
const tile = {z: 0, x: 0, y: 0, revision: geometry.revision, mask: [1, 1], causal: [3, 3], availability: [0, 2], counts: [1, 9001]}
function session() {
  const state = new WorldMembership({onChange: vi.fn(), onAck: vi.fn(), onReset: vi.fn()})
  state.bind(bitmapBinding, [geometry])
  return state
}

describe("binary admitted-row membership", () => {
  it("keeps uint64 sequence precision, replaces the complete view and accepts fresh index revisions", () => {
    const state = session()
    const bytes = bitmapFrame({sequence: 9007199254740993n, total: 0xffffffff, binding: {index_epoch: "synthetic-process"}, tiles: [tile]})
    expect(createHash("sha256").update(bytes).digest("hex")).toBe("595bcf21e73507ffc8363e460d45fbec93b405f599ee00301e471756796301c7")
    const decoded = decodeBitmapFrame(bytes)
    expect(decoded.sequence).toBe(9007199254740993n)
    expect(decoded.total).toBe(0xffffffff)
    expect(decoded.tiles.get("0/0/0").mask.buffer).toBe(bytes.buffer)
    state.receive(bytes)
    expect([...state.entries.get("0/0/0").counts]).toEqual([1, 9001])
    state.receive(bitmapFrame({sequence: 9007199254740995n, binding: {index_epoch: "fresh-process", index_revision: "999"}, total: 12,
      tiles: [{...tile, mask: [0, 1], counts: [0, 12]}]}))
    expect([...state.entries.get("0/0/0").mask]).toEqual([0, 1])
    state.receive(bytes)
    expect([...state.entries.get("0/0/0").counts]).toEqual([0, 12])
    expect(state.total).toBe(12)
    expect(state.onAck).toHaveBeenLastCalledWith({sequence: "9007199254740995", view_digest: bitmapBinding.view_digest})
    expect(state.retainedBufferBytes).toBeLessThan(262144 + 32768)
    const oversizedTransport = new Uint8Array(1024 * 1024)
    oversizedTransport.set(bytes)
    expect(decodeBitmapFrame(oversizedTransport.subarray(0, bytes.length)).tiles.get("0/0/0").mask.buffer.byteLength).toBe(bytes.length)
  })

  it("rejects malformed or incomplete replacements, ignores evicted views, and releases every receipt on disable", () => {
    const state = session()
    state.receive(bitmapFrame({tiles: [tile]}))
    state.receive(bitmapFrame({sequence: 2n, binding: {view_digest: "evicted-view"}, tiles: []}))
    expect(state.sequence).toBe(1n)
    state.receive(bitmapFrame({sequence: 2n, tiles: [{...tile, revision: "wrong-receipt"}]}))
    expect(state.pending).toBe(true)
    expect(state.total).toBeNull()
    expect(state.entries.size).toBe(0)
    expect(state.onReset).toHaveBeenCalledOnce()
    state.bind(bitmapBinding, [geometry])
    state.receive(bitmapFrame({tiles: []}))
    expect(state.onReset).toHaveBeenCalledTimes(2)
    state.bind(bitmapBinding, [geometry])
    state.receive(bitmapFrame({tiles: [{...tile, counts: [2, 9001]}]}))
    expect(state.onReset).toHaveBeenCalledTimes(3)
    const malformed = bitmapFrame({tiles: [tile]})
    new DataView(malformed.buffer).setUint32(8, 0xffffffff, true)
    expect(() => decodeBitmapFrame(malformed)).toThrow("frame length")
    expect(() => decodeBitmapFrame(bitmapFrame({tiles: [{...tile, mask: [0, 1]}]}))).toThrow("row count")
    expect(() => decodeBitmapFrame(bitmapFrame({tiles: [{...tile, causal: [4, 3]}]}))).toThrow("row state")
    state.clear()
    expect(state.receipts.size).toBe(0)
    expect(state.retainedBufferBytes).toBe(0)
    expect(state.pending).toBe(false)
    expect(state.total).toBeNull()
  })

  it("stays below the frame ceiling for all 64 admitted tiles and 8192 rows", () => {
    const tiles = Array.from({length: 64}, (_, x) => ({z: 6, x, y: 0, revision: "synthetic-maximum-receipt",
      mask: Array(128).fill(1), causal: Array(128).fill(3), availability: Array(128).fill(2), counts: Array(128).fill(1)}))
    const bytes = bitmapFrame({tiles})
    expect(bytes.byteLength).toBeLessThan(65536)
    expect(decodeBitmapFrame(bytes).tiles.size).toBe(64)
  })

  it("keeps filtered HTTP control metadata bounded and discards replies after the query changes", () => {
    const renderer = {bitmapQuery: {all: []}, membershipEnabled: true, membership: {pending: true}, queryGeneration: 0,
      queryParams: WorldMapRenderer.prototype.queryParams, assertQuery: WorldMapRenderer.prototype.assertQuery}
    expect(() => renderer.queryParams({id: "synthetic-device"})).toThrow("pending")
    renderer.membership.pending = false
    const params = renderer.queryParams({id: "synthetic-device"})
    expect(new URLSearchParams(params).get("query")).toBe('{"all":[]}')
    renderer.queryGeneration += 1
    expect(() => renderer.assertQuery(params)).toThrow("query changed")
    renderer.bitmapQuery = null
    expect(() => renderer.queryParams(params)).toThrow("query changed")
    expect(renderer.queryParams({id: "synthetic-device"})).toEqual({id: "synthetic-device"})
  })

  it("backs off transient watch errors and stops retrying unsupported queries", async () => {
    vi.useFakeTimers()
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    const replies = []
    const payload = {layout_version: "synthetic-layout", tiles: [{z: 0, x: 0, y: 0, revision: geometry.revision}]}
    renderer.membershipEnabled = true
    renderer.bitmapQuery = {all: []}
    renderer.cache.manifest = {node_count: 2}
    renderer.cache.entries.set("0/0/0", {geometry})
    renderer.cache.watchPayload = () => payload
    renderer.watchSignature = JSON.stringify(payload)
    renderer.channel = {state: "joined", push: vi.fn(name => {
      const callbacks = {}
      if (name === "membership:watch") replies.push(callbacks)
      const push = {receive: (kind, callback) => {callbacks[kind] = callback; return push}}
      return push
    })}
    try {
      renderer.syncWatch()
      replies[0].error({reason: "index_not_ready"})
      renderer.syncWatch()
      expect(renderer.channel.push).toHaveBeenCalledTimes(1)
      expect(renderer.membership.pending).toBe(true)
      await vi.advanceTimersByTimeAsync(1050)
      expect(renderer.channel.push).toHaveBeenCalledTimes(2)
      replies[1].error({reason: "index_unavailable"})
      await vi.advanceTimersByTimeAsync(1050)
      expect(renderer.channel.push).toHaveBeenCalledTimes(2)
      await vi.advanceTimersByTimeAsync(1000)
      expect(renderer.channel.push).toHaveBeenCalledTimes(3)
      replies[2].ok({...bitmapBinding, projection: {mapped: 1, total: 2}})
      renderer.membership.receive(bitmapFrame({tiles: [tile]}))
      expect(renderer.membership.pending).toBe(false)
      expect(renderer.mapSummary(1)).toContain("Some geometry has no canonical device identity")
      renderer.invalidateMembership()
      renderer.syncWatch()
      replies[3].error({reason: "unsupported_predicate"})
      const sent = renderer.channel.push.mock.calls.length
      await vi.advanceTimersByTimeAsync(30000)
      renderer.syncWatch()
      expect(renderer.channel.push).toHaveBeenCalledTimes(sent)
    } finally {
      renderer.destroyed = true
      renderer.clearMembershipRetry()
      clearTimeout(renderer.watchTimer)
      renderer.membership.clear()
      vi.useRealTimers()
    }
  })
})
