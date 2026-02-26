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

  it("schedules reconnect on join error", () => {
    const {handlers, chain} = makeJoin()
    const channel = {join: vi.fn(() => chain)}
    const state = {
      summary: {textContent: ""},
      pushEvent: vi.fn(),
      channelJoined: true,
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapChannelEventMethods), {
      scheduleChannelReconnect: vi.fn(),
    })

    ctx.joinSnapshotChannel(channel)
    handlers.error({reason: "boom"})

    expect(state.channelJoined).toBe(false)
    expect(state.summary.textContent).toBe("topology channel failed")
    expect(state.pushEvent).toHaveBeenCalledWith("god_view_stream_error", {reason: "boom"})
    expect(ctx.scheduleChannelReconnect).toHaveBeenCalledTimes(1)
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
