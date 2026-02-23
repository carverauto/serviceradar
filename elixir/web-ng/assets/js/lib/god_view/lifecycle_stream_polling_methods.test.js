import {afterEach, describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleStreamPollingMethods} from "./lifecycle_stream_polling_methods"

afterEach(() => {
  vi.restoreAllMocks()
})

function makeHeaders(entries) {
  const map = new Map(entries)
  return {get: (key) => map.get(key) ?? null}
}

function makeContext({state = {}, deps = {}, methods = {}} = {}) {
  const baseState = {
    snapshotUrl: "/api/snapshot",
    pollIntervalMs: 5000,
    channelJoined: false,
    lastSnapshotAt: 0,
    lastRevision: 10,
    lastGraph: null,
    lastTopologyStamp: null,
    rendererMode: "webgl",
    zoomTier: "local",
    zoomMode: "local",
    selectedNodeIndex: null,
    lastVisibleNodeCount: 2,
    summary: {textContent: ""},
    pushed: [],
    ...state,
  }

  const baseDeps = {
    decodeArrowGraph: vi.fn(() => ({nodes: [{id: "n1"}, {id: "n2"}], edges: [{source: 0, target: 1}]})),
    graphTopologyStamp: vi.fn(() => "topo:1"),
    prepareGraphLayout: vi.fn((g) => g),
    sameTopology: vi.fn(() => true),
    renderGraph: vi.fn(),
    animateTransition: vi.fn(),
    ensureBitmapMetadata: vi.fn((m) => m),
    pipelineStatsFromHeaders: vi.fn(() => null),
    normalizePipelineStats: vi.fn((p) => p),
    ...deps,
  }

  const ctx = createStateBackedContext(baseState, baseDeps)
  Object.assign(ctx, bindApi(ctx, godViewLifecycleStreamPollingMethods), methods)

  if (typeof baseState.pushEvent !== "function") {
    baseState.pushEvent = function pushEvent(name, payload) {
      this.pushed.push({name, payload})
    }
  }
  ctx.pushEvent = (...args) => baseState.pushEvent.apply(baseState, args)

  return ctx
}

describe("lifecycle_stream_polling_methods", () => {
  it("pollSnapshot skips network request while channel data is still fresh", async () => {
    const fetchMock = vi.fn()
    globalThis.fetch = fetchMock

    const ctx = makeContext({
      state: {
        channelJoined: true,
        lastSnapshotAt: Date.now(),
        pollIntervalMs: 6000,
      },
    })

    await ctx.pollSnapshot()

    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("pollSnapshot successful path renders and pushes stream stats", async () => {
    const response = {
      ok: true,
      arrayBuffer: async () => Uint8Array.from([1, 2, 3]).buffer,
      headers: makeHeaders([
        ["x-sr-god-view-revision", "12"],
        ["x-sr-god-view-schema", "2"],
        ["x-sr-god-view-generated-at", "2026-01-01T00:00:00Z"],
      ]),
    }
    globalThis.fetch = vi.fn(async () => response)

    const ctx = makeContext({deps: {sameTopology: vi.fn(() => true)}})

    await ctx.pollSnapshot()

    expect(ctx.deps.renderGraph).toHaveBeenCalledTimes(1)
    expect(ctx.deps.animateTransition).not.toHaveBeenCalled()
    expect(ctx.state.summary.textContent).toContain("snapshot revision=12")
    expect(ctx.state.pushed.some((e) => e.name === "god_view_stream_stats")).toEqual(true)
    expect(ctx.state.lastRevision).toEqual(12)
    expect(ctx.state.lastTopologyStamp).toEqual("topo:1")
  })

  it("pollSnapshot error path pushes poll_error only when channel is unavailable", async () => {
    globalThis.fetch = vi.fn(async () => ({ok: false, status: 503}))

    const ctx = makeContext({state: {channelJoined: false, lastSnapshotAt: 0}})
    await ctx.pollSnapshot()

    expect(ctx.state.summary.textContent).toEqual("snapshot polling error")
    expect(ctx.state.pushed.some((e) => e.name === "god_view_stream_error")).toEqual(true)

    const ctxSuppressed = makeContext({state: {channelJoined: true, lastSnapshotAt: Date.now() - 60_000}})
    await ctxSuppressed.pollSnapshot()

    expect(ctxSuppressed.state.summary.textContent).toEqual("snapshot polling error")
    expect(ctxSuppressed.state.pushed.some((e) => e.name === "god_view_stream_error")).toEqual(false)
  })
})
