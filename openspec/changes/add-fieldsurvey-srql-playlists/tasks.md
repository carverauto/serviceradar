## 1. SRQL FieldSurvey Entities
- [x] 1.1 Add parser/entity support for `in:field_survey_sessions`, `in:field_survey_rasters`, `in:field_survey_artifacts`, `in:field_survey_rf_observations`, `in:field_survey_pose_samples`, `in:field_survey_rf_pose_matches`, and `in:field_survey_spectrum_observations`.
- [x] 1.2 Implement Rust SRQL query modules for FieldSurvey summary entities with filters for session, site, building, floor, tags, overlay type, artifact type, and generated/uploaded times.
- [x] 1.3 Implement Rust SRQL query modules for raw RF, pose, fused RF/pose, and spectrum investigation entities with strict default time windows and limits.
- [x] 1.4 Add SRQL response fields needed by dashboard/review: `session_id`, `raster_id`, `overlay_type`, `generated_at`, `site_id`, `site_name`, `building_id`, `building_name`, `floor_id`, `floor_name`, `floor_index`, `tags`, `has_floorplan`, `artifact_count`, and bounded render metadata.
- [x] 1.5 Add SRQL viz/catalog metadata and builder filter fields for the FieldSurvey entities.
- [x] 1.6 Add Rust parser/query tests for FieldSurvey filters, ordering, pagination, and unsupported raw-table dashboard fields.

## 2. Playlist Storage and Settings UI
- [x] 2.1 Add `platform.fieldsurvey_dashboard_playlist_entries` migration/resource in Elixir with Ash-backed CRUD actions.
- [x] 2.2 Add settings UI for FieldSurvey dashboard playlist entries: label, SRQL query, overlay/display mode, enabled state, sort order, dwell interval, max age, and metadata.
- [x] 2.3 Add query validation and preview that executes the SRQL query and shows which persisted raster/floorplan candidate would display.
- [x] 2.4 Prevent saving dashboard heatmap playlist entries that do not resolve to a persisted `field_survey_rasters` candidate, while allowing raw FieldSurvey SRQL entities elsewhere.
- [x] 2.5 Add authorization checks for playlist CRUD and preview actions.

## 3. Dashboard Runtime
- [x] 3.1 Replace global latest-raster selection in the dashboard FieldSurvey card with a playlist resolver that evaluates enabled entries in order.
- [x] 3.2 Render the active playlist item from persisted raster cells plus cached floorplan metadata using the existing compact dashboard map styling.
- [x] 3.3 Rotate playlist entries by configured dwell interval without adding manual floor controls to the dashboard card.
- [x] 3.4 Keep a latest floorplan-backed `wifi_rssi` raster fallback when no playlist entries are configured.
- [x] 3.5 Surface concise dashboard diagnostics when a playlist entry is empty, invalid, stale, or missing floorplan/raster data.

## 4. Validation
- [ ] 4.1 Add Elixir tests for playlist CRUD, validation, and fallback behavior.
- [x] 4.2 Add SRQL tests for all new FieldSurvey entities.
- [ ] 4.3 Add Playwright coverage for settings preview and dashboard playlist rendering against demo FieldSurvey data.
- [ ] 4.4 Validate local web-ng dashboard screenshots with the `fieldsurvey-local-web-ng` workflow.
- [x] 4.5 Run `openspec validate add-fieldsurvey-srql-playlists --strict`.
