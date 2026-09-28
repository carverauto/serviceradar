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

function asSet(value) {
  return new Set((Array.isArray(value) ? value : [value]).map((entry) => String(entry)))
}

export function eventMatches(filter = {}, event = {}) {
  return Object.entries(filter || {}).every(([key, expected]) => {
    switch (key) {
      case "log_provider":
      case "log_name":
      case "class_uid":
        return asSet(expected).has(String(event?.[key]))
      case "device_uid":
        return asSet(expected).has(String(event?.device?.uid))
      case "min_severity_id":
        return Number(event?.severity_id) >= Number(expected)
      case "metadata":
        return Object.entries(expected || {}).every(
          ([field, value]) => String(event?.metadata?.[field] ?? "") === String(value),
        )
      default:
        return false
    }
  })
}

export function createHarnessEventsApi({onCall = () => {}, setTimer = setTimeout, clearTimer = clearTimeout} = {}) {
  const subscriptions = new Map()
  let timers = []
  let sequence = 0

  const deliver = (events) => {
    for (const {filter, onEvents} of subscriptions.values()) {
      const matched = events.filter((event) => eventMatches(filter, event))
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
        sequence += 1
        const id = `sub-${sequence}`
        subscriptions.set(id, {filter: {...filter}, onEvents})
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
        const action = getActions().find((entry) => entry.id === request.actionId || entry.id === request.action_id)
        if (!action) return Promise.reject(harnessError("rejected", "Select a launchable action."))
        if (!Array.isArray(request.targets) || request.targets.length === 0) {
          return Promise.reject(harnessError("invalid_request", "actions.invoke requires at least one target"))
        }

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
