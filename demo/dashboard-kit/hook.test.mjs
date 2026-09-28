// Stateful hook tests with react-test-renderer: folding live fault events
// into open incidents, and discarding the folded set when the timeline key
// changes (a replaced fixture replays from its own start).
import assert from "node:assert/strict"
import test from "node:test"
import React from "react"
import {act, create} from "react-test-renderer"

import {createDemoKit, fixtureTimelineKey} from "./kit.js"

function faultEvent(state, faultId) {
  return {
    id: `${faultId}/${state}`,
    log_name: "demo.fault",
    severity_id: state === "open" ? 4 : 1,
    time: "2026-01-01T00:00:10Z",
    message: `fault ${state} on conveyor-07`,
    metadata: {
      "demo.fault.state": state,
      "demo.fault.kind": "jam",
      "demo.fault.id": faultId,
      asset_id: "conveyor-07",
    },
  }
}

function mountHook({timelineKey} = {}) {
  let onEvents = null
  const sdk = {
    useDashboardActions: () => ({allowed: true, actions: [], invocations: {}, invoke: () => {}}),
    useDashboardEvents: (_filter, handler) => {
      onEvents = handler
      return {allowed: true, error: null}
    },
    useFrameRefresh: () => () => Promise.resolve({refreshed: true}),
  }
  const {useFaultIncidents} = createDemoKit({React, sdk})

  function Probe({tkey}) {
    const {headline} = useFaultIncidents({logProvider: "plugin:demo", timelineKey: tkey})
    return React.createElement("span", null, headline ? headline.faultId : "none")
  }

  let renderer = null
  act(() => {
    renderer = create(React.createElement(Probe, {tkey: timelineKey}))
  })
  return {
    headline: () => renderer.root.findByType("span").children[0],
    deliver: (events) => act(() => onEvents(events)),
    retimeline: (tkey) => act(() => renderer.update(React.createElement(Probe, {tkey}))),
  }
}

test("delivered fault events open and resolve incidents", () => {
  const hook = mountHook({timelineKey: "steady"})
  assert.equal(hook.headline(), "none")

  hook.deliver([faultEvent("open", "jam@c7#1")])
  assert.equal(hook.headline(), "jam@c7#1")

  hook.deliver([faultEvent("resolved", "jam@c7#1")])
  assert.equal(hook.headline(), "none")
})

test("a replaced timeline discards previously folded incidents first", () => {
  const hook = mountHook({timelineKey: "mid-fault"})
  hook.deliver([faultEvent("open", "jam@c7#1")])
  assert.equal(hook.headline(), "jam@c7#1")

  // The steady timeline replays nothing: without the reset the mid-fault
  // incident would stick on the banner.
  hook.retimeline("steady")
  assert.equal(hook.headline(), "none")

  hook.deliver([faultEvent("open", "jam@c7#2")])
  assert.equal(hook.headline(), "jam@c7#2")
})

test("an unchanged timeline key keeps folding across renders", () => {
  const hook = mountHook({timelineKey: "mid-fault"})
  hook.deliver([faultEvent("open", "jam@c7#1")])
  hook.retimeline("mid-fault")
  assert.equal(hook.headline(), "jam@c7#1")
})

test("a same-fixture dev harness reload clears manually opened incidents", () => {
  const hook = mountHook({timelineKey: fixtureTimelineKey({refreshed_at: "steady:1"}, "steady")})
  hook.deliver([faultEvent("open", "jam@c7#1")])
  assert.equal(hook.headline(), "jam@c7#1")

  hook.retimeline(fixtureTimelineKey({refreshed_at: "steady:2"}, "steady"))
  assert.equal(hook.headline(), "none")
})

test("ordinary frame refresh times do not reset live incidents", () => {
  const hook = mountHook({timelineKey: fixtureTimelineKey({refreshed_at: "2026-01-01T00:00:00Z"}, "steady")})
  hook.deliver([faultEvent("open", "jam@c7#1")])
  assert.equal(hook.headline(), "jam@c7#1")

  hook.retimeline(fixtureTimelineKey({refreshed_at: "2026-01-01T00:00:10Z"}, "steady"))
  assert.equal(hook.headline(), "jam@c7#1")
})
