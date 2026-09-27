import {afterEach, describe, expect, it, vi} from "vitest"
import {WorldTileCache} from "./world_tile_cache"
import {worldTileIpc, worldTileKey, worldTileRevision} from "./fixtures/world_tile_ipc"

const manifest = {layout_version: worldTileKey.layout_version, generation: 1, zmax: 16, extent: 2 ** 24, node_count: 70000, relation_count: 90000}
const root = {z: 0, x: 0, y: 0}
const child = {z: 1, x: 0, y: 0}
const sibling = {z: 1, x: 1, y: 0}
const caches = []
function cache(options) {
  const result = new WorldTileCache(options)
  result.observe(manifest)
  caches.push(result)
  return result
}
function response(index, generation = 1, status = 200) {
  const width = 2 ** (24 - index.z)
  return new globalThis.Response(status === 304 ? null : worldTileIpc({metadata: {
    ...index, origin_x: index.x * width, origin_y: index.y * width, coordinate_scale: width / 65535,
  }}), {
    status,
    headers: {
      "x-sr-topology-layout-version": manifest.layout_version,
      "x-sr-topology-generation": String(generation),
      etag: `"${manifest.layout_version}:${worldTileRevision}"`,
    },
  })
}
function automaticFetch(generation = 1) {
  const fetcher = vi.fn(url => {
    const [z, x, y] = url.split("/").slice(-3).map(Number)
    return Promise.resolve(response({z, x, y}, generation))
  })
  vi.stubGlobal("fetch", fetcher)
  return fetcher
}
afterEach(() => {
  for (const item of caches.splice(0)) item.destroy()
  vi.unstubAllGlobals()
})

describe("world geometry cache", () => {
  it("coalesces duplicate HTTP reads and revisits retained geometry without fetching", async () => {
    const fetcher = automaticFetch()
    const store = cache()
    const [first, concurrent] = await Promise.all([store.get(root), store.get(root)])
    expect(concurrent).toBe(first)
    await store.get(child)
    expect(await store.get(root)).toBe(first)
    expect(fetcher).toHaveBeenCalledTimes(2)
  })

  it("reports a transient server failure and permits a later successful read", async () => {
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(new globalThis.Response(null, {status: 503}))))
    const store = cache()
    await expect(store.get(root)).rejects.toThrow("Topology tile HTTP 503")
    automaticFetch()
    expect((await store.get(root)).generation).toBe(1)
  })

  it("keeps offscreen dirty geometry lazy and validates a visible dirty tile with ETag", async () => {
    let fetcher = automaticFetch()
    const store = cache()
    const first = await store.get(root)
    await store.get(child)
    store.setVisible([root])
    const watched = store.watchPayload()
    store.acknowledgeWatch(7, watched)
    store.observe({...manifest, generation: 2})
    expect(store.invalidate({...manifest, generation: 2, watch_id: 7, dirty_tiles: ["1/0/0"], reset: false})).toBe(true)
    expect((await store.get(root)).columns).toBe(first.columns)
    expect(fetcher).toHaveBeenCalledTimes(2)
    fetcher = vi.fn(() => Promise.resolve(response(child, 2, 304)))
    vi.stubGlobal("fetch", fetcher)
    const refreshed = await store.get(child)
    expect(refreshed.generation).toBe(2)
    expect(fetcher.mock.calls[0][1].headers["If-None-Match"]).toBe(`"${manifest.layout_version}:${worldTileRevision}"`)
    expect(await store.get(child)).toBe(refreshed)
    expect(fetcher).toHaveBeenCalledTimes(1)
  })

  it("discards a response from a superseded publication even if fetch ignores cancellation", async () => {
    let finish
    vi.stubGlobal("fetch", vi.fn(() => new Promise(resolve => {finish = resolve})))
    const store = cache()
    const pending = store.get(root)
    const rejected = expect(pending).rejects.toMatchObject({name: "AbortError"})
    store.observe({...manifest, generation: 2})
    finish(response(root))
    await rejected
    automaticFetch(2)
    const current = await store.get(root)
    expect(current.generation).toBe(2)
  })

  it("evicts the least recently used unpinned entry and preserves the visible one", async () => {
    const fetcher = automaticFetch()
    const store = cache({maxEntries: 2})
    store.setVisible([root])
    const visible = await store.get(root)
    await store.get(child)
    await store.get(sibling)
    expect(await store.get(root)).toBe(visible)
    expect(fetcher).toHaveBeenCalledTimes(3)
    await store.get(child)
    expect(fetcher).toHaveBeenCalledTimes(4)
  })
})
