import {defineDashboardConfig} from "@carverauto/serviceradar-dashboard-sdk"

export default defineDashboardConfig({
  outDir: ".",
  renderer: {
    entry: "src/main.jsx",
    artifact: "renderer.js",
  },
  manifest: {
    id: "__DASHBOARD_PACKAGE_ID__",
    name: "__PACK_NAME__ Console",
    version: "0.1.0",
    vendor: "ServiceRadar",
    description: "Synthetic Vantage Dashboard SDK console for Gate West 01 (SR-0100, TEST-742).",
    capabilities: ["camera.stream.view", "events.subscribe", "srql.execute"],
    data_frames: [
      {
        id: "recent_observations",
        query: "in:camera_observations category:license_plate sort:timeline_ts_us:desc limit:100",
        encoding: "json_rows",
        required: true,
        limit: 100,
        refresh_interval_ms: 5000,
      },
    ],
    settings_schema: {
      type: "object",
      properties: {
        camera_source_id: {type: "string"},
      },
    },
  },
  samples: {
    frames: "fixtures/sample-frames.json",
    settings: "fixtures/sample-settings.json",
  },
})
