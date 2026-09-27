// Loads the real harness fixtures off disk and drives them through the same
// path an offline `npm run dev` session takes: schedule metrics into the
// countdown, fixture actions into trigger buttons, and timeline-replayed
// events into open incidents. Steady stays quiet; mid-fault shows the
// incident while the countdown keeps ticking.
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import React from "react"
import {renderToStaticMarkup} from "react-dom/server"

import {createDemoKit} from "./kit.js"
import {faultTriggers, foldIncidents, headlineIncident, isFaultEvent, scheduleStatus} from "./presenter.js"

const T0 = Date.parse("2026-01-01T00:00:00Z")

function loadFixture(name) {
  const url = new URL(`./fixtures/${name}`, import.meta.url)
  return JSON.parse(readFileSync(url, "utf8"))
}

function scheduleRows(fixture) {
  return fixture.frames.find((frame) => frame.id === "schedule").results
}

// The harness replays `events` on a timeline from fixture load; folding only
// the events whose `at_ms` has passed reproduces the dashboard state then.
function openAt(fixture, atMs) {
  const arrived = fixture.events.filter((entry) => entry.at_ms <= atMs).map((entry) => entry.event)
  return foldIncidents(new Map(), arrived)
}

function fakeSdk({allowed = true, actions = []} = {}) {
  return {
    useDashboardActions: () => ({allowed, actions, invocations: {}, invoke: () => {}}),
    useDashboardEvents: () => ({allowed: true, error: null}),
    useFrameRefresh: () => () => Promise.resolve({refreshed: true}),
  }
}

test("both fixtures are harness object form: schedule frames, fault actions, timeline events", () => {
  for (const name of ["presenter-steady.json", "presenter-fault.json"]) {
    const fixture = loadFixture(name)
    assert.ok(Array.isArray(fixture.frames) && fixture.frames.length > 0, `${name} needs frames`)
    assert.ok(Array.isArray(fixture.actions) && fixture.actions.length > 0, `${name} needs actions`)
    assert.ok(Array.isArray(fixture.events), `${name} needs an events array`)

    const rows = scheduleRows(fixture)
    assert.ok(rows.some((row) => row.metric_name === "demo.fault.active"), `${name} needs the active metric`)
    assert.ok(rows.some((row) => row.metric_name === "demo.fault.next_at"), `${name} needs the next_at metric`)

    const triggers = faultTriggers(fixture.actions)
    assert.deepEqual(
      triggers.map((trigger) => trigger.kind),
      ["overheat"],
    )
  }
})

test("steady renders the countdown and trigger with no incident", () => {
  const fixture = loadFixture("presenter-steady.json")
  const status = scheduleStatus(scheduleRows(fixture), T0)
  assert.equal(status.visible, true)
  assert.equal(status.activeCount, 0)
  assert.equal(status.countdownMs, 300_000)
  assert.equal(headlineIncident(openAt(fixture, 60_000)), null)

  const {PresenterStrip} = createDemoKit({React, sdk: fakeSdk({actions: fixture.actions})})
  const html = renderToStaticMarkup(React.createElement(PresenterStrip, {scheduleRows: scheduleRows(fixture), now: T0}))
  assert.match(html, /No active incident/)
  assert.match(html, /Next overheat in 05:00/)
  assert.match(html, /data-fault-trigger="overheat"[^>]*>Overheat</)
})

test("mid-fault the replayed opening event becomes the active incident", () => {
  const fixture = loadFixture("presenter-fault.json")
  const status = scheduleStatus(scheduleRows(fixture), T0)
  assert.equal(status.activeCount, 1)

  const midFault = openAt(fixture, 5_000)
  assert.equal(midFault.size, 1)
  const incident = headlineIncident(midFault)
  assert.equal(incident.kind, "overheat")
  assert.equal(incident.assetId, "sensor-a")

  const {PresenterStrip} = createDemoKit({React, sdk: fakeSdk({actions: fixture.actions})})
  const html = renderToStaticMarkup(
    React.createElement(PresenterStrip, {scheduleRows: scheduleRows(fixture), incident, now: T0}),
  )
  assert.match(html, /Active: overheat on sensor-a/)
  assert.match(html, /Next overheat in 15:00/)
})

test("once the resolving event replays the incident clears", () => {
  const fixture = loadFixture("presenter-fault.json")
  assert.equal(openAt(fixture, 60_000).size, 0)
})

test("a successful invocation's emitted event opens the same incident", () => {
  const fixture = loadFixture("presenter-steady.json")
  const emitted = fixture.actions.flatMap((action) => action.emits || [])
  assert.ok(emitted.length > 0, "fault action declares what its invocation emits")
  for (const event of emitted) assert.equal(isFaultEvent(event), true)
  const open = foldIncidents(new Map(), emitted)
  assert.equal(open.size, 1)
  assert.equal(headlineIncident(open).kind, "overheat")
})
