import {defineDashboardConfig} from "@carverauto/serviceradar-dashboard-sdk/config"

export default defineDashboardConfig({
  manifest: {
    id: "__PACKAGE_ID__",
    name: "__DASHBOARD_TITLE__",
    version: "0.1.0",
    vendor: "__DASHBOARD_TITLE__",
    description: "Map dashboard powered by useDeckMap + useDeckLayers.",
    capabilities: ["srql.execute", "map.basemap.read"],
    data_frames: [
      {
        id: "sites",
        query: "in:wifi_sites limit:500",
        encoding: "json_rows",
        limit: 500,
        required: true,
        coordinates: {longitude: "longitude", latitude: "latitude"},
        fields: [
          {name: "site_code", type: "string"},
          {name: "name", type: "string"},
          {name: "region", type: "string"},
          {name: "longitude", type: "number"},
          {name: "latitude", type: "number"},
          {name: "ap_count", type: "number"},
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
    "all-regions": "fixtures/sample-frames.json",
    "americas-only": "fixtures/americas-only.json",
  },
})
