// SPDX-License-Identifier: Apache-2.0
// Pre-built browser_module entrypoint (`dashboard-browser-module-v1`) for
// __DASHBOARD_PACKAGE_ID__. Rebuild from src/main.jsx via `serviceradar-cli dashboard build --out-dir .`.

export const MODULE_VERSION = "dashboard-browser-module-v1"

export function mountDashboard(container, context = {}) {
  const capabilities = ["camera.stream.view", "events.subscribe", "srql.execute"]
  const eventFilter = {
    class_uid: 1008,
    metadata: {
      service_radar: {
        signal_schema: {
          schema_id: "__SCHEMA_ID__",
        },
      },
    },
  }
  const sampleRows = [
    {
      camera_name: "Gate West 01",
      camera_ip: "192.0.2.10",
      plate_text: "SR-0100",
      confidence: 0.94,
    },
    {
      camera_name: "Gate West 01",
      camera_ip: "192.0.2.10",
      plate_text: "TEST-742",
      confidence: 0.91,
    },
  ]
  if (container && typeof container === "object" && "textContent" in container) {
    container.textContent = `Vantage Console (${MODULE_VERSION}): ${sampleRows.map((r) => r.plate_text).join(", ")}`
  }
  return {
    moduleVersion: MODULE_VERSION,
    capabilities,
    eventFilter,
    context,
    sampleRows,
    unmount() {},
  }
}
