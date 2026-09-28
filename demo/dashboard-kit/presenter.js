// Presenter-strip state for demo dashboards, derived from what the platform
// already reports. No React and no SDK imports, so it runs under plain node.
//
// Inputs, all produced by the demo pipeline (design D13):
//   - schedule rows: the latest `demo.fault.active` / `demo.fault.next_at`
//     metrics the simulator publishes. A real Source publishes neither, and the
//     countdown then hides.
//   - fault events: OCSF events with log_name "demo.fault" whose metadata carries
//     `demo.fault.state` ("open" | "resolved"), `demo.fault.kind`,
//     `demo.fault.id` and `asset_id` (demo/pluginkit mirrors them there).
//   - actions: the viewer's launchable plugin actions (useDashboardActions). The
//     fault action is the one whose input schema has a `fault_kind` enum.

export const FAULT_ACTIVE_METRIC = "demo.fault.active"
export const FAULT_NEXT_AT_METRIC = "demo.fault.next_at"
export const FAULT_LOG_NAME = "demo.fault"

const STATE = "demo.fault.state"
const KIND = "demo.fault.kind"
const FAULT_ID = "demo.fault.id"
const ASSET = "asset_id"
const MAX_ACTION_TARGETS = 50

function metricName(row) {
  return row?.metric_name
}

function rowTime(row) {
  const value = row?.timestamp
  const ms = typeof value === "number" ? value : Date.parse(value)
  return Number.isFinite(ms) ? ms : 0
}

function rowLabels(row) {
  return row?.tags ?? {}
}

function latest(rows, name) {
  let best = null
  for (const row of rows || []) {
    if (metricName(row) !== name) continue
    if (!best || rowTime(row) >= rowTime(best)) best = row
  }
  return best
}

/**
 * Schedule status for the countdown. `visible` is false when the simulator's
 * metrics are absent (for example with a real Source), so the strip hides the
 * countdown instead of showing a wrong one.
 */
export function scheduleStatus(rows, nowMs = Date.now()) {
  const active = latest(rows, FAULT_ACTIVE_METRIC)
  const next = latest(rows, FAULT_NEXT_AT_METRIC)
  if (!active && !next) return {visible: false}

  const activeCount = active ? Number(active.value) || 0 : null
  if (!next) return {visible: true, activeCount, nextAtMs: null, countdownMs: null}

  const labels = rowLabels(next)
  const nextAtMs = Number(next.value) * 1000
  return {
    visible: true,
    activeCount,
    nextAtMs,
    nextKind: labels.kind ?? null,
    nextTarget: labels.target ?? null,
    countdownMs: Math.max(0, nextAtMs - nowMs),
  }
}

/**
 * Newest sample time across schedule rows, or null when the rows carry none.
 * An offline dashboard anchors its clock here and advances from mount, so a
 * fixture sampled long ago still counts down instead of clamping to 00:00
 * against the wall clock. Live rows sample near now, so the anchor is ~now.
 */
export function latestSampleMs(rows) {
  let best = null
  for (const row of rows || []) {
    const ms = rowTime(row)
    if (ms > 0 && (best === null || ms > best)) best = ms
  }
  return best
}

export function fixtureScheduleNow(sampleMs, fixtureFrameKey, observedAtMs, wallNowMs = Date.now()) {
  if (!fixtureFrameKey || sampleMs === null || sampleMs === undefined) return undefined
  const sample = Number(sampleMs)
  const observedAt = Number(observedAtMs)
  const wallNow = Number(wallNowMs)
  if (!Number.isFinite(sample) || !Number.isFinite(observedAt) || !Number.isFinite(wallNow)) return undefined
  return sample + Math.max(0, wallNow - observedAt)
}

/** "mm:ss", or "h:mm:ss" past an hour. */
export function formatCountdown(ms) {
  const total = Math.max(0, Math.round(ms / 1000))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = total % 60
  const pad = (n) => String(n).padStart(2, "0")
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(seconds)}` : `${pad(minutes)}:${pad(seconds)}`
}

function faultFields(event) {
  const meta = event?.metadata || {}
  return {state: meta[STATE], kind: meta[KIND], faultId: meta[FAULT_ID], assetId: meta[ASSET]}
}

export function isFaultEvent(event) {
  return event?.log_name === FAULT_LOG_NAME && Boolean(faultFields(event).faultId)
}

/**
 * Folds fault events into the set of open incidents, keyed by fault id.
 * A resolving event removes its fault; a duplicate resolve is harmless.
 */
export function foldIncidents(open, events) {
  const next = new Map(open)
  for (const event of events || []) {
    if (!isFaultEvent(event)) continue
    const {state, kind, faultId, assetId} = faultFields(event)
    if (state === "resolved") {
      next.delete(faultId)
    } else if (state === "open") {
      next.set(faultId, {
        faultId,
        kind,
        assetId,
        eventId: event.id,
        severityId: event.severity_id ?? null,
        message: event.message ?? null,
        openedAt: event.time ?? null,
      })
    }
  }
  return next
}

/** The incident to headline: the most severe, then the most recently opened. */
export function headlineIncident(open) {
  let best = null
  for (const incident of open.values()) {
    if (
      !best ||
      (incident.severityId ?? 0) > (best.severityId ?? 0) ||
      ((incident.severityId ?? 0) === (best.severityId ?? 0) && String(incident.openedAt) > String(best.openedAt))
    ) {
      best = incident
    }
  }
  return best
}

/** The event filter a demo dashboard subscribes with for its plugin's faults. */
export function faultEventFilter(logProvider) {
  return logProvider ? {log_name: FAULT_LOG_NAME, log_provider: logProvider} : {log_name: FAULT_LOG_NAME}
}

/**
 * One trigger button per fault kind the plugin's fault action declares. Hidden
 * (empty) when the viewer cannot invoke actions or the plugin exposes none.
 */
export function faultTriggers(actions, {allowed = true} = {}) {
  if (!allowed) return []
  const action = (actions || []).find((candidate) => {
    const kinds = candidate?.input_schema?.properties?.fault_kind?.enum
    return Array.isArray(kinds) && kinds.length > 0
  })
  if (!action) return []

  const property = action.input_schema.properties.fault_kind
  const labels = property["x-enum-labels"] || []
  return property.enum.map((kind, index) => ({
    actionId: action.id,
    kind,
    label: labels[index] || humanize(kind),
  }))
}

function humanize(kind) {
  const text = String(kind).replace(/[_-]+/g, " ").trim()
  return text.charAt(0).toUpperCase() + text.slice(1)
}

export function normalizeActionTargets(scope = "device", targets = []) {
  if (!Array.isArray(targets) || targets.length === 0 || targets.length > MAX_ACTION_TARGETS) return []
  const normalizedScope = String(scope || "device")
  if (normalizedScope !== "device" && normalizedScope !== "interface") return []
  const needsInterface = normalizedScope === "interface"
  const normalized = []
  for (const target of targets) {
    const deviceUid = String(target?.deviceUid ?? target?.device_uid ?? "").trim()
    const interfaceUid = String(target?.interfaceUid ?? target?.interface_uid ?? "").trim()
    if (!deviceUid || (needsInterface && !interfaceUid)) return []
    normalized.push(needsInterface ? {device_uid: deviceUid, interface_uid: interfaceUid} : {device_uid: deviceUid})
  }
  return normalized
}

export function hasActionTargets(scope = "device", targets = []) {
  return normalizeActionTargets(scope, targets).length > 0
}

/** The invocation request a trigger button sends through useDashboardActions. */
export function triggerRequest(trigger, {scope = "device", targets = [], input = {}} = {}) {
  const normalizedTargets = normalizeActionTargets(scope, targets)
  if (normalizedTargets.length === 0) throw new Error("fault trigger requires at least one valid target")
  return {actionId: trigger.actionId, scope, targets: normalizedTargets, input: {...input, fault_kind: trigger.kind}}
}

/** Link to the product's alert view for an incident, when its alert id is known. */
export function alertHref(incident) {
  return incident?.alertId ? `/alerts/${encodeURIComponent(incident.alertId)}` : "/alerts"
}
