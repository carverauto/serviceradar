// Mocks of the host action, live-event and frame-refresh APIs (`api.actions`,
// `api.events`, `api.refreshFrames`) for the dashboard dev harness.
//
// A fixture file may carry, next to its frames:
//
//   {
//     "frames": [...],
//     "actions": [{"id": "northbound:jam", "label": "Inject jam", ...,
//                  "emits": [{"id": "evt-1", "log_provider": "plugin:demo", ...}]}],
//     "events": [{"at_ms": 2000, "event": {"id": "evt-0", "severity_id": 4, ...}}]
//   }
//
// `events` replay on a timeline from the moment the fixture loads; a successful
// action invocation delivers its `emits` events, so presenter-triggered flows
// work offline. Filters match the same keys the production channel accepts.

export const MAX_EVENT_SUBSCRIPTIONS = 8

function harnessError(code, message) {
  const error = new Error(message)
  error.name = "DashboardChannelError"
  error.code = code
  return error
}

function stringSet(value) {
  if (typeof value === "string") return new Set([value])
  if (Array.isArray(value) && value.length > 0 && value.every((entry) => typeof entry === "string")) {
    return new Set(value)
  }
  return null
}

function integerSet(value) {
  if (Number.isInteger(value)) return new Set([value])
  if (Array.isArray(value) && value.length > 0 && value.every((entry) => Number.isInteger(entry))) {
    return new Set(value)
  }
  return null
}

function scalar(value) {
  return ["string", "number", "boolean"].includes(typeof value)
}

function normalizeEventFilter(filter = {}) {
  if (!filter || typeof filter !== "object" || Array.isArray(filter)) return null
  const normalized = {}
  for (const [key, expected] of Object.entries(filter)) {
    switch (key) {
      case "log_provider":
      case "log_name":
      case "device_uid": {
        const values = stringSet(expected)
        if (!values) return null
        normalized[key] = values
        break
      }
      case "class_uid": {
        const values = integerSet(expected)
        if (!values) return null
        normalized[key] = values
        break
      }
      case "min_severity_id":
        if (!Number.isInteger(expected)) return null
        normalized[key] = expected
        break
      case "metadata":
        if (!expected || typeof expected !== "object" || Array.isArray(expected) || Object.keys(expected).length > 8) {
          return null
        }
        normalized[key] = Object.fromEntries(Object.entries(expected).map(([field, value]) => [String(field), value]))
        if (!Object.values(normalized[key]).every(scalar)) return null
        break
      default:
        return null
    }
  }
  return normalized
}

function normalizedEventMatches(normalized, event = {}) {
  return Object.entries(normalized).every(([key, expected]) => {
    switch (key) {
      case "log_provider":
      case "log_name":
      case "class_uid":
        return expected.has(event?.[key])
      case "device_uid":
        return expected.has(event?.device?.uid)
      case "min_severity_id":
        return Number.isInteger(event?.severity_id) && event.severity_id >= expected
      case "metadata":
        return Object.entries(expected).every(
          ([field, value]) => String(event?.metadata?.[field] ?? "") === String(value),
        )
      default:
        return false
    }
  })
}

export function eventMatches(filter = {}, event = {}) {
  const normalized = normalizeEventFilter(filter)
  return normalized ? normalizedEventMatches(normalized, event) : false
}

function normalizeTargets(targets) {
  if (!Array.isArray(targets) || targets.length === 0) {
    throw harnessError("invalid_request", "actions.invoke requires at least one target")
  }
  return targets.map((target) => {
    const deviceUid = String(target?.deviceUid ?? target?.device_uid ?? "").trim()
    const interfaceUid = String(target?.interfaceUid ?? target?.interface_uid ?? "").trim()
    if (!deviceUid) throw harnessError("invalid_request", "every action target needs a device uid")
    return interfaceUid ? {device_uid: deviceUid, interface_uid: interfaceUid} : {device_uid: deviceUid}
  })
}

export function createHarnessEventsApi({onCall = () => {}, setTimer = setTimeout, clearTimer = clearTimeout} = {}) {
  const subscriptions = new Map()
  let timers = []
  let sequence = 0

  const deliver = (events) => {
    for (const {filter, onEvents} of subscriptions.values()) {
      const matched = events.filter((event) => normalizedEventMatches(filter, event))
      if (matched.length > 0) {
        try {
          onEvents(matched)
        } catch (_error) {}
      }
    }
  }

  return {
    deliver,
    replay(timeline = []) {
      timers.forEach((timer) => clearTimer(timer))
      timers = (Array.isArray(timeline) ? timeline : []).map((entry) =>
        setTimer(() => deliver([entry.event]), Number(entry.at_ms) || 0),
      )
    },
    stop() {
      timers.forEach((timer) => clearTimer(timer))
      timers = []
    },
    publicApi: () => ({
      allowed: () => true,
      subscribe(filter = {}, onEvents) {
        if (typeof onEvents !== "function") throw harnessError("invalid_request", "events.subscribe requires a callback")
        if (subscriptions.size >= MAX_EVENT_SUBSCRIPTIONS) {
          throw harnessError("invalid_request", `at most ${MAX_EVENT_SUBSCRIPTIONS} event subscriptions are allowed`)
        }
        const normalized = normalizeEventFilter(filter)
        if (!normalized) throw harnessError("invalid_request", "events.subscribe received an invalid filter")
        sequence += 1
        const id = `sub-${sequence}`
        subscriptions.set(id, {filter: normalized, onEvents})
        onCall(`events subscribe ${JSON.stringify(filter)}`)
        return () => subscriptions.delete(id)
      },
    }),
  }
}

export function createHarnessActionsApi({
  onCall = () => {},
  getActions = () => [],
  events = null,
  setTimer = setTimeout,
  stepMs = 400,
} = {}) {
  let sequence = 0

  return {
    publicApi: () => ({
      allowed: () => true,
      list: async () => getActions().map(({emits: _emits, ...action}) => ({...action})),
      invoke(request = {}, {onProgress} = {}) {
        const actionId = String(request.actionId ?? request.action_id ?? "").trim()
        if (!actionId) return Promise.reject(harnessError("invalid_request", "actions.invoke requires an actionId"))
        try {
          normalizeTargets(request.targets)
        } catch (error) {
          return Promise.reject(error)
        }
        const action = getActions().find((entry) => entry.id === actionId)
        if (!action) return Promise.reject(harnessError("rejected", "Select a launchable action."))

        sequence += 1
        const invocationId = `harness-invocation-${sequence}`
        onCall(`action invoke ${action.id}`)

        return new Promise((resolve) => {
          const steps = ["dispatching", "running", "succeeded"]
          const advance = (index) => {
            const progress = {invocation_id: invocationId, state: steps[index], result_summary: {}}
            try {
              onProgress?.(progress)
            } catch (_error) {}

            if (index < steps.length - 1) {
              setTimer(() => advance(index + 1), stepMs)
            } else {
              if (events && Array.isArray(action.emits)) events.deliver(action.emits)
              resolve(progress)
            }
          }
          advance(0)
        })
      },
    }),
  }
}

// Fixture resolution for `srql.update` in the dev harness.
//
// A project may name a resolver module in dashboard.config.mjs
// (`fixtureResolver: "fixtures/resolve.js"`). Its `resolveFixture` export is
// called on every SRQL update with
// `{query, frameQueries, frames, fixtures, activeFixture}` and may return, or
// resolve to:
//   - a fixture name (string) to switch to,
//   - an array of frames, or `{frames: [...]}`, to show instead,
//   - nothing, to leave the frames as they are.
export function interpretFixtureResolution(result, fixtures = {}) {
  if (typeof result === "string") {
    if (!Object.prototype.hasOwnProperty.call(fixtures || {}, result)) {
      throw harnessError("unknown_fixture", `fixture resolver returned unknown fixture "${result}"`)
    }
    return {kind: "fixture", name: result}
  }
  if (Array.isArray(result)) return {kind: "frames", frames: result}
  if (result && Array.isArray(result.frames)) return {kind: "frames", frames: result.frames}
  return {kind: "none"}
}

export function pickFixtureResolver(module) {
  if (!module) return null
  if (typeof module.resolveFixture === "function") return module.resolveFixture
  return null
}
