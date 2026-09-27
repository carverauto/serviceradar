// Shared frame and presenter strip for showcase demo dashboards (design D13,
// D14). Built as a factory so a demo dashboard passes in its own React and
// dashboard SDK, and tests can pass stand-ins:
//
//   import React from "react"
//   import * as sdk from "@carverauto/serviceradar-dashboard-sdk/live"
//   import {createDemoKit} from "../../dashboard-kit/kit.js"
//   const {DemoFrame, PresenterStrip, useFaultIncidents} = createDemoKit({React, sdk})
//
// `sdk` needs useDashboardActions, useDashboardEvents and useFrameRefresh.
// Nothing here changes dashboard state directly: every fault button invokes the
// plugin's fault action, and the banner and strip follow the resulting events.

import {
  alertHref,
  faultEventFilter,
  faultTriggers,
  foldIncidents,
  formatCountdown,
  headlineIncident,
  scheduleStatus,
  triggerRequest,
} from "./presenter.js"

export const DEMO_KIT_CSS = `
.sr-demo-frame{display:grid;grid-template-rows:auto auto auto 1fr;gap:.75rem;height:100%;padding:.75rem;box-sizing:border-box}
.sr-demo-header{display:flex;flex-wrap:wrap;align-items:baseline;gap:1rem}
.sr-demo-title{font-size:1.1rem;font-weight:600;margin:0}
.sr-demo-kpis{display:flex;flex-wrap:wrap;gap:1rem;margin-left:auto}
.sr-demo-kpi{display:flex;flex-direction:column}
.sr-demo-kpi-value{font-size:1.1rem;font-weight:600;font-variant-numeric:tabular-nums}
.sr-demo-kpi-label{font-size:.75rem;opacity:.7}
.sr-demo-chips{display:flex;flex-wrap:wrap;gap:.4rem}
.sr-demo-chip{border:1px solid currentColor;border-radius:999px;padding:.1rem .6rem;font-size:.8rem;background:none;color:inherit;cursor:pointer;opacity:.75}
.sr-demo-chip[aria-pressed="true"]{opacity:1;font-weight:600}
.sr-demo-banner{display:flex;align-items:center;gap:.75rem;padding:.5rem .75rem;border-radius:.4rem;background:#b91c1c;color:#fff}
.sr-demo-banner a{color:inherit;font-weight:600}
.sr-demo-body{display:grid;grid-template-columns:7fr 5fr;gap:.75rem;min-height:0}
@media (max-width:900px){.sr-demo-body{grid-template-columns:1fr}}
.sr-demo-visual,.sr-demo-detail{min-height:0;overflow:auto}
.sr-demo-strip{display:flex;flex-wrap:wrap;align-items:center;gap:.5rem;font-size:.85rem}
.sr-demo-countdown{font-variant-numeric:tabular-nums}
.sr-demo-trigger{border-radius:.3rem;padding:.2rem .6rem;cursor:pointer}
`

export function createDemoKit({React, sdk}) {
  const h = React.createElement
  const {useCallback, useEffect, useMemo, useState} = React

  function KpiHeader({title, kpis = []}) {
    return h(
      "header",
      {className: "sr-demo-header"},
      h("h1", {className: "sr-demo-title"}, title),
      h(
        "div",
        {className: "sr-demo-kpis"},
        kpis.map((kpi) =>
          h(
            "div",
            {className: "sr-demo-kpi", key: kpi.label},
            h("span", {className: "sr-demo-kpi-value"}, kpi.value),
            h("span", {className: "sr-demo-kpi-label"}, kpi.label),
          ),
        ),
      ),
    )
  }

  // Chips mirror the dashboard's SRQL query state; the caller applies them.
  function SrqlChips({chips = []}) {
    if (chips.length === 0) return null
    return h(
      "nav",
      {className: "sr-demo-chips", "aria-label": "Active filters"},
      chips.map((chip) =>
        h(
          "button",
          {
            key: chip.label,
            type: "button",
            className: "sr-demo-chip",
            "aria-pressed": chip.active ? "true" : "false",
            onClick: chip.onClick,
          },
          chip.label,
        ),
      ),
    )
  }

  function IncidentBanner({incident, onSelect}) {
    if (!incident) return null
    const text = incident.message || `${incident.kind} on ${incident.assetId}`
    return h(
      "div",
      {className: "sr-demo-banner", role: "alert", "data-fault-id": incident.faultId},
      h("strong", null, "Incident"),
      h(
        "button",
        {type: "button", className: "sr-demo-chip", onClick: () => onSelect?.(incident)},
        text,
      ),
      h("a", {href: alertHref(incident)}, "View alert"),
    )
  }

  // Open fault incidents from the plugin's live fault events. Frames are
  // refreshed on every fault event so the map and detail panel follow at once.
  function useFaultIncidents({logProvider, enabled = true} = {}) {
    const [open, setOpen] = useState(() => new Map())
    const refreshFrames = sdk.useFrameRefresh()
    const filter = useMemo(() => faultEventFilter(logProvider), [logProvider])

    const onEvents = useCallback(
      (events) => {
        setOpen((previous) => foldIncidents(previous, events))
        // The host resolves {refreshed: false} when a query is already in
        // flight; only a transport failure rejects, and nothing is left to
        // catch it here.
        refreshFrames().catch(() => {})
      },
      [refreshFrames],
    )
    const {allowed, error} = sdk.useDashboardEvents(filter, onEvents, {enabled})

    return {allowed, error, incidents: open, headline: headlineIncident(open)}
  }

  function useNow(active) {
    const [now, setNow] = useState(() => Date.now())
    useEffect(() => {
      if (!active) return undefined
      const timer = setInterval(() => setNow(Date.now()), 1000)
      return () => clearInterval(timer)
    }, [active])
    return now
  }

  // Active incident, countdown to the next scheduled fault, and one trigger per
  // fault the plugin declares. Triggers hide without action permission; the
  // countdown hides without the simulator's schedule metrics.
  function PresenterStrip({pluginId, scope = "device", targets = [], scheduleRows = [], incident, now}) {
    const {allowed, actions, invoke, invocations} = sdk.useDashboardActions({scope, pluginId})
    const triggers = faultTriggers(actions, {allowed})
    const ticking = now === undefined
    const clock = useNow(ticking)
    const schedule = scheduleStatus(scheduleRows, ticking ? clock : now)
    const busy = Object.values(invocations || {}).some((entry) =>
      ["pending", "dispatching", "running"].includes(entry?.state),
    )

    return h(
      "div",
      {className: "sr-demo-strip", "data-presenter-strip": ""},
      incident
        ? h("span", {"data-active-incident": incident.faultId}, `Active: ${incident.kind} on ${incident.assetId}`)
        : h("span", {"data-active-incident": ""}, "No active incident"),
      schedule.visible && schedule.countdownMs !== null
        ? h(
            "span",
            {className: "sr-demo-countdown", "data-countdown": ""},
            `Next ${schedule.nextKind || "fault"} in ${formatCountdown(schedule.countdownMs)}`,
          )
        : null,
      triggers.map((trigger) =>
        h(
          "button",
          {
            key: trigger.kind,
            type: "button",
            className: "sr-demo-trigger",
            "data-fault-trigger": trigger.kind,
            disabled: busy,
            onClick: () => invoke(triggerRequest(trigger, {scope, targets})),
          },
          trigger.label,
        ),
      ),
    )
  }

  // Common frame: header with KPIs, SRQL chips, incident banner, then the
  // visual (about 7/12) beside the detail panel (about 5/12).
  function DemoFrame({title, kpis, chips, incident, onSelectIncident, strip, visual, detail}) {
    return h(
      "div",
      {className: "sr-demo-frame"},
      h(KpiHeader, {title, kpis}),
      h(SrqlChips, {chips}),
      h(IncidentBanner, {incident, onSelect: onSelectIncident}),
      h(
        "div",
        {className: "sr-demo-body"},
        h("section", {className: "sr-demo-visual"}, visual),
        h("aside", {className: "sr-demo-detail"}, strip, detail),
      ),
    )
  }

  return {DemoFrame, IncidentBanner, KpiHeader, PresenterStrip, SrqlChips, useFaultIncidents}
}
