import {afterEach, describe, expect, it, vi} from "vitest"
import {WorldOverlays} from "./world_overlays"
import {worldTileKey, worldTileRevision} from "./fixtures/world_tile_ipc"

const geometry = {key: worldTileKey, generation: 1, revision: worldTileRevision}
const sample = healthy => ({layout_version: worldTileKey.layout_version, generation: 1, revision: worldTileRevision,
  tile_id: "1/1/0", health: {glyphs: [{id: "invented-glyph", counts: {healthy}}]}, flow: {edges: []}})
const stores = []
function store() {const result = new WorldOverlays(vi.fn()); stores.push(result); return result}
afterEach(() => {stores.splice(0).forEach(item => item.destroy()); vi.unstubAllGlobals()})

describe("world telemetry polling", () => {
  it("refreshes telemetry over overlay HTTP only and clears an unavailable sample", async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(Response.json(sample(1))).mockResolvedValueOnce(Response.json(sample(0)))
      .mockResolvedValueOnce(new Response(null, {status: 503}))
    vi.stubGlobal("fetch", fetcher)
    const overlays = store()
    overlays.setVisible([geometry])
    await overlays.poll()
    expect(overlays.entries.get("1/1/0").health.glyphs[0].counts.healthy).toBe(1)
    await overlays.poll()
    expect(overlays.entries.get("1/1/0").health.glyphs[0].counts.healthy).toBe(0)
    await overlays.poll()
    expect(overlays.entries.size).toBe(0)
    expect(fetcher.mock.calls.map(call => call[0])).toEqual(Array(3).fill(
      `/topology/overlays/${worldTileKey.layout_version}/1/1/0?revision=${worldTileRevision}`,
    ))
  })

  it("rejects a late sample when the visible geometry publication changes", async () => {
    let finish
    vi.stubGlobal("fetch", vi.fn(() => new Promise(resolve => {finish = resolve})))
    const overlays = store()
    overlays.setVisible([geometry])
    const pending = overlays.poll()
    overlays.setVisible([{...geometry, generation: 2}])
    finish(Response.json(sample(1)))
    await pending
    expect(overlays.entries.size).toBe(0)
    expect(overlays.onChange).not.toHaveBeenCalled()
  })
})
