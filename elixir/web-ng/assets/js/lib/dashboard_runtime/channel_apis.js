// Action, live-event and frame-refresh APIs exposed to dashboard packages
// (`api.actions`, `api.events`, `api.refreshFrames`). All three ride the
// dashboard's own frame channel. The channel re-authorizes every request against
// the viewer's scope and the package's signed capability list; the checks here
// only keep a package from asking for what it cannot have.

export const ACTIONS_INVOKE_CAPABILITY = "actions.invoke"
export const EVENTS_SUBSCRIBE_CAPABILITY = "events.subscribe"
export const MAX_EVENT_SUBSCRIPTIONS = 8

const TERMINAL_ACTION_STATES = new Set(["succeeded", "failed", "expired", "canceled", "suppressed", "unknown"])
const DEDUPE_WINDOW = 1000

export const CHANNEL_API_ERRORS = Object.freeze({
  CAPABILITY_DENIED: "capability_denied",
  PERMISSION_DENIED: "permission_denied",
  NOT_CONNECTED: "not_connected",
  INVALID_REQUEST: "invalid_request",
  REJECTED: "rejected",
  TIMEOUT: "timeout",
})

export class DashboardChannelError extends Error {
  constructor(code, message) {
    super(message)
    this.name = "DashboardChannelError"
    this.code = code
  }
}

function pushWithReply(getChannel, event, payload, timeoutMs = 10_000) {
  const channel = getChannel()
  if (!channel || typeof channel.push !== "function") {
    return Promise.reject(new DashboardChannelError(CHANNEL_API_ERRORS.NOT_CONNECTED, "dashboard channel is not connected"))
  }

  return new Promise((resolve, reject) => {
    channel
      .push(event, payload, timeoutMs)
      .receive("ok", (reply) => resolve(reply || {}))
      .receive("error", (reply) =>
        reject(new DashboardChannelError(CHANNEL_API_ERRORS.REJECTED, reply?.reason || `${event} was rejected`)),
      )
      .receive("timeout", () => reject(new DashboardChannelError(CHANNEL_API_ERRORS.TIMEOUT, `${event} timed out`)))
  })
}

function requireAccess(capabilityAllowed, capability, permitted) {
  if (!capabilityAllowed(capability)) {
    throw new DashboardChannelError(
      CHANNEL_API_ERRORS.CAPABILITY_DENIED,
      `dashboard capability is not approved: ${capability}`,
    )
  }
  if (!permitted) {
    throw new DashboardChannelError(CHANNEL_API_ERRORS.PERMISSION_DENIED, `viewer is not permitted to use ${capability}`)
  }
}

function normalizeTargets(targets) {
  if (!Array.isArray(targets) || targets.length === 0) {
    throw new DashboardChannelError(CHANNEL_API_ERRORS.INVALID_REQUEST, "actions.invoke requires at least one target")
  }

  return targets.map((target) => {
    const deviceUid = String(target?.deviceUid ?? target?.device_uid ?? "").trim()
    const interfaceUid = String(target?.interfaceUid ?? target?.interface_uid ?? "").trim()
    if (!deviceUid) {
      throw new DashboardChannelError(CHANNEL_API_ERRORS.INVALID_REQUEST, "every action target needs a device uid")
    }
    return interfaceUid ? {device_uid: deviceUid, interface_uid: interfaceUid} : {device_uid: deviceUid}
  })
}

export function createDashboardActionsApi({capabilityAllowed = () => false, permitted = false, getChannel = () => null} = {}) {
  const pending = new Map()

  const handleProgress = (payload) => {
    const id = String(payload?.invocation_id || "")
    const entry = pending.get(id)
    if (!entry) return

    const progress = {...payload}
    try {
      entry.onProgress?.(progress)
    } catch (_error) {}

    if (TERMINAL_ACTION_STATES.has(String(progress.state))) {
      pending.delete(id)
      entry.resolve(progress)
    }
  }

  const list = (options = {}) => {
    try {
      requireAccess(capabilityAllowed, ACTIONS_INVOKE_CAPABILITY, permitted)
    } catch (error) {
      return Promise.reject(error)
    }

    return pushWithReply(getChannel, "actions:list", {
      scope: options.scope || "device",
      plugin_id: options.pluginId || options.plugin_id || undefined,
      provider_type: options.providerType || options.provider_type || undefined,
    }).then((reply) => (Array.isArray(reply.actions) ? reply.actions : []))
  }

  // Resolves with the invocation's terminal progress payload; `onProgress`
  // receives every state change, starting with the submitted state.
  const invoke = (request = {}, {onProgress} = {}) => {
    let payload
    try {
      requireAccess(capabilityAllowed, ACTIONS_INVOKE_CAPABILITY, permitted)
      const actionId = String(request.actionId ?? request.action_id ?? "").trim()
      if (!actionId) throw new DashboardChannelError(CHANNEL_API_ERRORS.INVALID_REQUEST, "actions.invoke requires an actionId")
      payload = {
        action_id: actionId,
        scope: request.scope || "device",
        targets: normalizeTargets(request.targets),
        input: request.input && typeof request.input === "object" ? request.input : {},
      }
    } catch (error) {
      return Promise.reject(error)
    }

    return pushWithReply(getChannel, "actions:invoke", payload).then(
      (submitted) =>
        new Promise((resolve) => {
          const id = String(submitted.invocation_id || "")
          pending.set(id, {resolve, onProgress})
          handleProgress(submitted)
        }),
    )
  }

  return {
    handleProgress,
    pendingCount: () => pending.size,
    publicApi: () => ({
      allowed: () => capabilityAllowed(ACTIONS_INVOKE_CAPABILITY) && permitted,
      list,
      invoke,
    }),
  }
}

export function createDashboardEventsApi({capabilityAllowed = () => false, permitted = false, getChannel = () => null} = {}) {
  const subscriptions = new Map()
  let sequence = 0

  const send = (id, entry) =>
    pushWithReply(getChannel, "events:subscribe", {id, filter: entry.filter}).catch((error) => {
      try {
        entry.onError?.(error)
      } catch (_error) {}
    })

  const subscribe = (filter = {}, onEvents, {onError} = {}) => {
    requireAccess(capabilityAllowed, EVENTS_SUBSCRIBE_CAPABILITY, permitted)
    if (typeof onEvents !== "function") {
      throw new DashboardChannelError(CHANNEL_API_ERRORS.INVALID_REQUEST, "events.subscribe requires a callback")
    }
    if (subscriptions.size >= MAX_EVENT_SUBSCRIPTIONS) {
      throw new DashboardChannelError(
        CHANNEL_API_ERRORS.INVALID_REQUEST,
        `at most ${MAX_EVENT_SUBSCRIPTIONS} event subscriptions are allowed`,
      )
    }

    sequence += 1
    const id = `sub-${sequence}`
    const entry = {filter: {...filter}, onEvents, onError, seen: []}
    subscriptions.set(id, entry)
    if (getChannel()) send(id, entry)

    return () => {
      if (!subscriptions.delete(id)) return
      const channel = getChannel()
      if (channel && typeof channel.push === "function") channel.push("events:unsubscribe", {id})
    }
  }

  // A redelivered event batch can repeat an event; each subscription drops ids
  // it has already delivered.
  const handleBatch = (payload) => {
    const entry = subscriptions.get(String(payload?.subscription_id || ""))
    if (!entry) return

    const fresh = (Array.isArray(payload?.events) ? payload.events : []).filter((event) => {
      const id = String(event?.id || "")
      if (!id || entry.seen.includes(id)) return false
      entry.seen.push(id)
      if (entry.seen.length > DEDUPE_WINDOW) entry.seen.shift()
      return true
    })

    if (fresh.length === 0) return
    try {
      entry.onEvents(fresh)
    } catch (_error) {}
  }

  const handleError = (payload) => {
    for (const entry of subscriptions.values()) {
      try {
        entry.onError?.(new DashboardChannelError(CHANNEL_API_ERRORS.PERMISSION_DENIED, payload?.reason || "event access revoked"))
      } catch (_error) {}
    }
  }

  // Called after every (re)join so subscriptions survive a reconnect.
  const resubscribeAll = () => {
    for (const [id, entry] of subscriptions.entries()) send(id, entry)
  }

  return {
    handleBatch,
    handleError,
    resubscribeAll,
    subscriptionCount: () => subscriptions.size,
    clear: () => subscriptions.clear(),
    publicApi: () => ({
      allowed: () => capabilityAllowed(EVENTS_SUBSCRIBE_CAPABILITY) && permitted,
      subscribe,
    }),
  }
}

export function createFrameRefresh({capabilityAllowed = () => false, getChannel = () => null} = {}) {
  return () => {
    if (!capabilityAllowed("srql.execute")) {
      return Promise.reject(
        new DashboardChannelError(CHANNEL_API_ERRORS.CAPABILITY_DENIED, "dashboard capability is not approved: srql.execute"),
      )
    }

    return pushWithReply(getChannel, "frames:refresh", {}).then(
      () => ({refreshed: true}),
      (error) => {
        if (error?.code === CHANNEL_API_ERRORS.REJECTED) return {refreshed: false, reason: error.message}
        throw error
      },
    )
  }
}
