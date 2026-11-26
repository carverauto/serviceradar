import React from "react"
import {
  CameraGrid,
  mountReactDashboard,
  useDashboardEvents,
  useFrameRows,
} from "@carverauto/serviceradar-dashboard-sdk"

function VantageConsole({api}) {
  const rows = useFrameRows(api, "recent_observations")
  const events = useDashboardEvents(api, {
    class_uid: 1008,
    metadata: {
      service_radar: {
        signal_schema: {schema_id: "__SCHEMA_ID__"},
      },
    },
  })

  return React.createElement(
    "div",
    {className: "vantage-console"},
    React.createElement("h2", null, "__PACK_NAME__ Console (Gate West 01)"),
    React.createElement(CameraGrid, {api, maxColumns: 2}),
    React.createElement(
      "ul",
      null,
      rows.map((row, idx) =>
        React.createElement(
          "li",
          {key: idx},
          `${String(row.label || row.plate_text || "SR-0100")} (${String(row.confidence ?? 0.94)})`,
        ),
      ),
    ),
    React.createElement("p", null, `Live events: ${events.length}`),
  )
}

export const mountDashboard = mountReactDashboard(VantageConsole)
