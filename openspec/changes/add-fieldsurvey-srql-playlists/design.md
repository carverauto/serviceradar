## Context
FieldSurvey now persists the raw survey timeline, derived rasters, and small RoomPlan/floorplan metadata in Postgres, with large room artifacts stored in NATS Object Store. The dashboard currently has one FieldSurvey card and selects a latest survey/raster directly. That does not scale to airports, terminals, floors, or customer-defined operational views.

SRQL is the right selector language because it already provides query builder semantics, saved targeting patterns, and a common route for filtering operational data.

## Goals
- Make all persisted FieldSurvey tables discoverable through SRQL for investigation and saved views.
- Let administrators build a dashboard playlist from SRQL queries such as `in:field_survey_rasters site_id:ORD building_id:terminal-b floor_index:2 overlay_type:wifi_rssi has_floorplan:true sort:generated_at:desc limit:1`.
- Render dashboard FieldSurvey cards from persisted raster/floorplan records returned by playlist queries.
- Keep raw, high-volume FieldSurvey observations out of dashboard rendering paths.
- Preserve the existing latest-raster fallback for deployments that have not configured playlists yet.

## Non-Goals
- Do not add a dashboard floor selector as the primary UX.
- Do not make the dashboard evaluate arbitrary raw RF or pose queries every refresh.
- Do not store large LiDAR/RoomPlan blobs in Postgres; large artifacts stay in NATS Object Store, while cached floorplan metadata stays queryable in Postgres.
- Do not implement customer multitenancy or per-customer routing.

## Decisions
- **SRQL entities:** Add separate SRQL entities for summary/candidate data (`field_survey_sessions`, `field_survey_rasters`, `field_survey_artifacts`) and raw investigation data (`field_survey_rf_observations`, `field_survey_pose_samples`, `field_survey_rf_pose_matches`, `field_survey_spectrum_observations`).
- **Playlist contract:** Dashboard playlist entries store SRQL text plus presentation metadata. A playlist entry is valid for dashboard heatmaps only when its query resolves to a persisted `field_survey_rasters` result with a `raster_id`, `session_id`, `overlay_type`, and optional floorplan artifact metadata.
- **Rendering path:** The dashboard loads the playlist asynchronously, evaluates entries in order, and renders the active entry from persisted raster cells and cached floorplan linework. It rotates by dwell interval without adding manual floor controls to the dashboard card.
- **Settings UX:** Settings provides CRUD, validation, preview, and ordering for playlist entries. Preview executes the SRQL query and shows the candidate survey/raster that would be displayed.
- **Fallback:** If there are no enabled playlist entries, the dashboard uses the latest floorplan-backed `wifi_rssi` raster visible to the current user. The fallback is intentionally a compatibility behavior, not the primary UX.

## Data Model
- Add `platform.fieldsurvey_dashboard_playlist_entries` with:
  - `id`, `label`, `query`, `display_mode`, `overlay_type`, `enabled`, `position`, `dwell_seconds`, `max_age_seconds`, `metadata`, timestamps.
- Keep query results scoped by the authenticated user/session ownership checks already used by FieldSurvey review.
- Add or validate indexes on:
  - `platform.survey_coverage_rasters(user_id, overlay_type, generated_at)`
  - `platform.survey_session_metadata(user_id, site_id, building_id, floor_index)`
  - `platform.survey_session_metadata USING GIN(tags)`
  - `platform.survey_room_artifacts(session_id, artifact_type, uploaded_at)`

## Risks / Trade-offs
- SRQL queries over raw FieldSurvey tables can be expensive. Mitigation: enforce default time ranges/limits and keep dashboard playlist validation restricted to raster/session candidate entities.
- A playlist query can return stale or artifact-less sessions. Mitigation: settings preview surfaces the selected candidate and dashboard skips invalid entries with visible diagnostics.
- FieldSurvey schema is still evolving. Mitigation: expose stable fields first and keep raw tables behind narrow filter/operator support.

## Migration Plan
1. Add SRQL entity support and catalog metadata.
2. Add playlist storage migration/resource and settings UI.
3. Update dashboard FieldSurvey async loader to use the playlist resolver with latest-raster fallback.
4. Add Playwright coverage for settings preview, dashboard rotation, and fallback behavior.
5. Update documentation and OpenSpec task checklists after implementation.

## Open Questions
- Should playlist entries support multiple dashboard cards, or should the single card rotate through entries first?
- Should the playlist be global per deployment initially, or scoped to operator role/profile later?
