import {createHash} from "node:crypto"
import {describe, expect, it, vi} from "vitest"
import {WorldMembership} from "./world_membership"
import {BITMAP_FRAME_BYTES, FRAME_FIELDS, decodeBitmapFrame} from "./bitmap_frame"
import WorldMapRenderer from "./WorldMapRenderer"
import {bitmapBinding, bitmapFrame} from "./fixtures/bitmap_frame"
import {worldTileIpc, worldTileKey, worldTileRevision} from "./fixtures/world_tile_ipc"

const geometry = {key: {z: 0, x: 0, y: 0}, revision: "synthetic-tile", nodes: [{kind: "device", count: 1}, {kind: "aggregate", count: 9001}]}
const tile = {z: 0, x: 0, y: 0, revision: geometry.revision, mask: [1, 1], causal: [3, 3], availability: [0, 2], counts: [1, 9001]}
function session() {
  const state = new WorldMembership({onChange: vi.fn(), onAck: vi.fn(), onReset: vi.fn()})
  state.bind(bitmapBinding, [geometry])
  return state
}

describe("binary admitted-row membership", () => {
  it("keeps an accepted displayed view through offscreen prefetch, then replaces the new viewport atomically", async () => {
    vi.useFakeTimers()
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    const requests = []
    renderer.channel = {state: "joined", push: vi.fn((name, payload) => {
      const reply = {name, payload}
      requests.push(reply)
      const push = {receive: (kind, callback) => {
        reply[kind] = callback
        if (name === "tiles:watch" && kind === "ok") callback({watch_id: requests.length})
        return push
      }}
      return push
    })}
    renderer.cache.observe({layout_version: worldTileKey.layout_version, generation: 1, zmax: 2,
      extent: 2 ** 24, node_count: 70000, relation_count: 90000})
    renderer.membershipEnabled = true
    renderer.bitmapQuery = {all: []}
    vi.stubGlobal("fetch", vi.fn(async url => {
      const [z, x, y] = url.split("/").slice(-3).map(Number), width = 2 ** (24 - z)
      return new Response(worldTileIpc({metadata: {z, x, y, origin_x: x * width, origin_y: y * width, coordinate_scale: width / 65535}}),
        {headers: {"x-sr-topology-layout-version": worldTileKey.layout_version, "x-sr-topology-generation": "1",
          etag: `"${worldTileKey.layout_version}:${worldTileRevision}"`}})
    }))
    const matches = key => ({...key, revision: worldTileRevision, mask: [1, 0], causal: [3, 3], availability: [2, 2], counts: [70000, 0]})
    const watches = () => requests.filter(request => request.name === "membership:watch")
    try {
      renderer.cache.setVisible([worldTileKey])
      await renderer.cache.get(worldTileKey)
      await vi.advanceTimersByTimeAsync(50)
      watches()[0].ok(bitmapBinding)
      renderer.membership.receive(bitmapFrame({total: 70000, tiles: [matches(worldTileKey)]}))
      const accepted = renderer.membership.entries
      const neighbor = {...worldTileKey, x: 0}
      await renderer.cache.get(neighbor, {prefetch: true})
      expect(renderer.membership.pending).toBe(false)
      expect(renderer.membership.entries).toBe(accepted)
      await vi.advanceTimersByTimeAsync(50)
      expect(watches()).toHaveLength(1)
      expect(requests.filter(request => request.name === "tiles:watch").at(-1).payload.tiles).toHaveLength(2)
      renderer.cache.setVisible([neighbor])
      renderer.scheduleWatch()
      expect(renderer.membership.pending).toBe(true)
      renderer.syncWatch()
      expect(watches()).toHaveLength(2)
      expect(watches()[1].payload.tiles).toEqual([{z: 1, x: 0, y: 0, revision: worldTileRevision}])
      expect(renderer.membership.pending).toBe(true)
      watches()[1].ok({...bitmapBinding, view_digest: "new-visible-view"})
      renderer.membership.receive(bitmapFrame({tiles: [matches(worldTileKey)]}))
      expect(renderer.membership.pending).toBe(true)
      renderer.membership.receive(bitmapFrame({binding: {view_digest: "new-visible-view"}, total: 70000, tiles: [matches(neighbor)]}))
      expect(renderer.membership.pending).toBe(false)
      expect([...renderer.membership.entries.keys()]).toEqual(["1/0/0"])
    } finally {
      renderer.destroyed = true; renderer.clearMembershipRetry(); clearTimeout(renderer.watchTimer)
      renderer.cache.destroy(); renderer.overlays.destroy(); vi.unstubAllGlobals(); vi.useRealTimers()
    }
  })

  it.each(["malformed", "receipt"])("backs off repeated %s frames until a complete replacement succeeds", async failure => {
    vi.useFakeTimers()
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn()), replies = []
    renderer.membershipEnabled = true; renderer.bitmapQuery = {all: []}
    renderer.cache.manifest = {layout_version: "synthetic-layout", node_count: 2}
    renderer.cache.visible.set("0/0/0", geometry.key)
    renderer.cache.entries.set("0/0/0", {geometry})
    renderer.watchSignature = JSON.stringify(renderer.cache.watchPayload())
    renderer.channel = {state: "joined", push: vi.fn(name => {
      const callbacks = {}, push = {receive: (kind, callback) => {callbacks[kind] = callback; return push}}
      if (name === "membership:watch") replies.push(callbacks)
      return push
    })}
    const fail = () => renderer.membership.receive(failure === "malformed" ? new Uint8Array(24) :
      bitmapFrame({sequence: 2n, tiles: [{...tile, revision: "mismatched-receipt"}]}))
    try {
      renderer.syncWatch()
      for (const delay of [1000, 2000, 4000, 8000, 10000]) {
        replies.at(-1).ok(bitmapBinding)
        fail()
        const sent = replies.length
        expect(renderer.membership.pending).toBe(true)
        renderer.syncWatch()
        await vi.advanceTimersByTimeAsync(delay - 1)
        expect(replies).toHaveLength(sent)
        await vi.advanceTimersByTimeAsync(51)
        expect(replies).toHaveLength(sent + 1)
      }
      replies.at(-1).ok(bitmapBinding)
      renderer.membership.receive(bitmapFrame({tiles: [tile]}))
      expect(renderer.membership.pending).toBe(false)
      fail()
      const sent = replies.length
      await vi.advanceTimersByTimeAsync(1050)
      expect(replies).toHaveLength(sent + 1)
      renderer.setBitmapQuery(null)
      await vi.advanceTimersByTimeAsync(30000)
      expect(replies).toHaveLength(sent + 1)
    } finally {
      renderer.destroyed = true; renderer.clearMembershipRetry(); clearTimeout(renderer.watchTimer)
      renderer.cache.destroy(); renderer.overlays.destroy(); vi.useRealTimers()
    }
  })

  it("updates a live membership error and ignores error and timeout callbacks after destroy", () => {
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    renderer.membershipEnabled = true
    renderer.bitmapQuery = {all: []}
    renderer.cache.manifest = {layout_version: "synthetic-layout", node_count: 2, zmax: 16}
    renderer.cache.visible.set("0/0/0", geometry.key)
    renderer.cache.entries.set("0/0/0", {geometry})
    const replies = []
    renderer.channel = {leave() {}, push() {
      const callbacks = {}
      const push = {receive(kind, callback) {callbacks[kind] = callback; return push}}
      replies.push(callbacks)
      return push
    }}
    const status = vi.spyOn(renderer, "status")
    const updateFilterPanel = vi.spyOn(renderer, "updateFilterPanel")
    const payload = {layout_version: "synthetic-layout", tiles: [{z: 0, x: 0, y: 0, revision: geometry.revision}]}
    try {
      renderer.syncMembership(payload)
      replies[0].error({reason: "query_timeout"})
      expect(renderer.membershipError).toBe("query_timeout")
      expect(updateFilterPanel).toHaveBeenCalled()
      expect(status).toHaveBeenCalledWith("Topology query unavailable: query_timeout")
      expect(renderer.membershipRetryTimer).not.toBeNull()
      renderer.clearMembershipRetry()
      status.mockClear()
      updateFilterPanel.mockClear()
      renderer.membershipError = null
      renderer.syncMembership(payload)
      const late = replies.at(-1)
      vi.stubGlobal("window", {removeEventListener() {}})
      renderer.onLocationHistory = () => {}
      renderer.destroy()
      status.mockClear()
      updateFilterPanel.mockClear()
      late.error({reason: "query_unavailable"})
      late.timeout()
      expect(renderer.membershipError).toBeNull()
      expect(updateFilterPanel).not.toHaveBeenCalled()
      expect(status).not.toHaveBeenCalled()
      expect(renderer.membershipRetryTimer).toBeNull()
    } finally {
      if (!renderer.destroyed) renderer.destroy()
      clearTimeout(renderer.membershipRetryTimer)
      clearTimeout(renderer.watchTimer)
    }
  })

  it("clears a published view when a later SRMO frame changes authority", () => {
    const state = session()
    state.receive(bitmapFrame({tiles: [tile]}))
    expect([...state.entries.get("0/0/0").counts]).toEqual([1, 9001])
    expect(state.total).toBe(9002)
    state.onAck.mockClear()
    state.onReset.mockClear()
    state.receive(bitmapFrame({sequence: 2n, binding: {authority_fingerprint: "synthetic-authority-2"},
      tiles: [{...tile, mask: [0, 1], counts: [0, 1]}]}))
    expect(state.entries.size).toBe(0)
    expect(state.total).toBeNull()
    expect(state.binding).toBeNull()
    expect(state.pending).toBe(true)
    expect(state.onAck).not.toHaveBeenCalled()
    expect(state.onReset).toHaveBeenCalledWith("Membership binding changed", bitmapBinding.view_digest)
  })

  it.each(["aggregate", "boundary"])("rejects an oversized %s population before publishing any rows", kind => {
    const state = session()
    const nodes = [geometry.nodes[0], {kind, count: kind === "aggregate" ? 2 : 0}]
    state.bind(bitmapBinding, [{...geometry, nodes}])
    const accepted = {...tile, mask: [1, kind === "aggregate" ? 1 : 0], counts: [1, nodes[1].count]}
    state.receive(bitmapFrame({tiles: [accepted]}))
    expect(state.pending).toBe(false)
    state.onAck.mockClear()
    state.receive(bitmapFrame({sequence: 2n, tiles: [{...tile, counts: [1, nodes[1].count + 1]}]}))
    expect(state.pending).toBe(true)
    expect(state.entries.size).toBe(0)
    expect(state.total).toBeNull()
    expect(state.onAck).not.toHaveBeenCalled()
    expect(state.onReset).toHaveBeenCalledOnce()
  })

  it("refreshes filter capabilities while the channel is joined and geometry stays unchanged", async () => {
    const manifest = {layout_version: "00000000-0000-4000-8000-000000000478", generation: 1,
      zmax: 1, extent: 2 ** 24, node_count: 2, relation_count: 0, bitmap_membership_protocol: 1}
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    renderer.channel = {state: "joined"}
    renderer.membershipEnabled = true
    renderer.cache.observe({...manifest, bitmap: {ready: true}})
    const fetcher = vi.fn().mockResolvedValueOnce(Response.json({...manifest, bitmap: {ready: false, reason: "source_unavailable"}}))
      .mockResolvedValueOnce(Response.json({...manifest, bitmap: {ready: true}}))
    vi.stubGlobal("fetch", fetcher)
    try {
      await renderer.poll()
      expect(renderer.cache.manifest.bitmap).toEqual({ready: false, reason: "source_unavailable"})
      await renderer.poll()
      expect(renderer.cache.manifest.bitmap).toEqual({ready: true})
      expect(fetcher).toHaveBeenCalledTimes(2)
      expect(fetcher.mock.calls.every(([url]) => url === "/topology/tiles/manifest")).toBe(true)
    } finally {renderer.destroyed = true; clearTimeout(renderer.watchTimer); renderer.cache.destroy(); renderer.overlays.destroy(); vi.unstubAllGlobals()}
  })

  it("drops stale overlay health when the manifest fetch fails", async () => {
    const layout = "00000000-0000-4000-8000-000000000478"
    const manifest = {layout_version: layout, generation: 5, zmax: 1, extent: 2 ** 24, node_count: 1,
      relation_count: 0, bitmap_membership_protocol: 1, world_overlay_protocol: 0}
    const geometry = {key: {layout_version: layout, z: 0, x: 0, y: 0}, revision: "rev-1", generation: 5,
      nodes: [{kind: "device", count: 1}], edges: []}
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    renderer.channel = {state: "joined"}
    renderer.membershipEnabled = true
    renderer.cache.observe(manifest)
    renderer.overlays.setVisible([geometry])
    renderer.overlays.entries.set("0/0/0", {layout_version: layout, generation: 5, tile_id: "0/0/0",
      revision: "rev-1", health: {glyphs: [{state: "healthy"}]}})
    vi.stubGlobal("fetch", vi.fn(async () => {throw new Error("Topology manifest unavailable")}))
    try {
      await renderer.poll()
      expect(renderer.overlays.entries.size).toBe(0)
      expect(renderer.membershipEnabled).toBe(true)
      expect(renderer.channel.state).toBe("joined")
    } finally {renderer.destroyed = true; clearTimeout(renderer.watchTimer); renderer.cache.destroy(); renderer.overlays.destroy(); vi.unstubAllGlobals()}
  })

  it("keeps accepted protocol capabilities when a replica returns an older manifest", async () => {
    const layout = "00000000-0000-4000-8000-000000000479"
    const current = {layout_version: layout, generation: 5, zmax: 1, extent: 2 ** 24, node_count: 1,
      relation_count: 0, bitmap_membership_protocol: 1, world_overlay_protocol: 1,
      bitmap: {ready: true, query: {entity_kind: "device"}}}
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    renderer.channel = {state: "joined"}
    renderer.membershipEnabled = true
    renderer.bitmapQuery = {all: []}
    renderer.membershipSignature = "accepted-view"
    renderer.cache.observe(current)
    renderer.overlays.setBinary(true)
    const invalidated = vi.spyOn(renderer, "invalidateMembership")
    const lagging = {layout_version: layout, generation: 4, zmax: 1, extent: 2 ** 24, node_count: 1, relation_count: 0}
    vi.stubGlobal("fetch", vi.fn(async () => Response.json(lagging)))
    try {
      await renderer.poll()
      expect(renderer.cache.manifest.generation).toBe(5)
      expect(renderer.cache.manifest.bitmap).toEqual(current.bitmap)
      expect(renderer.membershipEnabled).toBe(true)
      expect(renderer.overlays.binary).toBe(true)
      expect(renderer.membershipSignature).toBe("accepted-view")
      expect(invalidated).not.toHaveBeenCalled()
    } finally {renderer.destroyed = true; clearTimeout(renderer.watchTimer); renderer.cache.destroy(); renderer.overlays.destroy(); vi.unstubAllGlobals()}
  })

  it("keeps uint64 sequence precision, replaces the complete view and accepts fresh index revisions", () => {
    const state = session()
    const bytes = bitmapFrame({sequence: 9007199254740993n, total: 0xffffffff, binding: {index_epoch: "synthetic-process"}, tiles: [tile]})
    expect(createHash("sha256").update(bytes).digest("hex")).toBe("e845f7ac68b02c88465d989ff118201ef86a179395e8875a01b56684f9b50107")
    const decoded = decodeBitmapFrame(bytes)
    expect(decoded.sequence).toBe(9007199254740993n)
    expect(decoded.total).toBe(0xffffffff)
    expect(decoded.prefix_sources).toEqual([])
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

  it("replaces prefix catalog versions only with an accepted newer frame", () => {
    const state = session()
    const captured = [{source: "synthetic-flow", version: 1n}, {source: "synthetic-site", version: 9007199254740993n}]
    state.receive(bitmapFrame({sequence: 2n, tiles: [tile], prefixSources: captured}))
    expect(state.prefixSources).toEqual(captured)
    expect(state.sequence).toBe(2n)
    state.receive(bitmapFrame({sequence: 1n, tiles: [{...tile, counts: [0, 1], mask: [0, 1]}], prefixSources: [{source: "synthetic-flow", version: 9n}]}))
    expect(state.prefixSources).toEqual(captured)
    expect([...state.entries.get("0/0/0").counts]).toEqual([1, 9001])
    state.receive(bitmapFrame({sequence: 3n, tiles: [{...tile, mask: [0, 1], counts: [0, 4]}], prefixSources: [{source: "synthetic-flow", version: 2n}]}))
    expect(state.prefixSources).toEqual([{source: "synthetic-flow", version: 2n}])
    expect([...state.entries.get("0/0/0").counts]).toEqual([0, 4])
    const reset = bitmapFrame({kind: "reset", prefixSources: captured})
    expect(decodeBitmapFrame(reset).prefix_sources).toEqual(captured)
    expect(decodeBitmapFrame(reset).tiles.size).toBe(0)
    state.receive(reset)
    expect(state.prefixSources).toEqual([])
    expect(state.entries.size).toBe(0)
    state.bind(bitmapBinding, [geometry])
    state.receive(bitmapFrame({sequence: 4n, tiles: [tile], prefixSources: [{source: "synthetic-site", version: 1n}, {source: "synthetic-flow", version: 1n}]}))
    expect(state.pending).toBe(true)
    expect(state.prefixSources).toEqual([])
    state.bind(bitmapBinding, [geometry])
    const truncated = bitmapFrame({tiles: [tile], prefixSources: [{source: "synthetic-flow", version: 1n}]})
    const cut = truncated.subarray(0, truncated.length - 4)
    new DataView(cut.buffer, cut.byteOffset, cut.byteLength).setUint32(8, cut.length, true)
    expect(() => decodeBitmapFrame(cut)).toThrow("truncated frame")
    expect(() => decodeBitmapFrame(bitmapFrame({tiles: [tile], prefixSources: Array.from({length: 33}, (_, index) => ({source: `synthetic-${index}`, version: 1n}))}))).toThrow("prefix source count")
    expect(() => decodeBitmapFrame(bitmapFrame({tiles: [tile], prefixSources: [{source: "bad\0name", version: 1n}]}))).toThrow("string encoding")
    const bmp = "synthetic-\uE000"
    const nonbmp = "synthetic-\u{10000}"
    const bom = "\uFEFFsynthetic"
    const byteOrder = [{source: bmp, version: 1n}, {source: nonbmp, version: 2n}, {source: bom, version: 3n}]
    expect(decodeBitmapFrame(bitmapFrame({tiles: [tile], prefixSources: byteOrder})).prefix_sources).toEqual(byteOrder)
    state.bind(bitmapBinding, [geometry])
    state.receive(bitmapFrame({sequence: 5n, tiles: [tile], prefixSources: byteOrder}))
    expect(state.prefixSources).toEqual(byteOrder)
    expect(() => decodeBitmapFrame(bitmapFrame({tiles: [tile], prefixSources: [byteOrder[1], byteOrder[0]]}))).toThrow("prefix source order")
    expect(() => decodeBitmapFrame(bitmapFrame({tiles: [tile], prefixSources: [byteOrder[0], byteOrder[0]]}))).toThrow("prefix source order")
    expect(decodeBitmapFrame(bitmapFrame({tiles: [tile], prefixSources: [{source: "\uFEFF", version: 4n}]})).prefix_sources).toEqual([{source: "\uFEFF", version: 4n}])
    state.receive(bitmapFrame({tiles: [tile], prefixSources: [{source: "", version: 1n}]}))
    expect(state.onReset).toHaveBeenCalled()
    expect(state.prefixSources).toEqual([])
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
    const text = "x".repeat(128)
    const binding = Object.fromEntries(FRAME_FIELDS.map(field => [field, text]))
    const prefixSources = Array.from({length: 32}, (_, index) => ({
      source: String.fromCharCode(index + 1).padEnd(128, "a"),
      version: 1n,
    }))
    const tiles = Array.from({length: 64}, (_, x) => ({z: 6, x, y: 0, revision: text,
      mask: Array(128).fill(1), causal: Array(128).fill(3), availability: Array(128).fill(2), counts: Array(128).fill(1)}))
    const bytes = bitmapFrame({binding, tiles, prefixSources, total: 8192})
    expect(bytes.byteLength).toBe(71720)
    expect(bytes.byteLength).toBeLessThanOrEqual(BITMAP_FRAME_BYTES)
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

  it.each(["index_not_ready", "index_unavailable", "prefix_source_unavailable"])("backs off %s and stops retrying unsupported queries", async reason => {
    vi.useFakeTimers()
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    const replies = []
    const payload = {layout_version: "synthetic-layout", tiles: [{z: 0, x: 0, y: 0, revision: geometry.revision}]}
    renderer.membershipEnabled = true
    renderer.bitmapQuery = {all: []}
    renderer.cache.manifest = {node_count: 2}
    renderer.cache.entries.set("0/0/0", {geometry})
    renderer.cache.visible.set("0/0/0", geometry.key)
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
      replies[0].error({reason})
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

  it("keeps retry history through channel reconnect and empty reconciliation, resetting only accepted or changed views", async () => {
    vi.useFakeTimers()
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn()), replies = [], handlers = {}, lifecycle = {}
    const layout = "00000000-0000-4000-8000-000000000478"
    const fence = {layout_version: layout, generation: 4}
    let watchId = 0
    const channel = {state: "joined", on: (event, callback) => {handlers[event] = callback},
      onError: callback => {lifecycle.error = callback}, onClose: callback => {lifecycle.close = callback},
      join: () => ({receive(kind, callback) {if (kind === "ok") lifecycle.join = callback; return this}}),
      push(name) {
        const callbacks = {}, push = {receive(kind, callback) {
          callbacks[kind] = callback
          if (name === "tiles:watch" && kind === "ok") callback({watch_id: ++watchId})
          return this
        }}
        if (name === "membership:watch") replies.push(callbacks)
        return push
      },
    }
    vi.stubGlobal("window", {godViewSocket: {channel: () => channel}})
    renderer.membershipEnabled = true; renderer.bitmapQuery = {facet: "vlan", value: "20"}
    renderer.cache.manifest = {...fence, node_count: 9002}
    renderer.cache.entries.set("0/0/0", {geometry})
    renderer.cache.setVisible([geometry.key])
    try {
      renderer.connect(); lifecycle.join(fence)
      await vi.advanceTimersByTimeAsync(50)
      for (const delay of [1000, 2000]) {
        const sent = replies.length
        replies.at(-1).error({reason: "query_busy"})
        await vi.advanceTimersByTimeAsync(delay - 1)
        expect(replies).toHaveLength(sent)
        await vi.advanceTimersByTimeAsync(51)
        expect(replies).toHaveLength(sent + 1)
      }
      replies.at(-1).error({reason: "query_busy"})
      channel.state = "errored"; lifecycle.error(); lifecycle.close()
      await vi.advanceTimersByTimeAsync(1000)
      channel.state = "joined"; lifecycle.join(fence)
      await vi.advanceTimersByTimeAsync(50)
      handlers.topology_invalidated({...fence, watch_id: watchId, dirty_tiles: []})
      renderer.syncWatch()
      await vi.advanceTimersByTimeAsync(2949)
      expect(replies).toHaveLength(3)
      await vi.advanceTimersByTimeAsync(51)
      expect(replies).toHaveLength(4)
      replies[3].error({reason: "membership_replaced"})
      await vi.advanceTimersByTimeAsync(7999)
      expect(replies).toHaveLength(4)
      await vi.advanceTimersByTimeAsync(51)
      expect(replies).toHaveLength(5)
      replies[4].ok(bitmapBinding)
      handlers["membership:frame"](bitmapFrame({tiles: [tile]}))
      expect(renderer.membership.pending).toBe(false)
      renderer.invalidateMembership(); renderer.syncWatch()
      replies.at(-1).error({reason: "query_busy"})
      await vi.advanceTimersByTimeAsync(999)
      expect(replies).toHaveLength(6)
      await vi.advanceTimersByTimeAsync(51)
      expect(replies).toHaveLength(7)
      replies.at(-1).error({reason: "query_busy"})
      renderer.setBitmapQuery({facet: "vlan", value: "21"})
      renderer.syncWatch()
      const sent = replies.length
      replies[6].error({reason: "membership_replaced"}) // Superseded query cannot disturb this watch.
      expect(renderer.membershipError).toBeNull()
      replies.at(-1).error({reason: "query_busy"})
      await vi.advanceTimersByTimeAsync(1050)
      expect(replies).toHaveLength(sent + 1)
      replies.at(-1).error({reason: "query_busy"})
      renderer.cache.entries.set("0/0/0", {geometry: {...geometry, revision: "new-receipt"}})
      renderer.scheduleWatch(); renderer.syncWatch()
      const changed = replies.length
      replies.at(-1).error({reason: "query_busy"})
      await vi.advanceTimersByTimeAsync(1050)
      expect(replies).toHaveLength(changed + 1)
    } finally {
      renderer.destroyed = true; renderer.clearMembershipRetry(); clearTimeout(renderer.watchTimer)
      renderer.cache.destroy(); renderer.overlays.destroy(); vi.unstubAllGlobals(); vi.useRealTimers()
    }
  })

  it("ignores a delayed reply when the same query is replaced and then restored", () => {
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn()), replies = []
    const payload = {layout_version: "synthetic-layout", tiles: [{z: 0, x: 0, y: 0, revision: geometry.revision}]}
    renderer.membershipEnabled = true
    renderer.bitmapQuery = {facet: "vlan", value: "20"}
    renderer.cache.manifest = {node_count: 2}
    renderer.cache.entries.set("0/0/0", {geometry})
    renderer.cache.visible.set("0/0/0", geometry.key)
    renderer.cache.watchPayload = () => payload
    renderer.watchSignature = JSON.stringify(payload)
    renderer.channel = {state: "joined", push: vi.fn(name => {
      const callbacks = {}
      if (name === "membership:watch") replies.push(callbacks)
      const push = {receive: (kind, callback) => {callbacks[kind] = callback; return push}}
      return push
    })}
    renderer.syncWatch()
    renderer.bitmapQuery = {facet: "vlan", value: "30"}
    renderer.syncWatch()
    renderer.bitmapQuery = {facet: "vlan", value: "20"}
    renderer.syncWatch()
    expect(replies).toHaveLength(3)
    replies[0].ok(bitmapBinding)
    replies[0].error({reason: "query_busy"})
    replies[0].timeout()
    expect(renderer.membership.binding).toBeNull()
    expect(renderer.membershipError).toBeUndefined()
    expect(renderer.membershipRetryTimer).toBeFalsy()
    replies[2].ok(bitmapBinding)
    expect(renderer.membership.binding.view_digest).toBe(bitmapBinding.view_digest)
    renderer.destroyed = true
    renderer.clearMembershipRetry()
  })

  it("keeps accepted VLAN membership when a Prefix Tags source version is the only manifest change", async () => {
    const layout = "00000000-0000-4000-8000-000000000478"
    const query = {entity_kind: "device", facets: [{key: "vlan", operators: ["eq"]}],
      prefix_tags: {available: true, discovery_url: "/topology/query/prefix-tags", sources: [{source: "synthetic", version: 41, available: true}]}}
    const manifest = {layout_version: layout, generation: 1, zmax: 1, extent: 2 ** 24, node_count: 2, relation_count: 0,
      bitmap_membership_protocol: 1, bitmap: {ready: true, query}}
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    renderer.channel = {state: "joined", push: vi.fn(() => {
      const push = {receive: () => push}
      return push
    })}
    renderer.membershipEnabled = true
    renderer.bitmapQuery = {all: [{facet: "vlan", value: "20"}]}
    renderer.cache.observe(manifest)
    renderer.membership.bind(bitmapBinding, [geometry])
    renderer.membership.receive(bitmapFrame({tiles: [tile]}))
    const accepted = renderer.membership.entries
    renderer.membershipSignature = "accepted-vlan"
    const refreshed = {...manifest, bitmap: {ready: true, query: {...query, prefix_tags: {...query.prefix_tags, sources: [{source: "synthetic", version: 42, available: true}]}}}}
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(Response.json(refreshed)))
    try {
      await renderer.poll()
      expect(renderer.membershipSignature).toBe("accepted-vlan")
      expect(renderer.membership.pending).toBe(false)
      expect(renderer.membership.entries).toBe(accepted)
      expect(renderer.membership.total).toBe(9002)
      const removed = {...refreshed, bitmap: {ready: true, query: {...query, prefix_tags: {...query.prefix_tags, available: false, sources: refreshed.bitmap.query.prefix_tags.sources}}}}
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(Response.json(removed)))
      await renderer.poll()
      expect(renderer.membershipSignature).toBe(null)
    } finally {
      renderer.destroyed = true
      clearTimeout(renderer.watchTimer)
      renderer.clearMembershipRetry()
      renderer.cache.destroy()
      renderer.overlays.destroy()
      vi.unstubAllGlobals()
    }
  })

  it("leaves the open detail alone when clear or apply repeats the same filter", () => {
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    const returned = vi.spyOn(renderer, "returnToMap").mockImplementation(() => {})
    const cleared = vi.spyOn(renderer.sceneCache, "clear")
    renderer.invalidateMembership = vi.fn()
    renderer.scheduleWatch = vi.fn()
    renderer.clearMembershipRetry = vi.fn()
    renderer.setBitmapQuery(null)
    expect(returned).not.toHaveBeenCalled()
    expect(renderer.queryGeneration || 0).toBe(0)
    renderer.setBitmapQuery({facet: "vlan", value: "20"})
    expect(renderer.queryGeneration).toBe(1)
    expect(renderer.bitmapQuery).toEqual({facet: "vlan", value: "20"})
    returned.mockClear()
    cleared.mockClear()
    renderer.setBitmapQuery({facet: "vlan", value: "20"})
    expect(returned).not.toHaveBeenCalled()
    expect(cleared).not.toHaveBeenCalled()
    expect(renderer.queryGeneration).toBe(1)
    renderer.setBitmapQuery(null)
    expect(renderer.queryGeneration).toBe(2)
    expect(renderer.bitmapQuery).toBeNull()
    expect(returned).toHaveBeenCalledOnce()
    renderer.destroyed = true
  })

  it("posts a valid filter that would overflow the GET request line and keeps a short filter on GET", async () => {
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn(), {csrfToken: "synthetic-csrf"})
    renderer.membershipEnabled = true
    renderer.membership.pending = false
    renderer.cache.manifest = {layout_version: "synthetic-layout", generation: 1, zmax: 2}
    const calls = []
    vi.stubGlobal("fetch", vi.fn(async (url, init) => {
      calls.push({url, init})
      return Response.json({layout_version: "synthetic-layout", generation: 1, device_id: "synthetic", x: 1, y: 2, zoom: 0})
    }))
    renderer.refreshManifest = vi.fn(async () => {})
    renderer.returnToMap = vi.fn()
    renderer.setView = vi.fn()
    renderer.showSelection = vi.fn(async () => {})
    try {
      renderer.bitmapQuery = {facet: "tag", value: "a".repeat(8100)}
      await renderer.search("synthetic")
      expect(calls[0].url).toBe("/topology/tiles/search")
      expect(calls[0].init.method).toBe("POST")
      expect(calls[0].init.headers["x-csrf-token"]).toBe("synthetic-csrf")
      expect(calls[0].init.headers["content-type"]).toBe("application/json")
      const posted = JSON.parse(calls[0].init.body)
      expect(posted.device_id).toBe("synthetic")
      expect(posted.query).toBe(JSON.stringify(renderer.bitmapQuery))
      expect(posted.query.length).toBeLessThanOrEqual(16384)
      renderer.bitmapQuery = {facet: "vlan", value: "20"}
      await renderer.search("synthetic")
      expect(calls[1].init.method).toBe("GET")
      expect(calls[1].url.startsWith("/topology/tiles/search?")).toBe(true)
      expect(calls[1].url.length).toBeLessThanOrEqual(8000)
      expect(calls[1].init.body).toBeUndefined()
    } finally {
      renderer.destroyed = true
      vi.unstubAllGlobals()
    }
  })
})
