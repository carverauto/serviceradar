import {defineDashboardConfig} from "@carverauto/serviceradar-dashboard-sdk/config"

export default defineDashboardConfig({
  manifest: {
    id: "__PACKAGE_ID__",
    name: "__DASHBOARD_TITLE__",
    version: "0.1.0",
    vendor: "__DASHBOARD_TITLE__",
    description: "Custom ServiceRadar dashboard package.",
    capabilities: ["srql.execute"],
    data_frames: [
      {
        id: "primary",
        query: "in:devices limit:50",
        encoding: "json_rows",
        limit: 50,
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
    frames: "fixtures/sample-frames.json",
    settings: "fixtures/sample-settings.json",
  },
})
