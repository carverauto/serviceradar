import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapChannelMethods} from "./lifecycle_bootstrap_channel_methods"
import {godViewLifecycleStreamSnapshotMethods} from "./lifecycle_stream_snapshot_methods"

function buildHeaders(values) {
  return {
    get(name) {
      return values[name] ?? null
    },
  }
}

describe("lifecycle_bootstrap_channel_methods", () => {
  it("buildSnapshotFrameFromHttpResponse reconstructs the binary frame from headers", () => {
    const state = {}
    const ctx = createStateBackedContext(state, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewLifecycleBootstrapChannelMethods),
      bindApi(ctx, godViewLifecycleStreamSnapshotMethods),
    )

    const frame = ctx.buildSnapshotFrameFromHttpResponse(
      Uint8Array.from([7, 8, 9]).buffer,
      buildHeaders({
        "x-sr-god-view-schema": "2",
        "x-sr-god-view-revision": "42",
        "x-sr-god-view-generated-at": "2023-11-14T22:13:20.000Z",
        "x-sr-god-view-bitmap-root-bytes": "11",
        "x-sr-god-view-bitmap-affected-bytes": "12",
        "x-sr-god-view-bitmap-healthy-bytes": "13",
        "x-sr-god-view-bitmap-unknown-bytes": "14",
        "x-sr-god-view-bitmap-root-count": "3",
        "x-sr-god-view-bitmap-affected-count": "4",
        "x-sr-god-view-bitmap-healthy-count": "5",
        "x-sr-god-view-bitmap-unknown-count": "6",
      }),
    )

    const parsed = ctx.parseBinarySnapshotFrame(frame)
    expect(parsed.schemaVersion).toEqual(2)
    expect(parsed.revision).toEqual(42)
    expect(parsed.bitmapMetadata.root_cause.bytes).toEqual(11)
    expect(Array.from(parsed.payload)).toEqual([7, 8, 9])
  })

  it("bootstrapLatestSnapshot fetches the latest snapshot and forwards it to handleSnapshot", async () => {
    const originalFetch = globalThis.fetch
    const fetchMock = vi.fn(async () => ({
      ok: true,
      status: 200,
      headers: buildHeaders({
        "x-sr-god-view-schema": "2",
        "x-sr-god-view-revision": "42",
        "x-sr-god-view-generated-at": "2023-11-14T22:13:20.000Z",
        "x-sr-god-view-bitmap-root-bytes": "11",
        "x-sr-god-view-bitmap-affected-bytes": "12",
        "x-sr-god-view-bitmap-healthy-bytes": "13",
        "x-sr-god-view-bitmap-unknown-bytes": "14",
        "x-sr-god-view-bitmap-root-count": "3",
        "x-sr-god-view-bitmap-affected-count": "4",
        "x-sr-god-view-bitmap-healthy-count": "5",
        "x-sr-god-view-bitmap-unknown-count": "6",
        "x-sr-god-view-pipeline-raw-links": "99",
      }),
      arrayBuffer: async () => Uint8Array.from([1, 2, 3]).buffer,
    }))
    globalThis.fetch = fetchMock

    try {
      const state = {
        el: {dataset: {url: "/topology/snapshot/latest"}},
        summary: {textContent: ""},
        pushEvent: vi.fn(),
        snapshotBootstrapPromise: null,
        lastGraph: null,
      }
      const ctx = createStateBackedContext(state, {})
      Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelMethods), {
        handleSnapshot: vi.fn(async () => {}),
      })

      const loaded = await ctx.bootstrapLatestSnapshot()

      expect(loaded).toEqual(true)
      expect(fetchMock).toHaveBeenCalledWith("/topology/snapshot/latest", {
        credentials: "same-origin",
        headers: {Accept: "application/octet-stream"},
      })
      expect(ctx.handleSnapshot).toHaveBeenCalledTimes(1)
      expect(state.lastPipelineStats.raw_links).toEqual(99)
      expect(state.snapshotBootstrapPromise).toEqual(null)
    } finally {
      globalThis.fetch = originalFetch
    }
  })
})
