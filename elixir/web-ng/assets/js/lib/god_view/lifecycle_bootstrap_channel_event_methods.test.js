import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapChannelEventMethods} from "./lifecycle_bootstrap_channel_event_methods"

function makeJoin() {
  const handlers = {}
  const chain = {
    receive(status, cb) {
      handlers[status] = cb
      return chain
    },
  }
  return {handlers, chain}
}

describe("lifecycle_bootstrap_channel_event_methods", () => {
  it("setClusterExpanded pushes the explicit cluster expansion event", () => {
    const channel = {push: vi.fn()}
    const state = {channel, userCameraLocked: true, hasAutoFit: true, pendingClusterFocus: null}
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods))

    ctx.setClusterExpanded("cluster:endpoints:sr:test", true)

    expect(state.pendingClusterFocus).toBe(null)
    expect(state.userCameraLocked).toBe(true)
    expect(state.hasAutoFit).toBe(true)
    expect(state.topologyLayers.endpoints).toBe(true)
    expect(channel.push).toHaveBeenCalledWith("cluster:set_expanded", {
      cluster_id: "cluster:endpoints:sr:test",
      expanded: true,
    })
  })

  it("setClusterExpanded enables the endpoints layer before asking the server to expand", () => {
    const channel = {push: vi.fn()}
    const pushEvent = vi.fn()
    const state = {
      channel,
      pushEvent,
      topologyLayers: {backbone: true, inferred: false, endpoints: false},
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods))

    ctx.setClusterExpanded("cluster:endpoints:sr:test", true)

    expect(state.topologyLayers.endpoints).toBe(true)
    expect(pushEvent).toHaveBeenCalledWith("enable_attachment_layers", {})
    expect(channel.push).toHaveBeenCalledWith("cluster:set_expanded", {
      cluster_id: "cluster:endpoints:sr:test",
      expanded: true,
    })
  })

  it("collapseAllClusters pushes the cluster collapse event", () => {
    const channel = {push: vi.fn()}
    const state = {channel, pendingClusterFocus: {clusterId: "cluster:endpoints:sr:test", expanded: true}}
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods))

    ctx.collapseAllClusters()

    expect(state.pendingClusterFocus).toBe(null)
    expect(channel.push).toHaveBeenCalledWith("cluster:collapse_all", {})
  })

  it("does not start polling on successful channel join", () => {
    const {handlers, chain} = makeJoin()
    const channel = {join: vi.fn(() => chain)}
    const state = {
      summary: {textContent: ""},
      pushEvent: vi.fn(),
      channelJoined: false,
      channelReconnectAttempt: 2,
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods), {
      startPolling: vi.fn(),
      clearChannelReconnectTimer: vi.fn(),
    })

    ctx.joinSnapshotChannel(channel)
    handlers.ok()

    expect(state.channelJoined).toBe(true)
    expect(state.channelReconnectAttempt).toBe(0)
    expect(ctx.clearChannelReconnectTimer).toHaveBeenCalledTimes(1)
    expect(ctx.startPolling).not.toHaveBeenCalled()
  })

  it("reports retrying and schedules reconnect on startup join error", () => {
    const {handlers, chain} = makeJoin()
    const channel = {join: vi.fn(() => chain)}
    const state = {
      summary: {textContent: ""},
      pushEvent: vi.fn(),
      channelJoined: true,
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods), {
      bootstrapLatestSnapshot: vi.fn(),
      scheduleChannelReconnect: vi.fn(),
    })

    ctx.joinSnapshotChannel(channel)
    handlers.error({reason: "boom"})

    expect(state.channelJoined).toBe(false)
    expect(state.summary.textContent).toBe("waiting for topology channel")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_retrying", {reason: "boom"})
    expect(ctx.bootstrapLatestSnapshot).toHaveBeenCalledTimes(1)
    expect(ctx.scheduleChannelReconnect).toHaveBeenCalledTimes(1)
  })

  it("reports fatal stream errors after a graph has hydrated", () => {
    const state = {
      lastGraph: {nodes: [], edges: []},
      pushEvent: vi.fn(),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods))

    ctx.reportSnapshotStartupError("channel_close")

    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {reason: "channel_close"})
  })

  it("reconnectSnapshotChannel leaves current channel and re-sets up channel", () => {
    const leave = vi.fn()
    const state = {
      channel: {leave},
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods), {
      setupSnapshotChannel: vi.fn(),
    })

    ctx.reconnectSnapshotChannel()

    expect(leave).toHaveBeenCalledTimes(1)
    expect(ctx.setupSnapshotChannel).toHaveBeenCalledTimes(1)
  })
})
