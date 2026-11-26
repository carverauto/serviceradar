## ADDED Requirements

### Requirement: Solution Pack bundling and CLI verification for Dashboard SDK browser modules
The `@carverauto/serviceradar-cli` tool SHALL support packaging a built `dashboard-browser-module-v1` project inside a `pack_format_version: 2` Solution Pack (`dashboard_packages/<slug>/manifest.json` and `renderer.js`), verifying renderer SHA-256 parity between the dashboard manifest and the Solution Pack `manifest.files` table, enforcing the `8 MiB` per-renderer size cap, and providing `serviceradar-cli vantage init|dev|validate` scaffolding that can compose a Vantage ML pipeline with a companion React Dashboard SDK module.

#### Scenario: CLI builds and validates a Solution Pack containing a React Dashboard SDK module
- **GIVEN** a Vantage Solution Pack project containing `vantage_pipelines/alpr-vehicle-plate.json` and a React dashboard project under `dashboard_packages/alpr-console/`
- **WHEN** the author runs `serviceradar-cli pack validate` and `serviceradar-cli pack build`
- **THEN** the CLI SHALL verify that `dashboard_packages/alpr-console/manifest.json` conforms to `dashboard-browser-module-v1`, that `renderer.js` is within the `8 MiB` cap and matches both the dashboard manifest `sha256` and `manifest.files`, and emit a deterministic `.srpack` archive containing both the Vantage pipeline and the dashboard module

#### Scenario: CLI rejects a Solution Pack with a stale or mismatched dashboard renderer digest
- **GIVEN** a pack directory where `dashboard_packages/alpr-console/renderer.js` was modified after `dashboard_packages/alpr-console/manifest.json` was stamped
- **WHEN** the author runs `serviceradar-cli pack validate` or `serviceradar-cli pack build`
- **THEN** the CLI SHALL exit non-zero naming the mismatched renderer digest and SHALL NOT emit a `.srpack` archive

### Requirement: Dashboard SDK consumption of Vantage camera observations and live observation events
Dashboard packages built with `@carverauto/serviceradar-dashboard-sdk` SHALL be able to query authorized Vantage ML observations via standard SRQL data frames (`in:camera_observations`) and subscribe to live OCSF observation events via `useDashboardEvents` (matching `metadata.service_radar.signal_schema` and `camera_source_id`) alongside `CameraGrid`/`useCameraStream`, while enforcing the viewer's own `devices.view` and `devices.cameras.recordings.view` RBAC permissions on every frame and event.

#### Scenario: ALPR console dashboard combines live CameraGrid, observation frames, and live watchlist events
- **GIVEN** an enabled `alpr-console` Dashboard SDK module declaring `camera.stream.view` and `events.subscribe` capabilities and a frame querying `in:camera_observations category:license_plate sort:timeline_ts_us:desc limit:100`
- **WHEN** an authorized operator views the dashboard and a new ALPR observation OCSF event is persisted for `Gate West 01`
- **THEN** `useDashboardEvents` SHALL deliver the matching OCSF event so the dashboard refreshes its `in:camera_observations` frame and updates its `CameraGrid` overlay without polling
- **AND** if the viewer lacks `devices.cameras.recordings.view`, the host SHALL deny the observation frame and withhold unauthorized camera events
