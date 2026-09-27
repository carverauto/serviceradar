import {defineDashboardConfig} from "@carverauto/serviceradar-dashboard-sdk/config"

// Offline showcase of the shared demo frame + presenter strip. `npm run dev`
// serves this from the fixtures below with no live ServiceRadar: the schedule
// frame feeds the countdown, the fixture's actions feed the trigger buttons,
// and its timeline events feed the incident banner.
export default defineDashboardConfig({
  manifest: {
    id: "dev.serviceradar.presenter-kit",
    name: "Demo presenter kit",
    version: "0.1.0",
    vendor: "ServiceRadar demos",
    description: "Shared demo frame and presenter strip, running offline from fixtures.",
    capabilities: ["srql.execute", "actions.invoke"],
    data_frames: [
      {
        id: "schedule",
        query: "in:timeseries_metrics metric_name:(demo.fault.active,demo.fault.next_at) latest:true",
        encoding: "json_rows",
        required: true,
      },
    ],
    renderer: {
      kind: "browser_module",
      interface_version: "dashboard-browser-module-v1",
      entrypoint: "mountDashboard",
      trust: "trusted",
    },
  },
  renderer: {
    entry: "src/main.jsx",
  },
  samples: {
    frames: "fixtures/presenter-steady.json",
  },
  fixtures: {
    steady: "fixtures/presenter-steady.json",
    "mid-fault": "fixtures/presenter-fault.json",
  },
  fixtureResolver: "fixtures/resolve.js",
})
