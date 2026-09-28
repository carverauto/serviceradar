import React, {useEffect, useMemo, useState} from "react"
import {mountReactDashboard, useDashboardFrame, useDashboardSrql} from "@carverauto/serviceradar-dashboard-sdk/react"
import * as sdk from "@carverauto/serviceradar-dashboard-sdk/live"

import {DEMO_KIT_CSS, createDemoKit} from "../kit.js"
import {latestSampleMs, scheduleStatus} from "../presenter.js"

const {DemoFrame, PresenterStrip, useFaultIncidents} = createDemoKit({React, sdk})

const PLUGIN_ID = "demo-hello-sim"
const SCHEDULE_QUERY = "in:timeseries_metrics metric_name:(demo.fault.active,demo.fault.next_at) latest:true"

export function Dashboard() {
  const frame = useDashboardFrame("schedule")
  const srql = useDashboardSrql()
  const rows = frame?.results || []

  // Anchor the clock at the newest schedule sample and advance it from mount:
  // fixtures sample one instant, so the wall clock would clamp their countdown
  // to 00:00. Live rows sample near now, so the anchor is ~now and the wall
  // clock stays in place for them.
  const [mountedAt] = useState(() => Date.now())
  const [, bumpClock] = useState(0)
  useEffect(() => {
    const timer = setInterval(() => bumpClock((tick) => tick + 1), 1000)
    return () => clearInterval(timer)
  }, [])
  const sampleMs = latestSampleMs(rows)
  const now = sampleMs === null ? undefined : sampleMs + (Date.now() - mountedAt)
  const status = scheduleStatus(rows, now === undefined ? Date.now() : now)

  // The pressed chip follows the loaded frames, not the last click: the side
  // panel can swap the fixture directly, and the schedule rows name which
  // scenario is actually showing. The timeline key follows the same identity,
  // so a replaced fixture replays from an empty incident set.
  const loadedScenario = (status.activeCount ?? 0) > 0 ? "mid-fault" : "steady"
  const {headline} = useFaultIncidents({logProvider: `plugin:${PLUGIN_ID}`, timelineKey: loadedScenario})

  const chips = useMemo(
    () => [
      {
        label: "scenario:steady",
        active: loadedScenario === "steady",
        onClick: () => srql.update(`${SCHEDULE_QUERY} scenario:steady`),
      },
      {
        label: "scenario:mid-fault",
        active: loadedScenario === "mid-fault",
        onClick: () => srql.update(`${SCHEDULE_QUERY} scenario:mid-fault`),
      },
    ],
    [loadedScenario, srql],
  )

  const kpis = [
    {label: "Active faults", value: String(status.activeCount ?? "—")},
    {label: "Next fault", value: status.nextKind ?? "—"},
  ]

  return (
    <>
      <style>{DEMO_KIT_CSS}</style>
      <DemoFrame
        title="Presenter kit (offline)"
        kpis={kpis}
        chips={chips}
        incident={headline}
        strip={
          <PresenterStrip
            pluginId={PLUGIN_ID}
            scope="device"
            // The fixture asset every fault targets; the host (and the
            // production actions API) rejects an invocation with no targets.
            targets={[{device_uid: "sensor-a"}]}
            scheduleRows={rows}
            incident={headline}
            now={now}
          />
        }
        visual={
          <div>
            <h2>Schedule frame</h2>
            <pre>{JSON.stringify(rows, null, 2)}</pre>
          </div>
        }
        detail={
          <div>
            <h2>Headline incident</h2>
            <pre>{JSON.stringify(headline, null, 2)}</pre>
          </div>
        }
      />
    </>
  )
}

export const mountDashboard = mountReactDashboard(Dashboard)
export default mountDashboard
