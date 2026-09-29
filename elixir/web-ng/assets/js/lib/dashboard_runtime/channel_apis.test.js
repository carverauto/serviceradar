import {describe, expect, test, vi} from "vitest"

import {
  createDashboardActionsApi,
  createDashboardEventsApi,
  createFrameRefresh,
  MAX_EVENT_SUBSCRIPTIONS,
} from "./channel_apis"

// A Phoenix channel stand-in: each push answers with the reply the test queued
// for that event name.
function fakeChannel(replies = {}) {
  const pushes = []
  return {
    pushes,
    push: vi.fn((event, payload) => {
      pushes.push({event, payload})
      const [status, reply] = replies[event] || ["ok", {}]
      const push = {
        receive(kind, callback) {
          if (kind === status) callback(reply)
          return push
        },
      }
      return push
    }),
  }
}

const allowAll = () => true

describe("actions API", () => {
  test("rejects without the capability or the viewer permission, without touching the channel", async () => {
    const channel = fakeChannel()
    const noCapability = createDashboardActionsApi({permitted: true, getChannel: () => channel}).publicApi()
    const noPermission = createDashboardActionsApi({capabilityAllowed: allowAll, getChannel: () => channel}).publicApi()

    await expect(noCapability.invoke({actionId: "a", targets: [{deviceUid: "d"}]})).rejects.toMatchObject({
      code: "capability_denied",
    })
    await expect(noPermission.list()).rejects.toMatchObject({code: "permission_denied"})
    expect(channel.push).not.toHaveBeenCalled()
  })

  test("invoke resolves with the terminal state and reports each progress step", async () => {
    const channel = fakeChannel({"actions:invoke": ["ok", {invocation_id: "inv-1", state: "dispatching"}]})
    const api = createDashboardActionsApi({capabilityAllowed: allowAll, permitted: true, getChannel: () => channel})
    const onProgress = vi.fn()

    const result = api.publicApi().invoke(
      {actionId: "northbound:1", targets: [{deviceUid: "sr:device:plc-07"}], input: {fault_kind: "jam"}},
      {onProgress},
    )
    await Promise.resolve()

    expect(channel.pushes[0]).toEqual({
      event: "actions:invoke",
      payload: {
        action_id: "northbound:1",
        scope: "device",
        targets: [{device_uid: "sr:device:plc-07"}],
        input: {fault_kind: "jam"},
      },
    })

    api.handleProgress({invocation_id: "inv-1", state: "running"})
    api.handleProgress({invocation_id: "inv-1", state: "succeeded", result_summary: {ok: true}})

    await expect(result).resolves.toMatchObject({state: "succeeded", result_summary: {ok: true}})
    expect(onProgress.mock.calls.map(([progress]) => progress.state)).toEqual(["dispatching", "running", "succeeded"])
    expect(api.pendingCount()).toBe(0)
  })

  test("a rejected invocation surfaces the server's reason", async () => {
    const channel = fakeChannel({"actions:invoke": ["error", {reason: "You are not authorized to launch actions."}]})
    const api = createDashboardActionsApi({capabilityAllowed: allowAll, permitted: true, getChannel: () => channel})

    await expect(api.publicApi().invoke({actionId: "a", targets: [{deviceUid: "d"}]})).rejects.toMatchObject({
      code: "rejected",
      message: "You are not authorized to launch actions.",
    })
  })

  test("an action held for confirmation resolves only after the host confirms", async () => {
    const channel = fakeChannel({
      "actions:invoke": ["ok", {state: "confirmation_required", confirmation_id: "conf-1", action_id: "northbound:1", expires_in_ms: 120000}],
    })
    const api = createDashboardActionsApi({capabilityAllowed: allowAll, permitted: true, getChannel: () => channel})
    const onProgress = vi.fn()
    const onConfirmation = vi.fn()
    let settled = false

    const result = api
      .publicApi()
      .invoke({actionId: "northbound:1", targets: [{deviceUid: "sr:device:sample-01"}]}, {onProgress, onConfirmation})
    result.then(() => (settled = true))
    await Promise.resolve()
    await Promise.resolve()

    expect(api.awaitingConfirmationCount()).toBe(1)
    expect(onConfirmation.mock.calls[0][0]).toMatchObject({state: "pending", confirmation_id: "conf-1"})
    expect(onProgress).not.toHaveBeenCalled()
    expect(settled).toBe(false)

    api.handleConfirmation({
      confirmation_id: "conf-1",
      state: "confirmed",
      invocation: {invocation_id: "inv-9", state: "dispatching"},
    })
    api.handleProgress({invocation_id: "inv-9", state: "succeeded"})

    await expect(result).resolves.toMatchObject({invocation_id: "inv-9", state: "succeeded"})
    expect(onConfirmation.mock.calls.map(([update]) => update.state)).toEqual(["pending", "confirmed"])
    expect(api.awaitingConfirmationCount()).toBe(0)
    expect(api.pendingCount()).toBe(0)
  })

  test("a declined or expired confirmation rejects the invoke with a confirmation code", async () => {
    const channel = fakeChannel({"actions:invoke": ["ok", {state: "confirmation_required", confirmation_id: "conf-2"}]})
    const api = createDashboardActionsApi({capabilityAllowed: allowAll, permitted: true, getChannel: () => channel})

    const declined = api.publicApi().invoke({actionId: "a", targets: [{deviceUid: "d"}]})
    await Promise.resolve()
    await Promise.resolve()
    api.handleConfirmation({confirmation_id: "conf-2", state: "declined"})
    await expect(declined).rejects.toMatchObject({code: "confirmation_declined", confirmationId: "conf-2", actionId: "a"})

    const expired = api.publicApi().invoke({actionId: "a", targets: [{deviceUid: "d"}]})
    await Promise.resolve()
    await Promise.resolve()
    api.handleConfirmation({confirmation_id: "conf-2", state: "expired", reason: "The confirmation expired before it was answered."})
    await expect(expired).rejects.toMatchObject({code: "confirmation_expired"})

    // A late or repeated message for a settled confirmation is ignored.
    expect(() => api.handleConfirmation({confirmation_id: "conf-2", state: "confirmed"})).not.toThrow()
    expect(api.awaitingConfirmationCount()).toBe(0)
  })

  test("invoke requires targets with a device uid", async () => {
    const api = createDashboardActionsApi({capabilityAllowed: allowAll, permitted: true, getChannel: () => fakeChannel()})

    await expect(api.publicApi().invoke({actionId: "a", targets: []})).rejects.toMatchObject({code: "invalid_request"})
    await expect(api.publicApi().invoke({actionId: "a", targets: [{}]})).rejects.toMatchObject({code: "invalid_request"})
  })
})

describe("events API", () => {
  test("delivers matching batches once per event id and stops after unsubscribe", () => {
    const channel = fakeChannel()
    const api = createDashboardEventsApi({capabilityAllowed: allowAll, permitted: true, getChannel: () => channel})
    const onEvents = vi.fn()

    const unsubscribe = api.publicApi().subscribe({log_provider: "plugin:demo-ot-plc"}, onEvents)
    expect(channel.pushes[0]).toEqual({
      event: "events:subscribe",
      payload: {id: "sub-1", filter: {log_provider: "plugin:demo-ot-plc"}},
    })

    api.handleBatch({subscription_id: "sub-1", events: [{id: "e1"}, {id: "e2"}]})
    api.handleBatch({subscription_id: "sub-1", events: [{id: "e2"}, {id: "e3"}]})
    expect(onEvents.mock.calls.map(([events]) => events.map((event) => event.id))).toEqual([["e1", "e2"], ["e3"]])

    unsubscribe()
    expect(channel.pushes.at(-1)).toEqual({event: "events:unsubscribe", payload: {id: "sub-1"}})
    api.handleBatch({subscription_id: "sub-1", events: [{id: "e4"}]})
    expect(onEvents).toHaveBeenCalledTimes(2)
  })

  test("re-sends every subscription after a rejoin", () => {
    let channel = null
    const api = createDashboardEventsApi({capabilityAllowed: allowAll, permitted: true, getChannel: () => channel})
    api.publicApi().subscribe({class_uid: 1008}, vi.fn())
    api.publicApi().subscribe({min_severity_id: 4}, vi.fn())

    channel = fakeChannel()
    api.resubscribeAll()

    expect(channel.pushes.map((push) => push.payload.id)).toEqual(["sub-1", "sub-2"])
  })

  test("enforces capability, permission and the subscription cap", () => {
    const denied = createDashboardEventsApi({permitted: true}).publicApi()
    expect(() => denied.subscribe({}, vi.fn())).toThrow(expect.objectContaining({code: "capability_denied"}))

    const api = createDashboardEventsApi({capabilityAllowed: allowAll, permitted: true}).publicApi()
    for (let index = 0; index < MAX_EVENT_SUBSCRIPTIONS; index += 1) api.subscribe({}, vi.fn())
    expect(() => api.subscribe({}, vi.fn())).toThrow(expect.objectContaining({code: "invalid_request"}))
  })

  test("a revoked-access error reaches every subscription", () => {
    const api = createDashboardEventsApi({capabilityAllowed: allowAll, permitted: true})
    const onError = vi.fn()
    api.publicApi().subscribe({}, vi.fn(), {onError})

    api.handleError({reason: "You are not authorized to read events."})

    expect(onError).toHaveBeenCalledWith(expect.objectContaining({code: "permission_denied"}))
  })
})

describe("frame refresh", () => {
  test("pushes frames:refresh and reports a refresh already in flight", async () => {
    const ok = fakeChannel()
    await expect(createFrameRefresh({capabilityAllowed: allowAll, getChannel: () => ok})()).resolves.toEqual({
      refreshed: true,
    })
    expect(ok.pushes[0].event).toBe("frames:refresh")

    const busy = fakeChannel({"frames:refresh": ["error", {reason: "refresh_in_progress"}]})
    await expect(createFrameRefresh({capabilityAllowed: allowAll, getChannel: () => busy})()).resolves.toEqual({
      refreshed: false,
      reason: "refresh_in_progress",
    })
  })

  test("requires srql.execute and a connected channel", async () => {
    await expect(createFrameRefresh({getChannel: () => fakeChannel()})()).rejects.toMatchObject({code: "capability_denied"})
    await expect(createFrameRefresh({capabilityAllowed: allowAll})()).rejects.toMatchObject({code: "not_connected"})
  })
})
