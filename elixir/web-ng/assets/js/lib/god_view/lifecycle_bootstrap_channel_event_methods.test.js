import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapChannelEventMethods} from "./lifecycle_bootstrap_channel_event_methods"

describe("lifecycle_bootstrap_channel_event_methods", () => {
  it("setClusterExpanded enables the endpoints layer for an expansion", () => {
    const pushEvent = vi.fn()
    const state = {
      pushEvent,
      topologyLayers: {backbone: true, inferred: false, endpoints: false},
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods))

    ctx.setClusterExpanded("cluster:endpoints:sr:test", true)

    expect(state.topologyLayers.endpoints).toBe(true)
    expect(pushEvent).toHaveBeenCalledWith("enable_attachment_layers", {})
  })

  it("setClusterExpanded ignores blank identifiers and collapse requests", () => {
    const pushEvent = vi.fn()
    const state = {
      pushEvent,
      topologyLayers: {backbone: true, inferred: false, endpoints: false},
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods))

    ctx.setClusterExpanded("   ", true)
    ctx.setClusterExpanded("cluster:endpoints:sr:test", false)

    expect(state.topologyLayers.endpoints).toBe(false)
    expect(pushEvent).not.toHaveBeenCalled()
  })
})
