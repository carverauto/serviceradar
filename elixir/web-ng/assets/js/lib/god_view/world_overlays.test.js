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
    const full = {...sample(1), flow: {edges: Array.from({length: 512}, (_, index) => ({id: `bundle:${index}`}))}}
    const oversized = {...sample(0), flow: {edges: [...full.flow.edges, {id: "bundle:overflow"}]}}
    const fetcher = vi.fn().mockResolvedValueOnce(Response.json(full)).mockResolvedValueOnce(Response.json(sample(0)))
      .mockResolvedValueOnce(Response.json(oversized)).mockResolvedValueOnce(new Response(null, {status: 503}))
    vi.stubGlobal("fetch", fetcher)
    const overlays = store()
    overlays.setVisible([geometry])
    await overlays.poll()
    expect(overlays.entries.get("1/1/0").health.glyphs[0].counts.healthy).toBe(1)
    expect(overlays.entries.get("1/1/0").flow.edges).toEqual(full.flow.edges)
    await overlays.poll()
    expect(overlays.entries.get("1/1/0").health.glyphs[0].counts.healthy).toBe(0)
    await overlays.poll()
    expect(overlays.entries.size).toBe(0)
    await overlays.poll()
    expect(overlays.entries.size).toBe(0)
    expect(fetcher.mock.calls.map(call => call[0])).toEqual(Array(4).fill(
      `/topology/overlays/${worldTileKey.layout_version}/1/1/0?revision=${worldTileRevision}`,
    ))
  })

  it("loads the new viewport before a poll requested during an old viewport fetch resolves", async () => {
    let finish
    const next = {...geometry, key: {...worldTileKey, x: 0}}
    const nextSample = {...sample(1), tile_id: "1/0/0"}
    const fetcher = vi.fn().mockImplementationOnce(() => new Promise(resolve => {finish = resolve}))
      .mockResolvedValueOnce(Response.json(nextSample))
    vi.stubGlobal("fetch", fetcher)
    const overlays = store()
    overlays.setVisible([geometry])
    const oldPoll = overlays.poll()
    overlays.setVisible([next])
    const currentPoll = overlays.poll()
    finish(Response.json(sample(1)))
    await Promise.all([oldPoll, currentPoll])
    expect(fetcher).toHaveBeenCalledTimes(2)
    expect(overlays.entries.has("1/1/0")).toBe(false)
    expect(overlays.entries.get("1/0/0")).toEqual(nextSample)
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
