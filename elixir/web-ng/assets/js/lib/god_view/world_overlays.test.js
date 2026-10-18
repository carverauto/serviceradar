import {afterEach, describe, expect, it, vi} from "vitest"
import {WorldOverlays} from "./world_overlays"
import {telemetryFrame, telemetryGeometry} from "./fixtures/world_overlay_frame"
import {WORLD_OVERLAY_MIME} from "./world_overlay_frame"

const tileUrl = `/topology/overlays/${telemetryGeometry.key.layout_version}/0/0/0?revision=${telemetryGeometry.revision}`
const frame = (geometry = telemetryGeometry, options) =>
  new globalThis.Response(telemetryFrame(geometry, options), {headers: {"content-type": WORLD_OVERLAY_MIME}})
const healthy = count => ({health: [[count, 0, 0, count, 2], [count, 0, 0, count, 2]]})
const stores = []
function store() {
  const result = new WorldOverlays(vi.fn())
  result.setSupported(true)
  result.onChange.mockClear()
  stores.push(result)
  return result
}
afterEach(() => {stores.splice(0).forEach(item => item.destroy()); vi.unstubAllGlobals()})

describe("world telemetry polling", () => {
  it("refreshes binary telemetry over overlay HTTP only and clears an unavailable or non-binary sample", async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(frame(telemetryGeometry, healthy(1))).mockResolvedValueOnce(frame(telemetryGeometry, healthy(0)))
      .mockResolvedValueOnce(globalThis.Response.json({})).mockResolvedValueOnce(frame())
      .mockResolvedValueOnce(new globalThis.Response(null, {status: 503}))
    vi.stubGlobal("fetch", fetcher)
    const overlays = store()
    overlays.setVisible([telemetryGeometry])
    await overlays.poll()
    expect(fetcher.mock.calls[0][1].headers.Accept).toBe(WORLD_OVERLAY_MIME)
    expect(overlays.entries.get("0/0/0").healthAt(0).healthy).toBe(1)
    expect(overlays.entries.get("0/0/0").flowAt(0).forward.observed_packets_per_second).toBe(12.5)
    expect(overlays.retainedBytes).toBeGreaterThan(0)
    await overlays.poll()
    expect(overlays.entries.get("0/0/0").healthAt(0).healthy).toBe(0)
    await overlays.poll()
    expect(overlays.entries.size).toBe(0)
    await overlays.poll()
    expect(overlays.entries.size).toBe(1)
    await overlays.poll()
    expect(overlays.entries.size).toBe(0)
    expect(fetcher.mock.calls.map(call => call[0])).toEqual(Array(5).fill(tileUrl))
  })

  it("loads the new viewport before a poll requested during an old viewport fetch resolves", async () => {
    let finish
    const next = {...telemetryGeometry, key: {...telemetryGeometry.key, z: 1, x: 1}}
    const fetcher = vi.fn().mockImplementationOnce(() => new Promise(resolve => {finish = resolve}))
      .mockResolvedValueOnce(frame(next))
    vi.stubGlobal("fetch", fetcher)
    const overlays = store()
    overlays.setVisible([telemetryGeometry])
    const oldPoll = overlays.poll()
    overlays.setVisible([next])
    const currentPoll = overlays.poll()
    finish(frame())
    await Promise.all([oldPoll, currentPoll])
    expect(fetcher).toHaveBeenCalledTimes(2)
    expect(overlays.entries.has("0/0/0")).toBe(false)
    expect(overlays.entries.get("1/1/0").tile_id).toBe("1/1/0")
  })

  it("rejects a late sample when the visible geometry publication changes", async () => {
    let finish
    vi.stubGlobal("fetch", vi.fn(() => new Promise(resolve => {finish = resolve})))
    const overlays = store()
    overlays.setVisible([telemetryGeometry])
    const pending = overlays.poll()
    overlays.setVisible([{...telemetryGeometry, generation: telemetryGeometry.generation + 1}])
    finish(frame())
    await pending
    expect(overlays.entries.size).toBe(0)
    expect(overlays.onChange).not.toHaveBeenCalled()
  })

  it("fetches nothing and drops all bytes when the server does not advertise the overlay protocol", async () => {
    let finish
    const fetcher = vi.fn().mockResolvedValueOnce(frame()).mockImplementationOnce(() => new Promise(resolve => {finish = resolve}))
    vi.stubGlobal("fetch", fetcher)
    const overlays = store()
    overlays.setVisible([telemetryGeometry])
    await overlays.poll()
    expect(overlays.entries.size).toBe(1)
    const pending = overlays.poll()
    overlays.setSupported(false)
    finish(frame())
    await pending
    expect(overlays.retainedBytes).toBe(0)
    expect(overlays.entries.size).toBe(0)
    await overlays.poll()
    expect(fetcher).toHaveBeenCalledTimes(2)
    expect(overlays.entries.size).toBe(0)
  })

  it("admits a stable dense viewport before fetching, within four requests and the complete overlay budget", async () => {
    const geometries = Array.from({length: 64}, (_, x) => ({...telemetryGeometry, key: {...telemetryGeometry.key, z: 6, x},
      nodes: Array.from({length: 128}, (_, index) => ({index})), edges: Array.from({length: 512}, (_, index) => ({index, count: 3}))}))
    let active = 0, peak = 0
    vi.stubGlobal("fetch", vi.fn(async url => {
      active += 1; peak = Math.max(peak, active)
      await new Promise(resolve => setTimeout(resolve, 0))
      const x = Number(url.split("/").at(-2))
      active -= 1
      return new globalThis.Response(telemetryFrame(geometries[x]), {headers: {"content-type": WORLD_OVERLAY_MIME}})
    }))
    const overlays = store()
    overlays.setVisible(geometries)
    await overlays.poll()
    expect(peak).toBe(4)
    expect(overlays.entries.size).toBeGreaterThan(0)
    expect(overlays.entries.size).toBeLessThan(64)
    expect(overlays.retainedBytes + 3 * 1024 * 1024).toBeLessThanOrEqual(8 * 1024 * 1024)
    const admitted = [...overlays.entries.keys()].sort()
    expect(fetch.mock.calls).toHaveLength(admitted.length)
    fetch.mockClear()
    overlays.setVisible([...geometries].reverse())
    await overlays.poll()
    expect([...overlays.entries.keys()].sort()).toEqual(admitted)
    expect(fetch.mock.calls).toHaveLength(admitted.length)
    expect(fetch.mock.calls.map(([url]) => url.split("/").slice(-3).join("/").split("?")[0]).sort()).toEqual(admitted)
    // A geometry outside the old admission becomes eligible after panning.
    const next = geometries.find(item => !admitted.includes(`6/${item.key.x}/0`))
    overlays.setVisible([next])
    await overlays.poll()
    expect([...overlays.entries.keys()]).toEqual([`6/${next.key.x}/0`])
    overlays.setVisible([])
    expect(overlays.retainedBytes).toBe(0)
  })
})
