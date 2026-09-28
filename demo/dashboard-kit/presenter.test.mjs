import assert from "node:assert/strict"
import test from "node:test"

import {
  faultEventFilter,
  faultTriggers,
  foldIncidents,
  formatCountdown,
  headlineIncident,
  latestSampleMs,
  normalizeActionTargets,
  scheduleStatus,
  triggerRequest,
} from "./presenter.js"

const T0 = Date.parse("2026-01-01T00:00:00Z")

const scheduleRows = [
  {metric_name: "demo.fault.active", value: 0, timestamp: "2026-01-01T00:00:00Z"},
  {
    metric_name: "demo.fault.next_at",
    value: T0 / 1000 + 90,
    timestamp: "2026-01-01T00:00:00Z",
    tags: {kind: "jam", target: "conveyor-07"},
  },
]

function faultEvent(state, faultId, extra = {}) {
  return {
    id: `${faultId}/${state}`,
    log_name: "demo.fault",
    severity_id: state === "open" ? 4 : 1,
    time: "2026-01-01T00:00:10Z",
    metadata: {"demo.fault.state": state, "demo.fault.kind": "jam", "demo.fault.id": faultId, asset_id: "conveyor-07"},
    ...extra,
  }
}

test("the countdown reads the simulator's next fault", () => {
  const status = scheduleStatus(scheduleRows, T0)
  assert.equal(status.visible, true)
  assert.equal(status.activeCount, 0)
  assert.equal(status.nextKind, "jam")
  assert.equal(status.nextTarget, "conveyor-07")
  assert.equal(status.countdownMs, 90_000)
  assert.equal(formatCountdown(status.countdownMs), "01:30")
})

test("the countdown hides when the schedule metrics are absent, as with a real source", () => {
  assert.deepEqual(scheduleStatus([], T0), {visible: false})
  assert.deepEqual(scheduleStatus([{metric_name: "temp_c", value: 21}], T0), {visible: false})
})

test("the newest sample time anchors an offline clock", () => {
  assert.equal(latestSampleMs(scheduleRows), T0)
  assert.equal(latestSampleMs([]), null)
  assert.equal(latestSampleMs([{metric_name: "temp_c", value: 21}]), null)
})

test("the latest schedule sample wins and a past start clamps to zero", () => {
  const rows = [
    ...scheduleRows,
    {metric_name: "demo.fault.next_at", value: T0 / 1000 - 5, timestamp: "2026-01-01T00:00:05Z", tags: {kind: "eds_timeout"}},
  ]
  const status = scheduleStatus(rows, T0)
  assert.equal(status.nextKind, "eds_timeout")
  assert.equal(status.countdownMs, 0)
  assert.equal(formatCountdown(3_725_000), "1:02:05")
})

test("fault events open and resolve incidents by fault id", () => {
  let open = foldIncidents(new Map(), [faultEvent("open", "jam@conveyor-07#1")])
  assert.equal(open.size, 1)
  assert.equal(headlineIncident(open).assetId, "conveyor-07")

  open = foldIncidents(open, [faultEvent("resolved", "jam@conveyor-07#1"), faultEvent("resolved", "jam@conveyor-07#1")])
  assert.equal(open.size, 0)
  assert.equal(headlineIncident(open), null)
})

test("fault fields are read from event metadata", () => {
  const unmappedOnly = faultEvent("open", "x#1", {metadata: {}, unmapped: {"demo.fault.state": "open", "demo.fault.kind": "jam", "demo.fault.id": "x#1", asset_id: "a"}})
  assert.equal(foldIncidents(new Map(), [unmappedOnly]).size, 0)
  assert.equal(foldIncidents(new Map(), [{log_name: "other", metadata: {"demo.fault.id": "y"}}]).size, 0)
})

test("the headline is the most severe open incident", () => {
  const open = foldIncidents(new Map(), [
    faultEvent("open", "minor#1", {severity_id: 2}),
    faultEvent("open", "major#1", {severity_id: 5}),
  ])
  assert.equal(headlineIncident(open).faultId, "major#1")
})

test("one trigger per declared fault kind, hidden without permission", () => {
  const actions = [
    {id: "act-status", input_schema: {properties: {}}},
    {
      id: "act-fault",
      requires_confirmation: false,
      input_schema: {properties: {fault_kind: {enum: ["jam", "eds_timeout"], "x-enum-labels": ["Jam", "Screening timeout"]}}},
    },
  ]

  assert.deepEqual(
    faultTriggers(actions).map(({kind, label}) => [kind, label]),
    [["jam", "Jam"], ["eds_timeout", "Screening timeout"]],
  )
  assert.deepEqual(faultTriggers(actions, {allowed: false}), [])
  assert.deepEqual(faultTriggers([{id: "a", input_schema: {properties: {fault_kind: {enum: ["mis_sort"]}}}}])[0].label, "Mis sort")
  assert.deepEqual(faultTriggers([]), [])
})

test("a trigger invokes the plugin's fault action with its kind", () => {
  const [trigger] = faultTriggers([{id: "act-fault", input_schema: {properties: {fault_kind: {enum: ["jam"]}}}}])
  assert.deepEqual(triggerRequest(trigger, {targets: [{deviceUid: "sr:device:c7"}], input: {duration_seconds: 120}}), {
    actionId: "act-fault",
    scope: "device",
    targets: [{device_uid: "sr:device:c7"}],
    input: {duration_seconds: 120, fault_kind: "jam"},
  })
})

test("action targets require devices and interfaces by scope", () => {
  assert.deepEqual(normalizeActionTargets("device", [{deviceUid: "sr:device:c7", interfaceUid: "if-1"}]), [
    {device_uid: "sr:device:c7"},
  ])
  assert.deepEqual(normalizeActionTargets("interface", [{deviceUid: "sr:device:c7", interfaceUid: "if-1"}]), [
    {device_uid: "sr:device:c7", interface_uid: "if-1"},
  ])
  assert.deepEqual(normalizeActionTargets("device", []), [])
  assert.deepEqual(normalizeActionTargets("device", Array.from({length: 51}, () => ({device_uid: "sr:device:c7"}))), [])
  assert.deepEqual(normalizeActionTargets("device", [{}]), [])
  assert.deepEqual(normalizeActionTargets("interface", [{device_uid: "sr:device:c7"}]), [])
  assert.deepEqual(normalizeActionTargets("unknown", [{device_uid: "sr:device:c7"}]), [])
  assert.throws(() => triggerRequest({actionId: "act-fault", kind: "jam"}, {targets: []}), /requires at least one/)
})

test("the event filter scopes to the plugin's fault events", () => {
  assert.deepEqual(faultEventFilter("plugin:demo-ot-plc"), {log_name: "demo.fault", log_provider: "plugin:demo-ot-plc"})
  assert.deepEqual(faultEventFilter(), {log_name: "demo.fault"})
})
