import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapCleanupRuntimeMethods} from "./lifecycle_bootstrap_cleanup_runtime_methods"
import {godViewLifecycleDomSetupMethods} from "./lifecycle_dom_setup_methods"
import {godViewLifecycleStreamSnapshotMethods} from "./lifecycle_stream_snapshot_methods"

function deferred() {
  let resolve
  const promise = new Promise((resolvePromise) => {
    resolve = resolvePromise
  })
  return {promise, resolve}
}

function bindCleanup(context) {
  Object.assign(context, bindApi(context, godViewLifecycleBootstrapCleanupRuntimeMethods), {
    stopAnimationLoop: vi.fn(),
    clearChannelReconnectTimer: vi.fn(),
  })
  return context
}

describe("lifecycle_bootstrap_cleanup_runtime_methods", () => {
  it("invalidates a pending profile layout before finalizing Deck", async () => {
    const sourceGraph = {_layoutMode: "elk-scene", _topologyScene: {profileKey: "landscape"}}
    const portraitGraph = {_layoutMode: "elk-scene", _topologyScene: {profileKey: "portrait"}}
    const pendingLayout = deferred()
    const finalize = vi.fn()
    const renderGraph = vi.fn()
    const state = {
      deck: {finalize},
      lastGraph: sourceGraph,
      lastRevision: 1,
      lastTopologyStamp: "source",
      layoutRequestToken: 0,
      latestSnapshotLayoutToken: 0,
      pendingSnapshotLayoutToken: null,
      pendingViewportProfileKey: "portrait",
      reducedMotionMediaQuery: null,
      reducedMotionListener: null,
      channel: null,
      pendingAnimationFrame: null,
    }
    const ctx = bindCleanup(createStateBackedContext(state, {
      prepareGraphLayout: vi.fn(() => pendingLayout.promise),
      renderGraph,
    }))
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    const request = ctx.requestTopologyProfileLayout(sourceGraph, "portrait")
    await Promise.resolve()
    ctx.cleanupLifecycleRuntime()
    pendingLayout.resolve(portraitGraph)

    expect(await request).toBe(false)
    expect(finalize).toHaveBeenCalledTimes(1)
    expect(renderGraph).not.toHaveBeenCalled()
    expect(state.lastGraph).toBe(sourceGraph)
    expect(state.deck).toBeNull()
    expect(state.pendingViewportProfileKey).toBeNull()
  })

  it("invalidates a pending snapshot layout before finalizing Deck", async () => {
    const previousGraph = {_layoutMode: "elk-scene", _topologyScene: {profileKey: "landscape"}}
    const snapshotGraph = {_layoutMode: "elk-scene", _topologyScene: {profileKey: "landscape"}, nodes: [], edges: []}
    const pendingLayout = deferred()
    const finalize = vi.fn()
    const renderGraph = vi.fn()
    const animateTransition = vi.fn()
    const state = {
      deck: {finalize},
      lastGraph: previousGraph,
      layoutRequestToken: 0,
      latestSnapshotLayoutToken: 0,
      pendingSnapshotLayoutToken: null,
      pendingViewportProfileKey: null,
      reducedMotionMediaQuery: null,
      reducedMotionListener: null,
      channel: null,
      pendingAnimationFrame: null,
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
    }
    const ctx = bindCleanup(createStateBackedContext(state, {
      decodeArrowGraph: vi.fn(() => ({nodes: [], edges: []})),
      graphTopologyStamp: vi.fn(() => "snapshot"),
      prepareGraphLayout: vi.fn(() => pendingLayout.promise),
      ensureBitmapMetadata: vi.fn(() => null),
      sameTopology: vi.fn(() => false),
      normalizePipelineStats: vi.fn(() => null),
      renderGraph,
      animateTransition,
    }))
    Object.assign(ctx, bindApi(ctx, godViewLifecycleStreamSnapshotMethods), {
      parseSnapshotMessage: vi.fn(() => ({
        revision: 2,
        payload: new ArrayBuffer(1),
      })),
    })

    const request = ctx.handleSnapshot(new ArrayBuffer(1))
    await Promise.resolve()
    ctx.cleanupLifecycleRuntime()
    pendingLayout.resolve(snapshotGraph)
    await request

    expect(finalize).toHaveBeenCalledTimes(1)
    expect(renderGraph).not.toHaveBeenCalled()
    expect(animateTransition).not.toHaveBeenCalled()
    expect(state.lastGraph).toBe(previousGraph)
    expect(state.deck).toBeNull()
    expect(state.pendingSnapshotLayoutToken).toBeNull()
  })
})
