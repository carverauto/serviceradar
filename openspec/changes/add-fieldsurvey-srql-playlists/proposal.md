# Change: Add FieldSurvey SRQL Playlist Dashboards

## Why
The dashboard should not expose an ad hoc floor selector or globally pick the latest FieldSurvey session. Operators need to curate dashboard heatmap rotation by site, building, floor, tag, or operational context, and that selection needs to be queryable through the same SRQL model used elsewhere in ServiceRadar.

Large deployments also need FieldSurvey data to be first-class in SRQL instead of being reachable only through bespoke dashboard/review queries.

## What Changes
- Add first-class SRQL entities for FieldSurvey sessions, persisted coverage rasters, room artifacts, RF observations, pose samples, RF/pose matches, and spectrum observations.
- Add a settings-managed FieldSurvey dashboard playlist where each entry has a label, display mode, order, dwell interval, and SRQL query.
- Make the dashboard FieldSurvey card resolve its displayed heatmap from the configured playlist rather than a global latest-session fallback.
- Restrict dashboard playlist entries to persisted raster/floorplan candidates so raw RF/pose/spectrum tables remain investigation surfaces, not dashboard hot paths.
- Keep the no-playlist fallback simple: show the latest floorplan-backed `wifi_rssi` raster visible to the current user.
- Extend existing FieldSurvey organization work so site/building/floor/tag attribution is filterable through SRQL.

## Impact
- Affected specs:
  - `srql`
  - `build-web-ui`
- Affected code (expected):
  - `rust/srql/src/parser.rs`
  - `rust/srql/src/query/mod.rs`
  - `rust/srql/src/query/field_survey_*.rs` (new query modules)
  - `rust/srql/src/query/viz.rs`
  - `rust/srql/src/models.rs`
  - `rust/srql/src/schema.rs`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
  - `elixir/serviceradar_core/priv/repo/migrations/*` (playlist storage and index tuning)
  - `elixir/serviceradar_core/lib/serviceradar/spatial/*`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings_*`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/*`
  - FieldSurvey review/dashboard Playwright coverage
- Breaking changes:
  - None expected. Existing dashboard behavior remains as fallback when no playlist is configured.
