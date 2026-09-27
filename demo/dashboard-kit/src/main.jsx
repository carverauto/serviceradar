import React, {useMemo, useState} from "react"
import {mountReactDashboard, useDashboardFrame, useDashboardSrql} from "@carverauto/serviceradar-dashboard-sdk/react"
import * as sdk from "@carverauto/serviceradar-dashboard-sdk/live"

import {DEMO_KIT_CSS, createDemoKit} from "../kit.js"
import {scheduleStatus} from "../presenter.js"

const {DemoFrame, PresenterStrip, useFaultIncidents} = createDemoKit({React, sdk})

const PLUGIN_ID = "demo-hello-sim"
const SCHEDULE_QUERY = "in:timeseries_metrics metric_name:(demo.fault.active,demo.fault.next_at) latest:true"

export function Dashboard() {
  const frame = useDashboardFrame("schedule")
  const srql = useDashboardSrql()
  const [scenario, setScenario] = useState("steady")
  const {headline} = useFaultIncidents({logProvider: `plugin:${PLUGIN_ID}`})

  const rows = frame?.results || []
  const status = scheduleStatus(rows, Date.now())
  const chips = useMemo(
    () => [
      {
        label: "scenario:steady",
        active: scenario === "steady",
        onClick: () => {
          setScenario("steady")
          srql.update(`${SCHEDULE_QUERY} scenario:steady`)
        },
      },
      {
        label: "scenario:mid-fault",
        active: scenario === "mid-fault",
        onClick: () => {
          setScenario("mid-fault")
          srql.update(`${SCHEDULE_QUERY} scenario:mid-fault`)
        },
      },
    ],
    [scenario, srql],
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
            targets={[]}
            scheduleRows={rows}
            incident={headline}
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
