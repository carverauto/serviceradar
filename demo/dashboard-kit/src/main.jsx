import React, {useEffect, useMemo, useRef, useState} from "react"
import {mountReactDashboard, useDashboardFrame, useDashboardSrql} from "@carverauto/serviceradar-dashboard-sdk/react"
import * as sdk from "@carverauto/serviceradar-dashboard-sdk/live"

import {DEMO_KIT_CSS, createDemoKit, fixtureTimelineKey} from "../kit.js"
import {fixtureScheduleNow, latestSampleMs, scheduleStatus} from "../presenter.js"

const {DemoFrame, PresenterStrip, useFaultIncidents} = createDemoKit({React, sdk})

const PLUGIN_ID = "demo-hello-sim"
const SCHEDULE_QUERY = "in:timeseries_metrics metric_name:(demo.fault.active,demo.fault.next_at) latest:true"

export function Dashboard() {
  const frame = useDashboardFrame("schedule")
  const srql = useDashboardSrql()
  const rows = frame?.results || []

  const [, bumpClock] = useState(0)
  const [fixtureLoadSeq, bumpFixtureLoadSeq] = useState(1)
  useEffect(() => {
    const timer = setInterval(() => bumpClock((tick) => tick + 1), 1000)
    return () => clearInterval(timer)
  }, [])
  const wallNow = Date.now()
  const sampleMs = latestSampleMs(rows)
  const timelineKey = fixtureTimelineKey(frame, fixtureLoadSeq)
  const sampleAnchor = useRef({sampleMs: null, timelineKey: null, observedAtMs: wallNow})
  if (sampleAnchor.current.sampleMs !== sampleMs || sampleAnchor.current.timelineKey !== timelineKey) {
    sampleAnchor.current = {sampleMs, timelineKey, observedAtMs: wallNow}
  }
  const now = fixtureScheduleNow(sampleMs, timelineKey, sampleAnchor.current.observedAtMs, wallNow)
  const status = scheduleStatus(rows, now === undefined ? wallNow : now)

  // The pressed chip follows the loaded frames, not the last click: the side
  // panel can swap the fixture directly, and the schedule rows name which
  // scenario is actually showing. Chip-driven fixture loads also carry a local
  // sequence so reloading the active fixture clears the replayed incident set.
  const loadedScenario = (status.activeCount ?? 0) > 0 ? "mid-fault" : "steady"
  const {headline} = useFaultIncidents({logProvider: `plugin:${PLUGIN_ID}`, timelineKey})

  const chips = useMemo(
    () => [
      {
        label: "scenario:steady",
        active: loadedScenario === "steady",
        onClick: () => {
          bumpFixtureLoadSeq((seq) => seq + 1)
          srql.update(`${SCHEDULE_QUERY} scenario:steady`)
        },
      },
      {
        label: "scenario:mid-fault",
        active: loadedScenario === "mid-fault",
        onClick: () => {
          bumpFixtureLoadSeq((seq) => seq + 1)
          srql.update(`${SCHEDULE_QUERY} scenario:mid-fault`)
        },
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
