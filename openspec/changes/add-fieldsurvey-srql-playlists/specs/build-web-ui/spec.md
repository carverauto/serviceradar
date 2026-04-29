## ADDED Requirements

### Requirement: FieldSurvey dashboard playlist settings
The web UI SHALL provide an authenticated settings surface where administrators can manage a FieldSurvey dashboard playlist made of saved SRQL queries.

#### Scenario: Create a playlist entry
- **GIVEN** an authenticated administrator is on the FieldSurvey dashboard playlist settings page
- **WHEN** they create an entry with a label, SRQL query, overlay type, enabled state, sort position, dwell interval, and max age
- **THEN** the system SHALL persist the entry
- **AND** the entry SHALL be available to the dashboard FieldSurvey card

#### Scenario: Preview playlist query
- **GIVEN** an administrator edits a playlist entry
- **WHEN** they click preview
- **THEN** the UI SHALL execute the SRQL query under the administrator's current scope
- **AND** show the survey/raster/floorplan candidate that would render on the dashboard
- **AND** show a useful error when the query is invalid, empty, stale, or not renderable as a heatmap

### Requirement: Dashboard FieldSurvey card uses playlist entries
The dashboard FieldSurvey card SHALL use the configured FieldSurvey SRQL playlist to select which persisted heatmap to show.

#### Scenario: Dashboard renders first matching playlist item
- **GIVEN** enabled FieldSurvey playlist entries exist
- **AND** the first entry resolves to a persisted `wifi_rssi` raster with cached floorplan geometry
- **WHEN** the dashboard loads
- **THEN** the FieldSurvey card SHALL render that raster over the floorplan
- **AND** it SHALL identify the playlist entry label without exposing manual floor controls on the dashboard card

#### Scenario: Dashboard rotates playlist entries
- **GIVEN** multiple enabled playlist entries resolve to renderable rasters
- **WHEN** the configured dwell interval elapses
- **THEN** the dashboard SHALL rotate to the next renderable playlist item
- **AND** it SHALL skip invalid or empty entries while surfacing concise diagnostics

#### Scenario: Dashboard fallback without playlist
- **GIVEN** no enabled FieldSurvey playlist entries exist
- **WHEN** the dashboard loads
- **THEN** the FieldSurvey card SHALL fall back to the latest floorplan-backed `wifi_rssi` raster visible to the current user
- **AND** it SHALL not globally mix sessions from unrelated site/building/floor metadata when playlist entries are configured

### Requirement: FieldSurvey playlist queries stay off raw hot paths
The dashboard SHALL NOT use raw FieldSurvey RF, pose, fused RF/pose, or spectrum SRQL entities for routine heatmap card rendering.

#### Scenario: Raw query is rejected for dashboard heatmap entry
- **GIVEN** an administrator enters `in:field_survey_rf_observations session_id:<session>` as a heatmap playlist query
- **WHEN** they validate or save the playlist entry
- **THEN** the UI SHALL reject it as unsuitable for dashboard heatmap rendering
- **AND** explain that dashboard heatmaps require persisted raster candidates such as `in:field_survey_rasters`
