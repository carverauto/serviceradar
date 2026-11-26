# Vantage ALPR (Synthetic Reference Pack)

Apache-2.0 reference Solution Pack v2 (`io.serviceradar.vantage-alpr`) demonstrating
Vantage ML vehicle license plate recognition across Ramp 1 (`camera_vlm` fallback)
and Ramp 2 (`vantage.alpr.v1` external worker over `vantage.worker.v1`).

## Contents

- **Vantage Pipeline (`vantage_pipelines/alpr-vehicle-plate.json`)**:
  Triggers `on_stage1_detection` for `vehicle` detections matching `tag:gate-entry`,
  extracts bounded full-resolution crops (`min_bbox_width_px: 96`, `max_dimension: 640`,
  `max_bytes: 98304`), targets `runner: "external_worker"` (`capability: "vantage.alpr.v1"`)
  with automatic Ramp 1 `fallback_runner: "camera_vlm"`, and validates reads against
  `alpr_plate_read`.
- **Signal Schema & Display Contract (`signal_schemas/alpr_plate_read.{schema,display}.json`)**:
  Draft 2020-12 JSON Schema enforcing `^[A-Z0-9-]{2,12}$` on `plate_text` with
  `additionalProperties: false` and timeline/overlay display metadata.
- **Health Check (`checks/alpr-worker-health.json`)**:
  Declarative SRQL DAG check monitoring `in:events log_name:"camera.vantage.observation"`
  volume against configurable warning/critical thresholds.
- **Watchlist Alert Rule (`rules/alpr-watchlist-alert.json`)**:
  Installs in `paused` state (`install_state: "paused"`) matching synthetic plates
  `SR-0100` and `TEST-742` from `camera.vantage.observation` OCSF `1008` events.
- **Overview Dashboard (`dashboards/alpr-overview.json`)**:
  Authored SRQL overview tracking ALPR observation events, alerts, and service health.
- **Bundled Console (`dashboard_packages/alpr-console/`)**:
  `dashboard-browser-module-v1` React console (`trust: "trusted"`, requiring admin
  approval or `dashboards.packages.manage` to enable) querying `in:camera_observations`
  and subscribing to OCSF `1008` `alpr_plate_read` updates.

## Synthetic Verification Defaults

- Camera location: `Gate West 01` (`192.0.2.10`, RFC 5737 subnet `198.51.100.0/24`)
- Synthetic watchlist plates: `SR-0100`, `TEST-742`
- License: `Apache-2.0` (zero copyleft or proprietary dependencies)
