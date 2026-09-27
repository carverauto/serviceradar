// Server-renders the kit with React from web-ng's Bazel-managed node_modules
// (paths passed in by //demo/dashboard-kit:kit_test) and stand-in SDK hooks.
import assert from "node:assert/strict"
import {createRequire} from "node:module"
import {resolve} from "node:path"
import test from "node:test"

import {createDemoKit} from "./kit.js"

const require = createRequire(import.meta.url)
const React = require(resolve(process.env.DEMO_KIT_REACT_DIR))
const {renderToStaticMarkup} = require(resolve(process.env.DEMO_KIT_REACT_DOM_DIR, "server.node.js"))

const faultAction = {
  id: "act-fault",
  input_schema: {properties: {fault_kind: {enum: ["jam", "eds_timeout"], "x-enum-labels": ["Jam", "Screening timeout"]}}},
}

function fakeSdk({allowed = true, actions = [faultAction], invocations = {}} = {}) {
  const calls = {invoked: [], subscribed: []}
  return {
    calls,
    sdk: {
      useDashboardActions: () => ({
        allowed,
        actions,
        invocations,
        invoke: (request) => calls.invoked.push(request),
      }),
      useDashboardEvents: (filter) => {
        calls.subscribed.push(filter)
        return {allowed: true, error: null}
      },
      useFrameRefresh: () => () => Promise.resolve({refreshed: true}),
    },
  }
}

const T0 = Date.parse("2026-01-01T00:00:00Z")
const scheduleRows = [
  {metric_name: "demo.fault.active", value: 0, timestamp: "2026-01-01T00:00:00Z"},
  {metric_name: "demo.fault.next_at", value: T0 / 1000 + 90, timestamp: "2026-01-01T00:00:00Z", tags: {kind: "jam"}},
]
const incident = {faultId: "jam@c7#1", kind: "jam", assetId: "conveyor-07", severityId: 4}

test("the strip shows the incident, the countdown and one button per fault", () => {
  const {sdk} = fakeSdk()
  const {PresenterStrip} = createDemoKit({React, sdk})
  const html = renderToStaticMarkup(React.createElement(PresenterStrip, {scheduleRows, incident, now: T0}))

  assert.match(html, /Active: jam on conveyor-07/)
  assert.match(html, /Next jam in 01:30/)
  assert.match(html, /data-fault-trigger="jam"[^>]*>Jam</)
  assert.match(html, /data-fault-trigger="eds_timeout"[^>]*>Screening timeout</)
})

test("without action permission the strip has no trigger buttons", () => {
  const {sdk} = fakeSdk({allowed: false})
  const {PresenterStrip} = createDemoKit({React, sdk})
  const html = renderToStaticMarkup(React.createElement(PresenterStrip, {scheduleRows, now: T0}))

  assert.doesNotMatch(html, /data-fault-trigger/)
  assert.match(html, /No active incident/)
})

test("without schedule metrics, as with a real source, the countdown is hidden", () => {
  const {sdk} = fakeSdk()
  const {PresenterStrip} = createDemoKit({React, sdk})
  const html = renderToStaticMarkup(React.createElement(PresenterStrip, {scheduleRows: [], now: T0}))

  assert.doesNotMatch(html, /data-countdown/)
  assert.match(html, /data-fault-trigger="jam"/)
})

test("trigger buttons are disabled while an invocation is running", () => {
  const {sdk} = fakeSdk({invocations: {"inv-1": {state: "running"}}})
  const {PresenterStrip} = createDemoKit({React, sdk})
  const html = renderToStaticMarkup(React.createElement(PresenterStrip, {scheduleRows, now: T0}))

  assert.match(html, /data-fault-trigger="jam" disabled=""/)
})

test("the frame lays out header, chips, banner, visual and detail", () => {
  const {sdk} = fakeSdk()
  const {DemoFrame} = createDemoKit({React, sdk})
  const html = renderToStaticMarkup(
    React.createElement(DemoFrame, {
      title: "Baggage hall",
      kpis: [{label: "Bags/hour", value: "1,840"}],
      chips: [{label: "zone:pier-b", active: true}],
      incident: {...incident, alertId: "alert-9"},
      visual: React.createElement("div", {id: "visual"}),
      detail: React.createElement("div", {id: "detail"}),
    }),
  )

  assert.match(html, /<h1 class="sr-demo-title">Baggage hall<\/h1>/)
  assert.match(html, /1,840/)
  assert.match(html, /aria-pressed="true">zone:pier-b/)
  assert.match(html, /role="alert"[^>]*data-fault-id="jam@c7#1"/)
  assert.match(html, /href="\/alerts\/alert-9"/)
  assert.ok(html.indexOf('id="visual"') < html.indexOf('id="detail"'))
})

test("the incident hook subscribes to the plugin's fault events", () => {
  const {sdk, calls} = fakeSdk()
  const {useFaultIncidents} = createDemoKit({React, sdk})

  function Probe() {
    const {headline} = useFaultIncidents({logProvider: "plugin:demo-ot-plc"})
    return React.createElement("span", null, headline ? headline.faultId : "none")
  }

  assert.equal(renderToStaticMarkup(React.createElement(Probe)), "<span>none</span>")
  assert.deepEqual(calls.subscribed[0], {log_name: "demo.fault", log_provider: "plugin:demo-ot-plc"})
})
