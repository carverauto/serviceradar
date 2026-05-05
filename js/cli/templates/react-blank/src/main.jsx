import React from "react"
import {mountReactDashboard, useDashboardFrame} from "@carverauto/serviceradar-dashboard-sdk/react"

function Dashboard() {
  const frame = useDashboardFrame("primary")
  const rows = frame?.results || []

  return (
    <main style={{padding: 24, fontFamily: "ui-sans-serif, system-ui, sans-serif"}}>
      <h1>__DASHBOARD_TITLE__</h1>
      <p>{rows.length} rows in the primary frame.</p>
      {rows.length > 0 ? (
        <pre style={{background: "#f3f4f6", padding: 12, borderRadius: 6, overflow: "auto"}}>
          {JSON.stringify(rows[0], null, 2)}
        </pre>
      ) : null}
    </main>
  )
}

export const mountDashboard = mountReactDashboard(Dashboard)
export default mountDashboard
