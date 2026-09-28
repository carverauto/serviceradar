import {defineDashboardConfig} from "@carverauto/serviceradar-dashboard-sdk/config"

export default defineDashboardConfig({
  manifest: {
    id: "__PACKAGE_ID__",
    name: "__DASHBOARD_TITLE__",
    version: "0.1.0",
    vendor: "__DASHBOARD_TITLE__",
    description: "Frame-driven table dashboard.",
    capabilities: ["srql.execute"],
    data_frames: [
      {
        id: "rows",
        query: "in:devices limit:1000",
        encoding: "json_rows",
        limit: 1000,
        required: true,
        fields: [
          {name: "device_id", type: "string"},
          {name: "name", type: "string"},
          {name: "site_code", type: "string"},
          {name: "status", type: "string"},
          {name: "model", type: "string"},
          {name: "last_seen", type: "string"},
        ],
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
  fixtures: {
    "all-up": "fixtures/sample-frames.json",
    "with-failures": "fixtures/with-failures.json",
  },
})
