import assert from "node:assert/strict"
import test from "node:test"

import {createHarnessActionsApi, createHarnessEventsApi, eventMatches, withFixtureTimelineKey} from "../harness/runtime.js"

const jam = {
  id: "evt-1",
  log_provider: "plugin:demo-ot-plc",
  class_uid: 1008,
  severity_id: 4,
  device: {uid: "sr:device:plc-07"},
  metadata: {fault_kind: "jam"},
}

// Timers fire synchronously so the timeline runs inside the test.
const immediate = (callback) => {
  callback()
  return 0
}

test("filters match the production channel's keys", () => {
  assert.ok(eventMatches({log_provider: "plugin:demo-ot-plc", class_uid: [1008]}, jam))
  assert.ok(eventMatches({device_uid: "sr:device:plc-07", min_severity_id: 4, metadata: {fault_kind: "jam"}}, jam))
  assert.equal(eventMatches({class_uid: "1008"}, jam), false)
  assert.equal(eventMatches({min_severity_id: "4"}, jam), false)
  assert.equal(eventMatches({min_severity_id: 5}, jam), false)
  assert.equal(eventMatches({metadata: {fault_kind: "mis_sort"}}, jam), false)
  assert.equal(eventMatches({unknown_key: "x"}, jam), false)
})

test("fixture events replay on the timeline to matching subscriptions", () => {
  const events = createHarnessEventsApi({setTimer: immediate, clearTimer: () => {}})
  const received = []
  events.publicApi().subscribe({log_provider: "plugin:demo-ot-plc"}, (batch) => received.push(...batch))
  events.publicApi().subscribe({log_provider: "plugin:other"}, () => assert.fail("filtered subscription fired"))

  events.replay([{at_ms: 1500, event: jam}])

  assert.deepEqual(received, [jam])
})

test("an invoked action walks to succeeded and delivers the events it emits", async () => {
  const events = createHarnessEventsApi({setTimer: immediate, clearTimer: () => {}})
  const received = []
  events.publicApi().subscribe({metadata: {fault_kind: "jam"}}, (batch) => received.push(...batch))
  const calls = []
  const actions = createHarnessActionsApi({
    onCall: (line) => calls.push(line),
    getActions: () => [
      {
        id: "northbound:jam",
        label: "Inject jam",
        scope: "device",
        plugin_id: "demo-ot-plc",
        provider_type: "wasm_plugin",
        emits: [jam],
      },
    ],
    events,
    setTimer: immediate,
  }).publicApi()

  const states = []
  const result = await actions.invoke(
    {actionId: "northbound:jam", targets: [{deviceUid: "sr:device:plc-07"}]},
    {onProgress: (progress) => states.push(progress.state)},
  )

  assert.equal(result.state, "succeeded")
  assert.deepEqual(states, ["dispatching", "running", "succeeded"])
  assert.deepEqual(received, [jam])
  assert.deepEqual(calls, ["action invoke northbound:jam"])
  assert.deepEqual(await actions.list({scope: "device", pluginId: "demo-ot-plc", providerType: "wasm_plugin"}), [
    {id: "northbound:jam", label: "Inject jam", scope: "device", plugin_id: "demo-ot-plc", provider_type: "wasm_plugin"},
  ])
})

test("action lists narrow by scope and provider", async () => {
  const actions = createHarnessActionsApi({
    getActions: () => [
      {id: "device-jam", scope: "device", plugin_id: "demo-ot-plc", provider_type: "wasm_plugin"},
      {id: "interface-jam", scope: "interface", plugin_id: "demo-ot-plc", provider_type: "wasm_plugin"},
      {id: "other-plugin", scope: "device", plugin_id: "other", provider_type: "wasm_plugin"},
    ],
  }).publicApi()

  assert.deepEqual((await actions.list({scope: "device", pluginId: "demo-ot-plc"})).map((action) => action.id), ["device-jam"])
  assert.deepEqual((await actions.list({scope: "interface", providerType: "wasm_plugin"})).map((action) => action.id), [
    "interface-jam",
  ])
})

test("invalid event filters are rejected before subscribing", () => {
  const events = createHarnessEventsApi()

  assert.throws(() => events.publicApi().subscribe({class_uid: "1008"}, () => {}), {code: "invalid_request"})
  assert.throws(() => events.publicApi().subscribe({min_severity_id: "4"}, () => {}), {code: "invalid_request"})
})

test("events require the manifest subscribe capability", () => {
  const events = createHarnessEventsApi({capabilityAllowed: () => false}).publicApi()

  assert.equal(events.allowed(), false)
  assert.throws(() => events.subscribe({log_provider: "plugin:demo-ot-plc"}, () => {}), {code: "capability_denied"})
})

test("actions require the manifest invoke capability", async () => {
  const actions = createHarnessActionsApi({
    capabilityAllowed: () => false,
    getActions: () => [{id: "a", scope: "device"}],
  }).publicApi()

  assert.equal(actions.allowed(), false)
  await assert.rejects(actions.list({scope: "device"}), {code: "capability_denied"})
  await assert.rejects(actions.invoke({actionId: "a", targets: [{deviceUid: "d"}]}), {code: "capability_denied"})
})

test("unknown actions and invalid action requests are rejected", async () => {
  const actions = createHarnessActionsApi({getActions: () => [{id: "a", scope: "device"}]}).publicApi()

  await assert.rejects(actions.invoke({actionId: "missing", targets: [{deviceUid: "d"}]}), {code: "rejected"})
  await assert.rejects(actions.invoke({actionId: "a", scope: "bogus", targets: [{deviceUid: "d"}]}), {code: "invalid_request"})
  await assert.rejects(actions.invoke({actionId: "a", targets: []}), {code: "invalid_request"})
  await assert.rejects(actions.invoke({actionId: "a", targets: Array.from({length: 51}, () => ({deviceUid: "d"}))}), {
    code: "invalid_request",
  })
  await assert.rejects(actions.invoke({actionId: "a", targets: [{}]}), {code: "invalid_request"})
  await assert.rejects(actions.invoke({actionId: "a", scope: "interface", targets: [{deviceUid: "d"}]}), {
    code: "invalid_request",
  })
  await assert.rejects(
    actions.invoke({actionId: "a", scope: "interface", targets: [{deviceUid: "d", interfaceUid: "if-1"}]}),
    {code: "rejected"},
  )
  await assert.rejects(actions.invoke({targets: [{deviceUid: "d"}]}), {code: "invalid_request"})
})

test("fixture timeline keys change frame identity without mutating fixtures", () => {
  const frames = [{id: "schedule", results: []}]
  const first = withFixtureTimelineKey(frames, "steady:1")
  const second = withFixtureTimelineKey(frames, "steady:2")

  assert.deepEqual(first, [{id: "schedule", results: [], fixture_timeline_key: "steady:1"}])
  assert.deepEqual(second, [{id: "schedule", results: [], fixture_timeline_key: "steady:2"}])
  assert.deepEqual(frames, [{id: "schedule", results: []}])
})

test("a fixture resolver can switch fixtures, replace frames, or leave them", async () => {
  const {interpretFixtureResolution, pickFixtureResolver} = await import("../harness/runtime.js")
  const fixtures = {steady: "/@fixtures/steady.json", jam: "/@fixtures/jam.json"}

  assert.deepEqual(interpretFixtureResolution("jam", fixtures), {kind: "fixture", name: "jam"})
  assert.deepEqual(interpretFixtureResolution([{id: "a"}], fixtures), {kind: "frames", frames: [{id: "a"}]})
  assert.deepEqual(interpretFixtureResolution({frames: [{id: "b"}]}, fixtures), {kind: "frames", frames: [{id: "b"}]})
  assert.deepEqual(interpretFixtureResolution(undefined, fixtures), {kind: "none"})
  assert.throws(() => interpretFixtureResolution("missing", fixtures), /unknown fixture "missing"/)

  const named = () => "jam"
  assert.equal(pickFixtureResolver({resolveFixture: named}), named)
  assert.equal(pickFixtureResolver({default: () => "steady"}), null)
  assert.equal(pickFixtureResolver({}), null)
})
